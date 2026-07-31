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
    limit: usize = 50,
    include_inactive: bool = false,
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
    display_name: []const u8,
    email: []const u8,
    active: []const u8,
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
        try stderr.print("users list: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "users list") catch {
        return 1;
    };

    var field_buf = std.ArrayListUnmanaged(printer.UserField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseUserFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("users list: {s}\n", .{message});
        return 1;
    };

    if (opts.limit == 0) {
        try stderr.print("users list: --limit must be greater than zero\n", .{});
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

    // Deactivated members stay queryable through the API, so the default listing
    // narrows to active members and `--include-inactive` drops the filter.
    if (!opts.include_inactive) {
        var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try eq_obj.object.put(var_alloc, "eq", .{ .bool = true });

        var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
        try filter.object.put(var_alloc, "active", eq_obj);
        try variables.object.put(var_alloc, "filter", filter);
    }

    const query =
        \\query Users($first: Int!, $filter: UserFilter) {
        \\  users(first: $first, filter: $filter) {
        \\    nodes { id name displayName email active }
        \\    pageInfo { hasNextPage endCursor }
        \\  }
        \\}
    ;

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var response = common.send(ctx.allocator, "users list", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "Users",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "users list", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("users list: response missing data\n", .{});
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

    const users_obj = common.getObjectField(data_value, "users") orelse {
        try stderr.print("users list: users not found in response\n", .{});
        return 1;
    };
    const nodes_array = common.getArrayField(users_obj, "nodes") orelse {
        try stderr.print("users list: nodes missing in response\n", .{});
        return 1;
    };
    const page_info = common.getObjectField(users_obj, "pageInfo");
    const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
    const end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;

    var rows = std.ArrayListUnmanaged(printer.UserRow).empty;
    defer rows.deinit(ctx.allocator);
    var data_rows = std.ArrayListUnmanaged(DataRow).empty;
    defer data_rows.deinit(ctx.allocator);

    for (nodes_array.items) |node| {
        if (node != .object) continue;
        const id = common.getStringField(node, "id") orelse continue;
        const name = common.getStringField(node, "name") orelse "";
        const display_name = common.getStringField(node, "displayName") orelse "";
        const email = common.getStringField(node, "email") orelse "";
        const active = if (common.getBoolField(node, "active")) |value|
            if (value) "true" else "false"
        else
            "";

        if (want_table) {
            try rows.append(ctx.allocator, .{
                .id = id,
                .name = name,
                .display_name = display_name,
                .email = email,
                .active = active,
            });
        }
        if (want_data_rows) {
            try data_rows.append(ctx.allocator, .{
                .id = id,
                .name = name,
                .display_name = display_name,
                .email = email,
                .active = active,
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
        try printer.printUserTable(ctx.allocator, stdout_iface, rows.items, selected_fields, table_opts);
    }

    if (has_next and !ctx.json_output) {
        const cursor_value = end_cursor orelse "(unknown)";
        try stderr.print("users list: more users available; pagination not implemented (endCursor {s})\n", .{cursor_value});
    }

    return 0;
}

fn fieldKey(field: printer.UserField) []const u8 {
    return switch (field) {
        .id => "id",
        .name => "name",
        .display_name => "displayName",
        .email => "email",
        .active => "active",
    };
}

fn cellValue(row: DataRow, field: printer.UserField) []const u8 {
    return switch (field) {
        .id => row.id,
        .name => row.name,
        .display_name => row.display_name,
        .email => row.email,
        .active => row.active,
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
        if (std.mem.eql(u8, arg, "--include-inactive")) {
            opts.include_inactive = true;
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
        \\Usage: linear users list [--limit N] [--include-inactive] [--fields LIST] [--plain] [--no-truncate] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --limit N            Number of users to fetch (default: 50)
        \\  --include-inactive   Include deactivated members (default: active only)
        \\  --fields LIST        Comma-separated columns (id,name,display_name,email,active)
        \\  --plain              Do not pad or truncate table cells
        \\  --no-truncate        Disable ellipsis and padding in table cells
        \\  --quiet              Print only user ids (one per line)
        \\  --data-only          Emit tab-separated rows (or JSON array with --json)
        \\  --help               Show this help message
        \\Examples:
        \\  linear users list --fields id,email
        \\  linear users list --include-inactive --data-only
        \\  linear issues list --team ENG --assignee <id from 'linear users list'>
        \\
    , .{});
}

fn parseUserFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(printer.UserField), allocator: Allocator) ![]const printer.UserField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseUserFieldName(trimmed) orelse return error.InvalidField;
            if (!containsUserField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.user_default_fields[0..];
}

fn parseUserFieldName(name: []const u8) ?printer.UserField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    if (std.ascii.eqlIgnoreCase(name, "display_name") or std.ascii.eqlIgnoreCase(name, "displayName")) return .display_name;
    if (std.ascii.eqlIgnoreCase(name, "email")) return .email;
    if (std.ascii.eqlIgnoreCase(name, "active")) return .active;
    return null;
}

fn containsUserField(haystack: []const printer.UserField, needle: printer.UserField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}
