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
        try stderr.print("teams: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "teams") catch {
        return 1;
    };

    var field_buf = std.ArrayListUnmanaged(printer.TeamField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseTeamFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("teams: {s}\n", .{message});
        return 1;
    };
    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "first", .{ .integer = 50 });

    const query =
        \\query Teams($first: Int!) {
        \\  teams(first: $first) {
        \\    nodes {
        \\      id
        \\      key
        \\      name
        \\    }
        \\  }
        \\}
    ;

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var response = common.send(ctx.allocator, "teams", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "Teams",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "teams", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("teams: response missing data\n", .{});
        return 1;
    };

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const teams_obj = common.getObjectField(data_value, "teams") orelse {
        try stderr.print("teams: teams not found in response\n", .{});
        return 1;
    };
    const nodes_array = common.getArrayField(teams_obj, "nodes") orelse {
        try stderr.print("teams: nodes missing in response\n", .{});
        return 1;
    };

    var rows = std.ArrayListUnmanaged(printer.TeamRow).empty;
    defer rows.deinit(ctx.allocator);

    for (nodes_array.items) |node| {
        if (node != .object) continue;
        const id = common.getStringField(node, "id") orelse continue;
        const key = common.getStringField(node, "key") orelse "";
        const name = common.getStringField(node, "name") orelse "";
        try rows.append(ctx.allocator, .{ .id = id, .key = key, .name = name });
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try printer.printTeamTable(ctx.allocator, &out_writer.interface, rows.items, selected_fields, table_opts);
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

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear teams list [--fields LIST] [--plain] [--no-truncate] [--help]
        \\Flags:
        \\  --fields LIST   Comma-separated columns (id,key,name)
        \\  --plain         Do not pad or truncate table cells
        \\  --no-truncate   Disable ellipsis and padding in table cells
        \\  --help          Show this help message
        \\Examples:
        \\  linear teams list --fields id,key
        \\
    , .{});
}

fn parseTeamFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(printer.TeamField), allocator: Allocator) ![]const printer.TeamField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseTeamFieldName(trimmed) orelse return error.InvalidField;
            if (!containsTeamField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.team_default_fields[0..];
}

fn parseTeamFieldName(name: []const u8) ?printer.TeamField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "key")) return .key;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    return null;
}

fn containsTeamField(haystack: []const printer.TeamField, needle: printer.TeamField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}
