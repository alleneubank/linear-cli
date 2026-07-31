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
    limit: usize = 50,
    fields: ?[]const u8 = null,
    plain: bool = false,
    no_truncate: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

const DataRow = struct {
    id: []const u8,
    name: []const u8,
    type: []const u8,
    position: []const u8,
    team: []const u8,
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
        try stderr.print("states list: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "states list") catch {
        return 1;
    };

    var field_buf = std.ArrayListUnmanaged(printer.StateField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseStateFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("states list: {s}\n", .{message});
        return 1;
    };

    if (opts.limit == 0) {
        try stderr.print("states list: --limit must be greater than zero\n", .{});
        return 1;
    }
    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    const limit_i64 = std.math.cast(i64, opts.limit) orelse return error.InvalidLimit;
    try variables.object.put(var_alloc, "first", .{ .integer = limit_i64 });

    if (opts.team) |team_raw| {
        const trimmed = std.mem.trim(u8, team_raw, " \t");
        if (trimmed.len == 0) {
            try stderr.print("states list: invalid --team value\n", .{});
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

        var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
        try filter.object.put(var_alloc, "team", team_obj);
        try variables.object.put(var_alloc, "filter", filter);
    }

    const query =
        \\query WorkflowStates($first: Int!, $filter: WorkflowStateFilter) {
        \\  workflowStates(first: $first, filter: $filter) {
        \\    nodes { id name type position team { key } }
        \\    pageInfo { hasNextPage endCursor }
        \\  }
        \\}
    ;

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var response = common.send(ctx.allocator, "states list", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "WorkflowStates",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "states list", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("states list: response missing data\n", .{});
        return 1;
    };

    const want_table = !ctx.json_output and !opts.data_only and !opts.quiet;
    const want_data_rows = opts.data_only or opts.quiet;
    const want_raw_nodes = ctx.json_output and !opts.data_only and !opts.quiet;

    if (want_raw_nodes) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const states_obj = common.getObjectField(data_value, "workflowStates") orelse {
        try stderr.print("states list: workflowStates not found in response\n", .{});
        return 1;
    };
    const nodes_array = common.getArrayField(states_obj, "nodes") orelse {
        try stderr.print("states list: nodes missing in response\n", .{});
        return 1;
    };
    const page_info = common.getObjectField(states_obj, "pageInfo");
    const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
    const end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;

    var rows = std.ArrayListUnmanaged(printer.StateRow).empty;
    defer rows.deinit(ctx.allocator);
    var data_rows = std.ArrayListUnmanaged(DataRow).empty;
    defer data_rows.deinit(ctx.allocator);

    for (nodes_array.items) |node| {
        if (node != .object) continue;
        const id = common.getStringField(node, "id") orelse continue;
        const name = common.getStringField(node, "name") orelse "";
        const type_value = common.getStringField(node, "type") orelse "";
        const position = try formatPosition(var_alloc, node);
        const team_obj = common.getObjectField(node, "team");
        const team_key = if (team_obj) |t| common.getStringField(t, "key") orelse "" else "";

        if (want_table) {
            try rows.append(ctx.allocator, .{
                .id = id,
                .name = name,
                .type = type_value,
                .position = position,
                .team = team_key,
            });
        }
        if (want_data_rows) {
            try data_rows.append(ctx.allocator, .{
                .id = id,
                .name = name,
                .type = type_value,
                .position = position,
                .team = team_key,
            });
        }
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        for (data_rows.items) |row| {
            try stdout_iface.writeAll(row.id);
            try stdout_iface.writeByte('\n');
        }
    } else if (opts.data_only) {
        if (ctx.json_output) {
            var out_array = std.json.Array.init(var_alloc);
            for (data_rows.items) |row| {
                var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
                for (selected_fields) |field| {
                    try obj.object.put(var_alloc, fieldKey(field), .{ .string = cellValue(row, field) });
                }
                try out_array.append(obj);
            }
            var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try root_obj.object.put(var_alloc, "nodes", .{ .array = out_array });

            var page_info_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try page_info_obj.object.put(var_alloc, "hasNextPage", .{ .bool = has_next });
            if (end_cursor) |cursor_value| {
                try page_info_obj.object.put(var_alloc, "endCursor", .{ .string = cursor_value });
            }
            try root_obj.object.put(var_alloc, "pageInfo", page_info_obj);
            try root_obj.object.put(var_alloc, "limit", .{ .integer = limit_i64 });
            try printer.printJson(root_obj, stdout_iface, true);
        } else {
            for (data_rows.items) |row| {
                var first = true;
                for (selected_fields) |field| {
                    if (!first) try stdout_iface.writeByte('\t') else first = false;
                    try stdout_iface.writeAll(cellValue(row, field));
                }
                try stdout_iface.writeByte('\n');
            }
        }
    } else {
        try printer.printStateTable(ctx.allocator, stdout_iface, rows.items, selected_fields, table_opts);
    }

    if (has_next and !ctx.json_output) {
        const cursor_value = end_cursor orelse "(unknown)";
        try stderr.print("states list: more states available; pagination not implemented (endCursor {s})\n", .{cursor_value});
    }

    return 0;
}

/// `WorkflowState.position` is a GraphQL Float, so it arrives as a JSON number
/// rather than a string and has to be rendered before it can fill a table cell.
/// The result is arena-owned and lives until `run` returns.
fn formatPosition(allocator: Allocator, node: std.json.Value) ![]const u8 {
    if (node != .object) return "";
    const value = node.object.get("position") orelse return "";
    return switch (value) {
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .number_string => |s| s,
        .string => |s| s,
        else => "",
    };
}

fn fieldKey(field: printer.StateField) []const u8 {
    return switch (field) {
        .id => "id",
        .name => "name",
        .type => "type",
        .position => "position",
        .team => "team",
    };
}

fn cellValue(row: DataRow, field: printer.StateField) []const u8 {
    return switch (field) {
        .id => row.id,
        .name => row.name,
        .type => row.type,
        .position => row.position,
        .team => row.team,
    };
}

pub fn parseOptions(args: []const []const u8) !Options {
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
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
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
        \\Usage: linear states list [--team ID|KEY] [--limit N] [--fields LIST] [--plain] [--no-truncate] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --team ID|KEY    Filter by team id or key (omitted: every team's states, disambiguated by the Team column)
        \\  --limit N        Number of workflow states to fetch (default: 50)
        \\  --fields LIST    Comma-separated columns (id,name,type,position,team)
        \\  --plain          Do not pad or truncate table cells
        \\  --no-truncate    Disable ellipsis and padding in table cells
        \\  --quiet          Print only state ids (one per line)
        \\  --data-only      Emit tab-separated rows (or JSON array with --json)
        \\  --help           Show this help message
        \\Examples:
        \\  linear states list --team ENG
        \\  linear states list --team ENG --fields id,name --data-only
        \\  linear states list --fields id,name,team --data-only
        \\  linear issues list --team ENG --state-id <id from 'linear states list'>
        \\
    , .{});
}

fn parseStateFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(printer.StateField), allocator: Allocator) ![]const printer.StateField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseStateFieldName(trimmed) orelse return error.InvalidField;
            if (!containsStateField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.state_default_fields[0..];
}

fn parseStateFieldName(name: []const u8) ?printer.StateField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    if (std.ascii.eqlIgnoreCase(name, "type")) return .type;
    if (std.ascii.eqlIgnoreCase(name, "position")) return .position;
    if (std.ascii.eqlIgnoreCase(name, "team")) return .team;
    return null;
}

fn containsStateField(haystack: []const printer.StateField, needle: printer.StateField) bool {
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
