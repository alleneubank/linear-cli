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
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    description_file: ?[]const u8 = null,
    priority: ?i64 = null,
    state: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    project: ?[]const u8 = null,
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
        try stderr.print("issue create: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    if (opts.team == null) {
        try stderr.print("issue create: --team is required\n", .{});
        return 1;
    }
    if (opts.title == null) {
        try stderr.print("issue create: --title is required\n", .{});
        return 1;
    }

    // Resolved before any network work so a bad path or an oversize file fails
    // without touching the API.
    const description_source = common.resolveContent(
        ctx.allocator,
        ctx.io,
        opts.description,
        opts.description_file,
        stderr,
        "issue create",
        "--description",
    ) catch {
        return 1;
    };
    defer description_source.deinit(ctx.allocator);

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue create") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const team_id = resolveTeamId(ctx, &client, opts.team.?, stderr) catch |err| {
        try stderr.print("issue create: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (team_id.owned) ctx.allocator.free(team_id.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    try input.object.put(var_alloc, "teamId", .{ .string = team_id.value });
    try input.object.put(var_alloc, "title", .{ .string = opts.title.? });
    if (description_source.value) |desc| {
        try input.object.put(var_alloc, "description", .{ .string = desc });
    }
    if (opts.priority) |prio| {
        try input.object.put(var_alloc, "priority", .{ .integer = prio });
    }
    if (opts.state) |state_id| {
        try input.object.put(var_alloc, "stateId", .{ .string = state_id });
    }
    if (opts.assignee) |assignee_id| {
        try input.object.put(var_alloc, "assigneeId", .{ .string = assignee_id });
    }
    if (opts.labels) |labels_value| {
        var label_ids = std.json.Array.init(var_alloc);
        var iter = std.mem.tokenizeScalar(u8, labels_value, ',');
        var added: usize = 0;
        while (iter.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            if (trimmed.len == 0) continue;
            try label_ids.append(.{ .string = trimmed });
            added += 1;
        }
        if (added > 0) {
            try input.object.put(var_alloc, "labelIds", .{ .array = label_ids });
        }
    }
    if (opts.project) |project_id| {
        try input.object.put(var_alloc, "projectId", .{ .string = project_id });
    }

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "input", input);

    if (!opts.yes) {
        try stderr.print("issue create: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const mutation =
        \\mutation IssueCreate($input: IssueCreateInput!) {
        \\  issueCreate(input: $input) {
        \\    success
        \\    issue {
        \\      id
        \\      identifier
        \\      title
        \\      url
        \\    }
        \\    lastSyncId
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue create", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "IssueCreate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue create", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue create: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "issueCreate") orelse {
        try stderr.print("issue create: issueCreate missing in response\n", .{});
        return 1;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    const issue_obj = common.getObjectField(payload, "issue");
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("issue create: {s}\n", .{user_error.string});
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("issue create: {s}\n", .{msg.string});
                        return 1;
                    }
                }
            }
        }
        try stderr.print("issue create: request failed\n", .{});
        return 1;
    }

    const issue = issue_obj orelse {
        try stderr.print("issue create: issue missing in response\n", .{});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const identifier = common.getStringField(issue, "identifier") orelse "(unknown)";
    const title_value = common.getStringField(issue, "title") orelse opts.title.?;
    const url = common.getStringField(issue, "url") orelse "";

    const pairs = [_]printer.KeyValue{
        .{ .key = "Identifier", .value = identifier },
        .{ .key = "Title", .value = title_value },
        .{ .key = "URL", .value = url },
    };
    const data_pairs = [_]printer.KeyValue{
        .{ .key = "identifier", .value = identifier },
        .{ .key = "title", .value = title_value },
        .{ .key = "url", .value = url },
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(identifier);
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

    try printer.printKeyValues(stdout_iface, pairs[0..]);
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

    var response = common.send(ctx.allocator, "issue create", client, .{
        .query = query,
        .variables = variables,
        .operation_name = "TeamLookup",
    }, stderr) catch {
        return error.InvalidTeam;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue create", &response, stderr, client.api_key) catch {
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
        try stderr.print("issue create: warning: failed to cache team id: {s}\n", .{@errorName(err)});
        break :blk false;
    };
    if (updated) {
        ctx.config.save(ctx.allocator, null) catch |err| {
            try stderr.print("issue create: warning: failed to persist team cache: {s}\n", .{@errorName(err)});
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
        if (std.mem.eql(u8, arg, "--title")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.title = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--title=")) {
            opts.title = arg["--title=".len..];
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
        if (std.mem.eql(u8, arg, "--description-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.description_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--description-file=")) {
            opts.description_file = arg["--description-file=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--priority")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.priority = try std.fmt.parseInt(i64, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--priority=")) {
            opts.priority = try std.fmt.parseInt(i64, arg["--priority=".len..], 10);
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
        if (std.mem.eql(u8, arg, "--assignee")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.assignee = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--assignee=")) {
            opts.assignee = arg["--assignee=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--labels")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.labels = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--labels=")) {
            opts.labels = arg["--labels=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.project = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project=")) {
            opts.project = arg["--project=".len..];
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
        \\Usage: linear issue create --team ID|KEY --title TITLE [--description TEXT|--description-file PATH] [--priority N] [--state STATE_ID] [--assignee USER_ID] [--labels ID,ID] [--project PROJECT_ID] [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --team ID|KEY        Team id or key (required)
        \\  --title TITLE        Issue title (required)
        \\  --description TEXT   Issue description
        \\  --description-file PATH  Read the description from a file (use '-' for stdin)
        \\  --priority N         Priority number
        \\  --state STATE_ID     State id to apply
        \\  --assignee USER_ID   Assignee id
        \\  --labels LIST        Comma-separated label ids
        \\  --project PROJECT_ID Attach to project
        \\  --yes                Skip confirmation prompt (alias: --force)
        \\  --quiet              Print only the identifier
        \\  --data-only          Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help               Show this help message
        \\Examples:
        \\  linear issue create --team ENG --title \"Fix bug\" --priority 2
        \\  linear issue create --team ENG --title \"API error\" --labels abc,def --quiet
        \\  linear issue create --team ENG --title \"Imported\" --description-file body.md --yes
        \\  cat body.md | linear issue create --team ENG --title \"Imported\" --description-file - --yes
        \\
    , .{});
}
