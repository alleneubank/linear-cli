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
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
    content_file: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
    target_date: ?[]const u8 = null,
    state: ?[]const u8 = null,
    yes: bool = false,
    help: bool = false,
    quiet: bool = false,
    data_only: bool = false,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        try stderr.print("project update: {s}\n", .{@errorName(err)});
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
        try stderr.print("project update: missing id\n", .{});
        return 1;
    };

    if (opts.name == null and opts.description == null and opts.content == null and
        opts.content_file == null and opts.start_date == null and opts.target_date == null and
        opts.state == null)
    {
        try stderr.print("project update: at least one field to update is required\n", .{});
        return 1;
    }

    // Resolved before any network work so a bad path or an oversize file fails
    // without touching the API.
    const content_source = common.resolveContent(
        ctx.allocator,
        ctx.io,
        opts.content,
        opts.content_file,
        stderr,
        "project update",
        "--content",
    ) catch {
        return 1;
    };
    defer content_source.deinit(ctx.allocator);

    const api_key = common.requireApiKey(ctx.config, null, stderr, "project update") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var status_id: ?[]const u8 = null;
    defer if (status_id) |sid| ctx.allocator.free(sid);

    const resolved = common.resolveProjectId(ctx.allocator, &client, target, stderr, "project update") catch {
        return 1;
    };
    defer if (resolved.owned) ctx.allocator.free(resolved.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    if (opts.name) |name_value| try input.object.put(var_alloc, "name", .{ .string = name_value });
    if (opts.description) |desc| try input.object.put(var_alloc, "description", .{ .string = desc });
    // `description` is capped at 255 characters by Linear; long-form project
    // text belongs in the separate `content` field.
    if (content_source.value) |content_value| try input.object.put(var_alloc, "content", .{ .string = content_value });
    if (opts.start_date) |start_value| try input.object.put(var_alloc, "startDate", .{ .string = start_value });
    if (opts.target_date) |target_value| try input.object.put(var_alloc, "targetDate", .{ .string = target_value });
    if (opts.state) |state_value| {
        status_id = common.resolveProjectStatusId(ctx.allocator, &client, state_value, stderr, "project update") catch {
            return 1;
        };
    }
    if (status_id) |sid| try input.object.put(var_alloc, "statusId", .{ .string = sid });

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = resolved.value });
    try variables.object.put(var_alloc, "input", input);

    if (!opts.yes) {
        try stderr.print("project update: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const mutation =
        \\mutation ProjectUpdate($id: String!, $input: ProjectUpdateInput!) {
        \\  projectUpdate(id: $id, input: $input) {
        \\    success
        \\    project { id name slugId state url }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "project update", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "ProjectUpdate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "project update", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("project update: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "projectUpdate") orelse {
        try stderr.print("project update: projectUpdate missing in response\n", .{});
        return 1;
    };
    const success = common.getBoolField(payload, "success") orelse false;
    const project_obj = common.getObjectField(payload, "project");
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("project update: {s}\n", .{user_error.string});
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("project update: {s}\n", .{msg.string});
                        return 1;
                    }
                }
            }
        }
        try stderr.print("project update: request failed\n", .{});
        return 1;
    }

    const project = project_obj orelse {
        try stderr.print("project update: project missing in response\n", .{});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const id = common.getStringField(project, "id") orelse "(unknown)";
    const name = common.getStringField(project, "name") orelse "";
    const slug = common.getStringField(project, "slugId") orelse "";
    const state = common.getStringField(project, "state") orelse "";
    const url = common.getStringField(project, "url") orelse "";

    const quiet_value = if (slug.len > 0) slug else id;

    var display_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer display_pairs.deinit(ctx.allocator);
    var data_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer data_pairs.deinit(ctx.allocator);

    try display_pairs.append(ctx.allocator, .{ .key = "ID", .value = id });
    try display_pairs.append(ctx.allocator, .{ .key = "Name", .value = name });
    try display_pairs.append(ctx.allocator, .{ .key = "Slug", .value = slug });
    try display_pairs.append(ctx.allocator, .{ .key = "State", .value = state });
    try display_pairs.append(ctx.allocator, .{ .key = "URL", .value = url });

    try data_pairs.append(ctx.allocator, .{ .key = "id", .value = id });
    try data_pairs.append(ctx.allocator, .{ .key = "name", .value = name });
    try data_pairs.append(ctx.allocator, .{ .key = "slug", .value = slug });
    try data_pairs.append(ctx.allocator, .{ .key = "state", .value = state });
    try data_pairs.append(ctx.allocator, .{ .key = "url", .value = url });

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
            for (data_pairs.items) |pair| {
                try data_obj.object.put(var_alloc, pair.key, .{ .string = pair.value });
            }
            try printer.printJson(data_obj, stdout_iface, true);
            return 0;
        }

        try printer.printKeyValuesPlain(stdout_iface, data_pairs.items);
        return 0;
    }

    try printer.printKeyValues(stdout_iface, display_pairs.items);
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
        if (std.mem.eql(u8, arg, "--name")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.name = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            opts.name = arg["--name=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--description")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.description = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--description=")) {
            opts.description = arg["--description=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--content")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.content = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--content=")) {
            opts.content = arg["--content=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--content-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.content_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--content-file=")) {
            opts.content_file = arg["--content-file=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--start-date")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.start_date = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--start-date=")) {
            opts.start_date = arg["--start-date=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target-date")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.target_date = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target-date=")) {
            opts.target_date = arg["--target-date=".len..];
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
        \\Usage: linear project update <ID> [--name NAME] [--description TEXT] [--content TEXT|--content-file PATH] [--start-date DATE] [--target-date DATE] [--state STATE] [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --name NAME         Update project name
        \\  --description TEXT  Update description (Linear caps this at 255 characters)
        \\  --content TEXT      Update long-form project content (no 255-character cap)
        \\  --content-file PATH Read the project content from a file (use '-' for stdin)
        \\  --start-date DATE   ISO start date
        \\  --target-date DATE  ISO target date
        \\  --state STATE       Update state (backlog, planned, started, paused, completed, canceled)
        \\  --yes               Skip confirmation prompt (alias: --force)
        \\  --quiet             Print only the identifier
        \\  --data-only         Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help              Show this help message
        \\Examples:
        \\  linear project update a6e7e3aa-53d0-42ab-9049-ac7aaa51f732 --name "New Name" --yes
        \\  linear project update 0949c8955675 --state started --yes --json
        \\  linear project update 0949c8955675 --content-file overview.md --target-date 2026-12-31 --yes
        \\
    , .{});
}
