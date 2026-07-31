const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");
const git = @import("git");

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
    /// `null` disables branch inference for a missing identifier, and with it
    /// every subprocess this command could start. `main.zig` installs
    /// `git.system_runner`; tests inject a fake.
    git_runner: ?git.Runner = null,
};

const Options = struct {
    identifier: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    state: ?[]const u8 = null,
    priority: ?i64 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    description_file: ?[]const u8 = null,
    project: ?[]const u8 = null,
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
        try stderr.print("issue update: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    var inferred: ?[]u8 = null;
    defer if (inferred) |value| ctx.allocator.free(value);
    const target = opts.identifier orelse blk: {
        const runner = ctx.git_runner orelse {
            try stderr.print("issue update: missing identifier or id\n", .{});
            return 1;
        };
        inferred = git.requireInferredIdentifier(runner, ctx.allocator, ctx.io, stderr, "issue update") catch {
            return 1;
        };
        break :blk inferred.?;
    };

    // Require at least one field to update
    if (opts.assignee == null and opts.parent == null and opts.state == null and opts.priority == null and opts.title == null and opts.project == null and opts.description == null and opts.description_file == null) {
        try stderr.print("issue update: at least one field to update is required\n", .{});
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
        "issue update",
        "--description",
    ) catch {
        return 1;
    };
    defer description_source.deinit(ctx.allocator);

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue update") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    // Resolve assignee "me" to current user ID
    var assignee_id: ?[]const u8 = null;
    if (opts.assignee) |assignee_value| {
        if (std.mem.eql(u8, assignee_value, "me")) {
            assignee_id = resolveCurrentUserId(ctx, &client, var_alloc, stderr) catch |err| {
                try stderr.print("issue update: failed to resolve current user: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else {
            assignee_id = assignee_value;
        }
    }

    var state_id: ?[]const u8 = null;
    if (opts.state) |state_value| {
        state_id = resolveWorkflowStateId(ctx, &client, var_alloc, target, state_value, stderr) catch {
            return 1;
        };
    }

    // `parentId` is a raw issue id, so a human identifier such as ENG-100 has to
    // be looked up first; `resolveIssueId` passes real ids straight through.
    var parent_resolved: ?common.ResolvedId = null;
    defer if (parent_resolved) |resolved| {
        if (resolved.owned) ctx.allocator.free(resolved.value);
    };
    if (opts.parent) |parent_value| {
        parent_resolved = common.resolveIssueId(ctx.allocator, &client, parent_value, stderr, "issue update") catch {
            return 1;
        };
    }

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    if (assignee_id) |aid| {
        try input.object.put(var_alloc, "assigneeId", .{ .string = aid });
    }
    if (parent_resolved) |resolved| {
        try input.object.put(var_alloc, "parentId", .{ .string = resolved.value });
    }
    if (state_id) |state_value| {
        try input.object.put(var_alloc, "stateId", .{ .string = state_value });
    }
    if (opts.priority) |prio| {
        try input.object.put(var_alloc, "priority", .{ .integer = prio });
    }
    if (opts.title) |title_value| {
        try input.object.put(var_alloc, "title", .{ .string = title_value });
    }
    if (description_source.value) |desc| {
        try input.object.put(var_alloc, "description", .{ .string = desc });
    }
    if (opts.project) |project_id| {
        try input.object.put(var_alloc, "projectId", .{ .string = project_id });
    }

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = target });
    try variables.object.put(var_alloc, "input", input);

    if (!opts.yes) {
        try stderr.print("issue update: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const mutation =
        \\mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
        \\  issueUpdate(id: $id, input: $input) {
        \\    success
        \\    issue {
        \\      id
        \\      identifier
        \\      title
        \\      url
        \\      state { name }
        \\      assignee { name }
        \\      project { name }
        \\      parent { identifier }
        \\    }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue update", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "IssueUpdate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue update", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue update: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "issueUpdate") orelse {
        try stderr.print("issue update: issueUpdate missing in response\n", .{});
        return 1;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    const issue_obj = common.getObjectField(payload, "issue");
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("issue update: {s}\n", .{user_error.string});
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("issue update: {s}\n", .{msg.string});
                        return 1;
                    }
                }
            }
        }
        try stderr.print("issue update: request failed\n", .{});
        return 1;
    }

    const issue = issue_obj orelse {
        try stderr.print("issue update: issue missing in response\n", .{});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const identifier = common.getStringField(issue, "identifier") orelse "(unknown)";
    const title_value = common.getStringField(issue, "title") orelse "";
    const url = common.getStringField(issue, "url") orelse "";
    const state_obj = common.getObjectField(issue, "state");
    const state_name = if (state_obj) |st| common.getStringField(st, "name") else null;
    const assignee_obj = common.getObjectField(issue, "assignee");
    const assignee_name = if (assignee_obj) |a| common.getStringField(a, "name") else null;
    const parent_obj = common.getObjectField(issue, "parent");
    const parent_identifier = if (parent_obj) |p| common.getStringField(p, "identifier") else null;
    const project_obj = common.getObjectField(issue, "project");
    const project_name = if (project_obj) |p| common.getStringField(p, "name") else null;

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(identifier);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    var pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer pairs.deinit(ctx.allocator);
    var data_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer data_pairs.deinit(ctx.allocator);

    try pairs.append(ctx.allocator, .{ .key = "Identifier", .value = identifier });
    try data_pairs.append(ctx.allocator, .{ .key = "identifier", .value = identifier });
    try pairs.append(ctx.allocator, .{ .key = "Title", .value = title_value });
    try data_pairs.append(ctx.allocator, .{ .key = "title", .value = title_value });
    if (state_name) |sn| {
        try pairs.append(ctx.allocator, .{ .key = "State", .value = sn });
        try data_pairs.append(ctx.allocator, .{ .key = "state", .value = sn });
    }
    if (assignee_name) |an| {
        try pairs.append(ctx.allocator, .{ .key = "Assignee", .value = an });
        try data_pairs.append(ctx.allocator, .{ .key = "assignee", .value = an });
    }
    if (project_name) |pn| {
        try pairs.append(ctx.allocator, .{ .key = "Project", .value = pn });
        try data_pairs.append(ctx.allocator, .{ .key = "project", .value = pn });
    }
    if (parent_identifier) |pi| {
        try pairs.append(ctx.allocator, .{ .key = "Parent", .value = pi });
        try data_pairs.append(ctx.allocator, .{ .key = "parent", .value = pi });
    }
    try pairs.append(ctx.allocator, .{ .key = "URL", .value = url });
    try data_pairs.append(ctx.allocator, .{ .key = "url", .value = url });

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

    try printer.printKeyValues(stdout_iface, pairs.items);
    return 0;
}

fn resolveCurrentUserId(ctx: Context, client: *graphql.GraphqlClient, allocator: Allocator, stderr: anytype) ![]const u8 {
    const query = "query Viewer { viewer { id } }";

    var response = common.send(ctx.allocator, "issue update", client, .{
        .query = query,
        .variables = null,
        .operation_name = "Viewer",
    }, stderr) catch {
        return error.ResolveFailed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue update", &response, stderr, client.api_key) catch {
        return error.ResolveFailed;
    };

    const data_value = response.data() orelse return error.ResolveFailed;
    const viewer_obj = common.getObjectField(data_value, "viewer") orelse return error.ResolveFailed;
    const user_id = common.getStringField(viewer_obj, "id") orelse return error.ResolveFailed;

    // Dupe the string since response will be freed by defer
    return allocator.dupe(u8, user_id);
}

fn resolveWorkflowStateId(
    ctx: Context,
    client: *graphql.GraphqlClient,
    allocator: Allocator,
    issue_identifier: []const u8,
    state_value: []const u8,
    stderr: anytype,
) ![]const u8 {
    const trimmed = std.mem.trim(u8, state_value, " \t");
    if (trimmed.len == 0) {
        try stderr.print("issue update: invalid --state value\n", .{});
        return common.CommandError.CommandFailed;
    }

    if (common.looksLikeWorkflowStateId(trimmed)) {
        return trimmed;
    }

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(allocator, "id", .{ .string = issue_identifier });

    const query =
        \\query IssueStateLookup($id: String!) {
        \\  issue(id: $id) {
        \\    id
        \\    team {
        \\      id
        \\      states { nodes { id name } }
        \\    }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue update", client, .{
        .query = query,
        .variables = variables,
        .operation_name = "IssueStateLookup",
    }, stderr) catch {
        return common.CommandError.CommandFailed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue update", &response, stderr, client.api_key) catch {
        return common.CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue update: response missing data\n", .{});
        return common.CommandError.CommandFailed;
    };
    const issue_obj = common.getObjectField(data_value, "issue") orelse {
        try stderr.print("issue update: issue not found\n", .{});
        return common.CommandError.CommandFailed;
    };
    const team_obj = common.getObjectField(issue_obj, "team") orelse {
        try stderr.print("issue update: team missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    const states_obj = common.getObjectField(team_obj, "states") orelse {
        try stderr.print("issue update: workflow states missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    const nodes = common.getArrayField(states_obj, "nodes") orelse {
        try stderr.print("issue update: workflow states missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    if (nodes.items.len == 0) {
        try stderr.print("issue update: no workflow states found for issue\n", .{});
        return common.CommandError.CommandFailed;
    }

    var available = std.ArrayListUnmanaged(u8).empty;
    defer available.deinit(ctx.allocator);
    var first = true;

    for (nodes.items) |node| {
        if (node != .object) continue;
        const name_value = common.getStringField(node, "name") orelse continue;
        const name_trimmed = std.mem.trim(u8, name_value, " \t");
        if (name_trimmed.len == 0) continue;

        if (!first) try available.appendSlice(ctx.allocator, ", ");
        try available.appendSlice(ctx.allocator, name_trimmed);
        first = false;

        const matches_name = std.ascii.eqlIgnoreCase(name_trimmed, trimmed);
        const id_value = common.getStringField(node, "id") orelse {
            if (matches_name) {
                try stderr.print("issue update: workflow state id missing for '{s}'\n", .{name_trimmed});
                return common.CommandError.CommandFailed;
            }
            continue;
        };
        const matches_id = std.mem.eql(u8, id_value, trimmed);
        if (!matches_name and !matches_id) continue;

        const duped = allocator.dupe(u8, id_value) catch {
            try stderr.print("issue update: failed to allocate state id\n", .{});
            return common.CommandError.CommandFailed;
        };
        return duped;
    }

    try stderr.print("issue update: state '{s}' not found", .{trimmed});
    if (available.items.len > 0) {
        try stderr.print("; available states: {s}\n", .{available.items});
    } else {
        try stderr.print("\n", .{});
    }
    return common.CommandError.CommandFailed;
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
        if (std.mem.eql(u8, arg, "--parent")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.parent = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--parent=")) {
            opts.parent = arg["--parent=".len..];
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
        \\Usage: linear issue update [ID|IDENTIFIER] [--assignee USER_ID|me] [--parent ID|IDENTIFIER] [--state STATE_ID|NAME] [--priority N] [--title TEXT] [--description TEXT|--description-file PATH] [--project PROJECT_ID] [--yes] [--quiet] [--data-only] [--help]
        \\Without an identifier the issue is inferred from the current branch name.
        \\Flags:
        \\  --assignee USER_ID|me  Assign to user (use 'me' for current user)
        \\  --parent ID|IDENTIFIER Set parent issue (make sub-issue); accepts ENG-100 or an issue id
        \\  --state STATE_ID|NAME  Change workflow state
        \\  --priority N           Set priority (0-4)
        \\  --title TEXT           Update title
        \\  --description TEXT     Update description
        \\  --description-file PATH  Read the description from a file (use '-' for stdin)
        \\  --project PROJECT_ID   Attach to project
        \\  --yes                  Skip confirmation prompt (alias: --force)
        \\  --quiet                Print only the identifier
        \\  --data-only            Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help                 Show this help message
        \\Examples:
        \\  linear issue update ENG-123 --assignee me --yes
        \\  linear issue update ENG-123 --parent ENG-100 --yes
        \\  linear issue update ENG-123 --priority 1 --state done --yes
        \\  linear issue update ENG-123 --description-file body.md --yes
        \\
    , .{});
}
