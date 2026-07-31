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
    name: ?[]const u8 = null,
    team: ?[]const u8 = null,
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

const ResolvedId = struct {
    value: []const u8,
    owned: bool,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        try stderr.print("project create: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    if (opts.name == null) {
        try stderr.print("project create: --name is required\n", .{});
        return 1;
    }
    if (opts.team == null) {
        try stderr.print("project create: --team is required\n", .{});
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
        "project create",
        "--content",
    ) catch {
        return 1;
    };
    defer content_source.deinit(ctx.allocator);

    const api_key = common.requireApiKey(ctx.config, null, stderr, "project create") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var status_id: ?[]const u8 = null;
    defer if (status_id) |sid| ctx.allocator.free(sid);

    const team_id = resolveTeamId(ctx, &client, opts.team.?, stderr) catch |err| {
        try stderr.print("project create: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (team_id.owned) ctx.allocator.free(team_id.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    try input.object.put(var_alloc, "name", .{ .string = opts.name.? });
    var team_ids = std.json.Array.init(var_alloc);
    try team_ids.append(.{ .string = team_id.value });
    try input.object.put(var_alloc, "teamIds", .{ .array = team_ids });
    if (opts.description) |desc| {
        try input.object.put(var_alloc, "description", .{ .string = desc });
    }
    // `description` is capped at 255 characters by Linear; long-form project
    // text belongs in the separate `content` field.
    if (content_source.value) |content_value| {
        try input.object.put(var_alloc, "content", .{ .string = content_value });
    }
    if (opts.start_date) |start_value| {
        try input.object.put(var_alloc, "startDate", .{ .string = start_value });
    }
    if (opts.target_date) |target_value| {
        try input.object.put(var_alloc, "targetDate", .{ .string = target_value });
    }
    if (opts.state) |state_value| {
        status_id = common.resolveProjectStatusId(ctx.allocator, &client, state_value, stderr, "project create") catch {
            return 1;
        };
    }
    if (status_id) |sid| {
        try input.object.put(var_alloc, "statusId", .{ .string = sid });
    }

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "input", input);

    if (!opts.yes) {
        try stderr.print("project create: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const mutation =
        \\mutation ProjectCreate($input: ProjectCreateInput!) {
        \\  projectCreate(input: $input) {
        \\    success
        \\    project { id name slugId url }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "project create", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "ProjectCreate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "project create", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("project create: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "projectCreate") orelse {
        try stderr.print("project create: projectCreate missing in response\n", .{});
        return 1;
    };
    const success = common.getBoolField(payload, "success") orelse false;
    const project_obj = common.getObjectField(payload, "project");
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("project create: {s}\n", .{user_error.string});
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("project create: {s}\n", .{msg.string});
                        return 1;
                    }
                }
            }
        }
        try stderr.print("project create: request failed\n", .{});
        return 1;
    }

    const project = project_obj orelse {
        try stderr.print("project create: project missing in response\n", .{});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const id = common.getStringField(project, "id") orelse "(unknown)";
    const name = common.getStringField(project, "name") orelse opts.name.?;
    const slug = common.getStringField(project, "slugId") orelse "";
    const url = common.getStringField(project, "url") orelse "";

    const display_pairs = [_]printer.KeyValue{
        .{ .key = "ID", .value = id },
        .{ .key = "Name", .value = name },
        .{ .key = "Slug", .value = slug },
        .{ .key = "URL", .value = url },
    };
    const data_pairs = [_]printer.KeyValue{
        .{ .key = "id", .value = id },
        .{ .key = "name", .value = name },
        .{ .key = "slug", .value = slug },
        .{ .key = "url", .value = url },
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        const quiet_value = if (slug.len > 0) slug else id;
        try stdout_iface.writeAll(quiet_value);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    if (opts.data_only) {
        if (ctx.json_output) {
            var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            for (data_pairs) |pair| {
                try data_obj.object.put(var_alloc, pair.key, .{ .string = pair.value });
            }
            try printer.printJson(data_obj, stdout_iface, true);
            return 0;
        }

        try printer.printKeyValuesPlain(stdout_iface, data_pairs[0..]);
        return 0;
    }

    try printer.printKeyValues(stdout_iface, display_pairs[0..]);
    return 0;
}

fn resolveTeamId(ctx: Context, client: *graphql.GraphqlClient, value: []const u8, stderr: anytype) !ResolvedId {
    if (isUuid(value)) {
        return .{ .value = value, .owned = false };
    }

    if (ctx.config.lookupTeamId(value)) |cached| {
        return .{ .value = cached, .owned = false };
    }

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    try eq_obj.object.put(var_alloc, "eq", .{ .string = value });
    try filter.object.put(var_alloc, "key", eq_obj);

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "filter", filter);
    try variables.object.put(var_alloc, "first", .{ .integer = 1 });

    const query =
        \\query TeamLookup($filter: TeamFilter, $first: Int!) {
        \\  teams(filter: $filter, first: $first) {
        \\    nodes { id }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "project create", client, .{
        .query = query,
        .variables = variables,
        .operation_name = "TeamLookup",
    }, stderr) catch {
        return error.InvalidTeam;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "project create", &response, stderr, client.api_key) catch {
        return error.InvalidTeam;
    };

    const data_value = response.data() orelse return error.InvalidTeam;
    const teams_obj = common.getObjectField(data_value, "teams") orelse return error.InvalidTeam;
    const nodes_array = common.getArrayField(teams_obj, "nodes") orelse return error.InvalidTeam;
    if (nodes_array.items.len == 0) return error.InvalidTeam;
    const node = nodes_array.items[0];
    if (node != .object) return error.InvalidTeam;
    const id_value = common.getStringField(node, "id") orelse return error.InvalidTeam;

    const updated = ctx.config.cacheTeamId(value, id_value) catch |err| blk: {
        try stderr.print("project create: warning: failed to cache team id: {s}\n", .{@errorName(err)});
        break :blk false;
    };
    if (updated) {
        ctx.config.save(ctx.allocator, null) catch |err| {
            try stderr.print("project create: warning: failed to persist team cache: {s}\n", .{@errorName(err)});
        };
        if (ctx.config.lookupTeamId(value)) |cached| {
            return .{ .value = cached, .owned = false };
        }
    } else if (ctx.config.lookupTeamId(value)) |cached| {
        return .{ .value = cached, .owned = false };
    }

    const duped = try ctx.allocator.dupe(u8, id_value);
    return .{ .value = duped, .owned = true };
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (value[idx] != '-') return false;
    }
    return true;
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
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear project create --name NAME --team ID|KEY [--description TEXT] [--content TEXT|--content-file PATH] [--start-date DATE] [--target-date DATE] [--state STATE] [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --name NAME         Project name (required)
        \\  --team ID|KEY       Team id or key (required)
        \\  --description TEXT  Project description (Linear caps this at 255 characters)
        \\  --content TEXT      Long-form project content (no 255-character cap)
        \\  --content-file PATH Read the project content from a file (use '-' for stdin)
        \\  --start-date DATE   ISO start date
        \\  --target-date DATE  ISO target date
        \\  --state STATE       Project state (backlog, planned, started, paused, completed, canceled)
        \\  --yes               Skip confirmation prompt (alias: --force)
        \\  --quiet             Print only the identifier
        \\  --data-only         Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help              Show this help message
        \\Examples:
        \\  linear project create --name \"Roadmap\" --team ENG --state started --yes
        \\  linear project create --name \"API\" --team eng --target-date 2024-12-31 --yes --json
        \\  linear project create --name \"Imported\" --team ENG --content-file overview.md --yes
        \\
    , .{});
}
