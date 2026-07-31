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
    identifier: ?[]const u8 = null,
    yes: bool = false,
    help: bool = false,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        try stderr.print("project delete: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const target = opts.identifier orelse {
        try stderr.print("project delete: missing id\n", .{});
        return 1;
    };

    if (!opts.yes) {
        try stderr.print("project delete: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "project delete") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const resolved = common.resolveProjectId(ctx.allocator, &client, target, stderr, "project delete") catch {
        return 1;
    };
    defer if (resolved.owned) ctx.allocator.free(resolved.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = resolved.value });

    const mutation =
        \\mutation ProjectDelete($id: String!) {
        \\  projectDelete(id: $id) { success }
        \\}
    ;

    var response = common.send(ctx.allocator, "project delete", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "ProjectDelete",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "project delete", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("project delete: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "projectDelete") orelse {
        try stderr.print("project delete: projectDelete missing in response\n", .{});
        return 1;
    };
    const success = common.getBoolField(payload, "success") orelse false;
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("project delete: {s}\n", .{user_error.string});
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("project delete: {s}\n", .{msg.string});
                        return 1;
                    }
                }
            }
        }
        try stderr.print("project delete: request failed\n", .{});
        return 1;
    }

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try out_writer.interface.print("project delete: archived {s}\n", .{target});
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
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--force")) {
            opts.yes = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (opts.identifier == null) {
            opts.identifier = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear project delete <ID> --yes [--help]
        \\Flags:
        \\  --yes    Skip confirmation prompt (alias: --force)
        \\  --help   Show this help message
        \\Examples:
        \\  linear project delete a6e7e3aa-53d0-42ab-9049-ac7aaa51f732 --yes
        \\
    , .{});
}
