const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    config: *config.Config,
    args: [][]const u8,
    json_output: bool,
    retries: u8,
    timeout_ms: u32,
    endpoint: ?[]const u8 = null,
};

const Options = struct {
    team: ?[]const u8 = null,
    state: ?[]const u8 = null,
    limit: usize = 50,
    fields: ?[]const u8 = null,
    plain: bool = false,
    no_truncate: bool = false,
    help: bool = false,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --limit value",
            else => @errorName(err),
        };
        try stderr.print("projects list: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "projects list") catch {
        return 1;
    };

    if (opts.state) |state_value| {
        if (!common.isValidProjectState(state_value)) {
            try stderr.print("projects list: invalid --state value\n", .{});
            return 1;
        }
    }

    var field_buf = std.ArrayListUnmanaged(printer.ProjectField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseProjectFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("projects list: {s}\n", .{message});
        return 1;
    };

    if (opts.limit == 0) {
        try stderr.print("projects list: --limit must be greater than zero\n", .{});
        return 1;
    }
    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var status_id: ?[]const u8 = null;
    defer if (status_id) |sid| ctx.allocator.free(sid);

    if (opts.state) |state_raw| {
        const trimmed = std.mem.trim(u8, state_raw, " \t");
        if (trimmed.len == 0) {
            try stderr.print("projects list: invalid --state value\n", .{});
            return 1;
        }
        status_id = common.resolveProjectStatusId(ctx.allocator, &client, trimmed, stderr, "projects list") catch {
            return 1;
        };
    }

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    const limit_i64 = std.math.cast(i64, opts.limit) orelse return error.InvalidLimit;
    try variables.object.put(var_alloc, "first", .{ .integer = limit_i64 });

    var has_filter = false;
    var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    if (opts.team) |team_raw| {
        const trimmed = std.mem.trim(u8, team_raw, " \t");
        if (trimmed.len == 0) {
            try stderr.print("projects list: invalid --team value\n", .{});
            return 1;
        }
        var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try eq_obj.object.put(var_alloc, "eq", .{ .string = trimmed });

        var team_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        if (isUuid(trimmed)) {
            try team_obj.object.put(var_alloc, "id", eq_obj);
        } else {
            try team_obj.object.put(var_alloc, "key", eq_obj);
        }
        var teams_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try teams_obj.object.put(var_alloc, "some", team_obj);
        try filter.object.put(var_alloc, "accessibleTeams", teams_obj);
        has_filter = true;
    }
    if (status_id) |sid| {
        var id_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try id_obj.object.put(var_alloc, "eq", .{ .string = sid });

        var status_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try status_obj.object.put(var_alloc, "id", id_obj);
        try filter.object.put(var_alloc, "status", status_obj);
        has_filter = true;
    }
    if (has_filter) {
        try variables.object.put(var_alloc, "filter", filter);
    }

    const query =
        \\query Projects($first: Int!, $filter: ProjectFilter) {
        \\  projects(first: $first, filter: $filter) {
        \\    nodes { id name slugId description state startDate targetDate url }
        \\    pageInfo { hasNextPage endCursor }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "projects list", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "Projects",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "projects list", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("projects list: response missing data\n", .{});
        return 1;
    };

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const projects_obj = common.getObjectField(data_value, "projects") orelse {
        try stderr.print("projects list: projects not found in response\n", .{});
        return 1;
    };
    const nodes_array = common.getArrayField(projects_obj, "nodes") orelse {
        try stderr.print("projects list: nodes missing in response\n", .{});
        return 1;
    };
    const page_info = common.getObjectField(projects_obj, "pageInfo");
    const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
    const end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;

    var rows = std.ArrayListUnmanaged(printer.ProjectRow).empty;
    defer rows.deinit(ctx.allocator);

    for (nodes_array.items) |node| {
        if (node != .object) continue;
        const id = common.getStringField(node, "id") orelse continue;
        const name = common.getStringField(node, "name") orelse "";
        const slug = common.getStringField(node, "slugId") orelse "";
        const description = common.getStringField(node, "description") orelse "";
        const state = common.getStringField(node, "state") orelse "";
        const start_date = common.getStringField(node, "startDate") orelse "";
        const target_date = common.getStringField(node, "targetDate") orelse "";
        const url = common.getStringField(node, "url") orelse "";
        try rows.append(ctx.allocator, .{
            .id = id,
            .name = name,
            .slug = slug,
            .description = description,
            .state = state,
            .start_date = start_date,
            .target_date = target_date,
            .url = url,
        });
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try printer.printProjectTable(ctx.allocator, &out_writer.interface, rows.items, selected_fields, table_opts);

    if (has_next) {
        const cursor_value = end_cursor orelse "(unknown)";
        try stderr.print("projects list: more projects available; pagination not implemented (endCursor {s})\n", .{cursor_value});
    }

    return 0;
}

fn parseOptions(args: [][]const u8) !Options {
    var opts = Options{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--team")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.team = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--team=")) {
            opts.team = arg["--team=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--state")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.state = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--state=")) {
            opts.state = arg["--state=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.limit = parseLimit(args[idx + 1]) catch return error.InvalidLimit;
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--limit=")) {
            opts.limit = parseLimit(arg["--limit=".len..]) catch return error.InvalidLimit;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fields")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.fields = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--fields=")) {
            opts.fields = arg["--fields=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            opts.plain = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-truncate")) {
            opts.no_truncate = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

fn parseLimit(raw: []const u8) !usize {
    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidLimit;
    if (value <= 0) return error.InvalidLimit;
    return std.math.cast(usize, value) orelse error.InvalidLimit;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear projects list [--team ID] [--state STATE] [--limit N] [--fields LIST] [--plain] [--no-truncate] [--help]
        \\Flags:
        \\  --team ID        Filter by team id or key
        \\  --state STATE    Filter by state (backlog, planned, started, paused, completed, canceled)
        \\  --limit N        Number of projects to fetch (default: 50)
        \\  --fields LIST    Comma-separated columns (id,name,slug,description,state,start_date,target_date,url)
        \\  --plain          Do not pad or truncate table cells
        \\  --no-truncate    Disable ellipsis and padding in table cells
        \\  --help           Show this help message
        \\Examples:
        \\  linear projects list --state started --limit 20
        \\  linear projects list --team ENG --fields name,state,target_date
        \\
    , .{});
}

fn parseProjectFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(printer.ProjectField), allocator: Allocator) ![]const printer.ProjectField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseProjectFieldName(trimmed) orelse return error.InvalidField;
            if (!containsProjectField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.project_default_fields[0..];
}

fn parseProjectFieldName(name: []const u8) ?printer.ProjectField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    if (std.ascii.eqlIgnoreCase(name, "slug") or std.ascii.eqlIgnoreCase(name, "slugId")) return .slug;
    if (std.ascii.eqlIgnoreCase(name, "description")) return .description;
    if (std.ascii.eqlIgnoreCase(name, "state")) return .state;
    if (std.ascii.eqlIgnoreCase(name, "start_date") or std.ascii.eqlIgnoreCase(name, "startDate")) return .start_date;
    if (std.ascii.eqlIgnoreCase(name, "target_date") or std.ascii.eqlIgnoreCase(name, "targetDate")) return .target_date;
    if (std.ascii.eqlIgnoreCase(name, "url")) return .url;
    return null;
}

fn containsProjectField(haystack: []const printer.ProjectField, needle: printer.ProjectField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (value[idx] != '-') return false;
    }
    return true;
}
