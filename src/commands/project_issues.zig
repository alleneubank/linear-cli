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
    project_id: ?[]const u8 = null,
    issue_id: ?[]const u8 = null,
    yes: bool = false,
    help: bool = false,
    quiet: bool = false,
    data_only: bool = false,
};

const Mode = enum { add, remove };

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;

    if (ctx.args.len == 0) {
        try usage(stderr);
        return 1;
    }

    const sub = ctx.args[0];
    const rest = ctx.args[1..];
    if (std.mem.eql(u8, sub, "add-issue")) {
        return runModify(ctx, .add, rest);
    }
    if (std.mem.eql(u8, sub, "remove-issue")) {
        return runModify(ctx, .remove, rest);
    }

    try stderr.print("project: unknown command: {s}\n", .{sub});
    try usage(stderr);
    return 1;
}

fn runModify(ctx: Context, mode: Mode, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const prefix = switch (mode) {
        .add => "project add-issue",
        .remove => "project remove-issue",
    };

    const opts = parseOptions(args) catch |err| {
        try stderr.print("{s}: {s}\n", .{ prefix, @errorName(err) });
        switch (mode) {
            .add => addUsage(stderr) catch {},
            .remove => removeUsage(stderr) catch {},
        }
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        switch (mode) {
            .add => try addUsage(&out_writer.interface),
            .remove => try removeUsage(&out_writer.interface),
        }
        return 0;
    }

    const project_id = opts.project_id orelse {
        try stderr.print("{s}: missing project id\n", .{prefix});
        return 1;
    };
    const issue_id = opts.issue_id orelse {
        try stderr.print("{s}: missing issue id\n", .{prefix});
        return 1;
    };

    if (!opts.yes) {
        try stderr.print("{s}: confirmation required; re-run with --yes to proceed\n", .{prefix});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, prefix) catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const resolved = common.resolveProjectId(ctx.allocator, &client, project_id, stderr, prefix) catch {
        return 1;
    };
    defer if (resolved.owned) ctx.allocator.free(resolved.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    switch (mode) {
        .add => try input.object.put(var_alloc, "projectId", .{ .string = resolved.value }),
        .remove => try input.object.put(var_alloc, "projectId", .{ .null = {} }),
    }

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = issue_id });
    try variables.object.put(var_alloc, "input", input);

    const mutation =
        \\mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
        \\  issueUpdate(id: $id, input: $input) {
        \\    success
        \\    issue { id identifier project { name } }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, prefix, &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "IssueUpdate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, prefix, &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return 1;
    };

    const payload = common.getObjectField(data_value, "issueUpdate") orelse {
        try stderr.print("{s}: issueUpdate missing in response\n", .{prefix});
        return 1;
    };
    const success = common.getBoolField(payload, "success") orelse false;
    const issue_obj = common.getObjectField(payload, "issue");
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("{s}: {s}\n", .{ prefix, user_error.string });
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("{s}: {s}\n", .{ prefix, msg.string });
                        return 1;
                    }
                }
            }
        }
        try stderr.print("{s}: request failed\n", .{prefix});
        return 1;
    }

    const issue = issue_obj orelse {
        try stderr.print("{s}: issue missing in response\n", .{prefix});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const identifier = common.getStringField(issue, "identifier") orelse "(unknown)";
    const project_obj = common.getObjectField(issue, "project");
    const project_name = if (project_obj) |proj| common.getStringField(proj, "name") else null;

    const quiet_value = identifier;
    const project_value = switch (mode) {
        .add => project_name orelse resolved.value,
        .remove => resolved.value,
    };
    const project_label = switch (mode) {
        .add => "Project",
        .remove => "Removed from",
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(quiet_value);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    if (opts.data_only) {
        if (ctx.json_output) {
            var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try data_obj.object.put(var_alloc, "identifier", .{ .string = identifier });
            try data_obj.object.put(var_alloc, "project", .{ .string = project_value });
            try printer.printJson(data_obj, stdout_iface, true);
            return 0;
        }

        const data_pairs = [_]printer.KeyValue{
            .{ .key = "identifier", .value = identifier },
            .{ .key = "project", .value = project_value },
        };
        try printer.printKeyValuesPlain(stdout_iface, data_pairs[0..]);
        return 0;
    }

    const pairs = [_]printer.KeyValue{
        .{ .key = "Identifier", .value = identifier },
        .{ .key = project_label, .value = project_value },
    };
    try printer.printKeyValues(stdout_iface, pairs[0..]);
    return 0;
}

pub fn parseOptions(args: [][]const u8) !Options {
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
        if (opts.project_id == null) {
            opts.project_id = arg;
            idx += 1;
            continue;
        }
        if (opts.issue_id == null) {
            opts.issue_id = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear project add-issue|remove-issue <PROJECT_ID> <ISSUE_ID> --yes [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --yes         Skip confirmation prompt (alias: --force)
        \\  --quiet       Print only the identifier
        \\  --data-only   Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help        Show this help message
        \\Examples:
        \\  linear project add-issue a6e7e3aa-53d0-42ab-9049-ac7aaa51f732 ENG-42 --yes
        \\  linear project remove-issue 0949c8955675 ENG-42 --yes
        \\
    , .{});
}

pub fn addUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear project add-issue <PROJECT_ID> <ISSUE_ID> --yes [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --yes         Skip confirmation prompt (alias: --force)
        \\  --quiet       Print only the identifier
        \\  --data-only   Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help        Show this help message
        \\Examples:
        \\  linear project add-issue a6e7e3aa-53d0-42ab-9049-ac7aaa51f732 ENG-42 --yes
        \\
    , .{});
}

pub fn removeUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear project remove-issue <PROJECT_ID> <ISSUE_ID> --yes [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --yes         Skip confirmation prompt (alias: --force)
        \\  --quiet       Print only the identifier
        \\  --data-only   Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help        Show this help message
        \\Examples:
        \\  linear project remove-issue 0949c8955675 ENG-42 --yes
        \\
    , .{});
}
