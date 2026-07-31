const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");
const git = @import("git");

const Allocator = std.mem.Allocator;

const prefix = "issue start";

pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    config: *config.Config,
    args: [][]const u8,
    json_output: bool,
    retries: u8,
    timeout_ms: u32,
    endpoint: ?[]const u8 = null,
    /// `null` disables every subprocess this command would otherwise start.
    /// `main.zig` installs `git.system_runner`; tests inject a fake.
    git_runner: ?git.Runner = null,
};

const Options = struct {
    identifier: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    from_ref: ?[]const u8 = null,
    yes: bool = false,
    help: bool = false,
    quiet: bool = false,
    data_only: bool = false,
};

/// A workflow state the issue can be moved into.
const StateRef = struct {
    id: []const u8,
    name: []const u8,
    /// Linear orders a team's workflow in the UI by `position`; taking the
    /// lowest one makes "the team's first started state" deterministic rather
    /// than dependent on the order the API happened to return.
    position: f64,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        try stderr.print("{s}: {s}\n", .{ prefix, @errorName(err) });
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    // Checked before anything is fetched, checked out, or mutated.
    if (!opts.yes) {
        try stderr.print("{s}: confirmation required; re-run with --yes to proceed\n", .{prefix});
        return 1;
    }

    if (opts.branch) |value| {
        git.validateRefArg(value) catch |err| {
            try stderr.print("{s}: --branch {s}\n", .{ prefix, git.refErrorText(err) });
            return 1;
        };
    }
    if (opts.from_ref) |value| {
        git.validateRefArg(value) catch |err| {
            try stderr.print("{s}: --from-ref {s}\n", .{ prefix, git.refErrorText(err) });
            return 1;
        };
    }

    var inferred: ?[]u8 = null;
    defer if (inferred) |value| ctx.allocator.free(value);
    const target = opts.identifier orelse blk: {
        inferred = git.requireInferredIdentifier(ctx.git_runner, ctx.allocator, ctx.io, stderr, prefix) catch {
            return 1;
        };
        break :blk inferred.?;
    };

    const runner = ctx.git_runner orelse {
        try stderr.print("{s}: git integration is unavailable\n", .{prefix});
        return 1;
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, prefix) catch {
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

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = target });

    const query =
        \\query IssueStart($id: String!) {
        \\  issue(id: $id) {
        \\    id
        \\    identifier
        \\    title
        \\    url
        \\    branchName
        \\    state { id name type }
        \\    team {
        \\      id
        \\      states { nodes { id name type position } }
        \\    }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, prefix, &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "IssueStart",
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
    const issue = common.getObjectField(data_value, "issue") orelse {
        try stderr.print("{s}: issue '{s}' not found\n", .{ prefix, target });
        return 1;
    };

    const issue_id = common.getStringField(issue, "id") orelse {
        try stderr.print("{s}: issue id missing in response\n", .{prefix});
        return 1;
    };
    const identifier = common.getStringField(issue, "identifier") orelse target;
    const title = common.getStringField(issue, "title") orelse "";
    const url = common.getStringField(issue, "url") orelse "";

    // Linear owns the branch naming convention; the local side never slugifies.
    const branch = opts.branch orelse common.getStringField(issue, "branchName") orelse {
        try stderr.print("{s}: issue has no branchName; pass --branch NAME\n", .{prefix});
        return 1;
    };
    git.validateRefArg(branch) catch |err| {
        try stderr.print("{s}: branch name '{s}' {s}\n", .{ prefix, branch, git.refErrorText(err) });
        return 1;
    };

    const team = common.getObjectField(issue, "team") orelse {
        try stderr.print("{s}: team missing in response\n", .{prefix});
        return 1;
    };
    // Resolved before touching the working tree so a team with no started
    // state fails without leaving a half-done checkout behind.
    const started = findStartedState(team) orelse {
        try stderr.print("{s}: team has no workflow state of type 'started'\n", .{prefix});
        return 1;
    };

    const current_state = common.getObjectField(issue, "state");
    const current_state_id = if (current_state) |state| common.getStringField(state, "id") else null;
    const already_started = if (current_state_id) |id| std.mem.eql(u8, id, started.id) else false;

    checkoutBranch(runner, ctx.allocator, ctx.io, branch, opts.from_ref, stderr) catch {
        return 1;
    };

    if (!already_started) {
        transitionState(ctx, &client, var_alloc, issue_id, started.id, api_key, stderr) catch {
            return 1;
        };
    }

    var pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer pairs.deinit(ctx.allocator);
    var data_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer data_pairs.deinit(ctx.allocator);

    try pairs.append(ctx.allocator, .{ .key = "Identifier", .value = identifier });
    try data_pairs.append(ctx.allocator, .{ .key = "identifier", .value = identifier });
    try pairs.append(ctx.allocator, .{ .key = "Title", .value = title });
    try data_pairs.append(ctx.allocator, .{ .key = "title", .value = title });
    try pairs.append(ctx.allocator, .{ .key = "Branch", .value = branch });
    try data_pairs.append(ctx.allocator, .{ .key = "branch", .value = branch });
    try pairs.append(ctx.allocator, .{ .key = "State", .value = started.name });
    try data_pairs.append(ctx.allocator, .{ .key = "state", .value = started.name });
    try pairs.append(ctx.allocator, .{ .key = "URL", .value = url });
    try data_pairs.append(ctx.allocator, .{ .key = "url", .value = url });

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(identifier);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    if (ctx.json_output) {
        var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        for (data_pairs.items) |pair| {
            try data_obj.object.put(var_alloc, pair.key, .{ .string = pair.value });
        }
        try printer.printJson(data_obj, stdout_iface, true);
        return 0;
    }

    if (opts.data_only) {
        try printer.printKeyValuesPlain(stdout_iface, data_pairs.items);
        return 0;
    }

    try printer.printKeyValues(stdout_iface, pairs.items);
    return 0;
}

/// Checks out `branch`, creating it when it does not exist yet.
fn checkoutBranch(
    runner: git.Runner,
    allocator: Allocator,
    io: std.Io,
    branch: []const u8,
    from_ref: ?[]const u8,
    stderr: *std.Io.Writer,
) !void {
    const verify_argv = git.verifyRefArgv(branch);
    var verify = runner.capture(allocator, io, &verify_argv) catch |err| {
        try stderr.print("{s}: {s} {s}\n", .{ prefix, git.git_binary, git.errorText(err) });
        return common.CommandError.CommandFailed;
    };
    defer verify.deinit(allocator);

    const exists = verify.ok();
    if (exists and from_ref != null) {
        try stderr.print("{s}: branch '{s}' already exists; --from-ref ignored\n", .{ prefix, branch });
    }

    var argv_buffer: [5][]const u8 = undefined;
    const checkout_argv = if (exists) blk: {
        const fixed = git.checkoutArgv(branch);
        argv_buffer[0] = fixed[0];
        argv_buffer[1] = fixed[1];
        argv_buffer[2] = fixed[2];
        break :blk argv_buffer[0..3];
    } else git.checkoutNewArgv(&argv_buffer, branch, from_ref);

    var checkout = runner.capture(allocator, io, checkout_argv) catch |err| {
        try stderr.print("{s}: {s} {s}\n", .{ prefix, git.git_binary, git.errorText(err) });
        return common.CommandError.CommandFailed;
    };
    defer checkout.deinit(allocator);

    // git reports "Switched to branch ..." on stderr; keep it off stdout so
    // --quiet stays machine-readable.
    if (checkout.stderr.len > 0) try stderr.writeAll(checkout.stderr);
    if (checkout.stdout.len > 0) try stderr.writeAll(checkout.stdout);

    if (!checkout.ok()) {
        try stderr.print("{s}: git checkout failed for branch '{s}'\n", .{ prefix, branch });
        return common.CommandError.CommandFailed;
    }
}

fn transitionState(
    ctx: Context,
    client: *graphql.GraphqlClient,
    var_alloc: Allocator,
    issue_id: []const u8,
    state_id: []const u8,
    api_key: []const u8,
    stderr: *std.Io.Writer,
) !void {
    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    try input.object.put(var_alloc, "stateId", .{ .string = state_id });

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = issue_id });
    try variables.object.put(var_alloc, "input", input);

    const mutation =
        \\mutation IssueStartUpdate($id: String!, $input: IssueUpdateInput!) {
        \\  issueUpdate(id: $id, input: $input) {
        \\    success
        \\    issue { id identifier state { name } }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, prefix, client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "IssueStartUpdate",
    }, stderr) catch {
        return common.CommandError.CommandFailed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, prefix, &response, stderr, api_key) catch {
        return common.CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return common.CommandError.CommandFailed;
    };
    const payload = common.getObjectField(data_value, "issueUpdate") orelse {
        try stderr.print("{s}: issueUpdate missing in response\n", .{prefix});
        return common.CommandError.CommandFailed;
    };

    if (common.getBoolField(payload, "success") orelse false) return;

    if (payload.object.get("userError")) |user_error| {
        if (user_error == .string) {
            try stderr.print("{s}: {s}\n", .{ prefix, user_error.string });
            return common.CommandError.CommandFailed;
        }
        if (user_error == .object) {
            if (user_error.object.get("message")) |message| {
                if (message == .string) {
                    try stderr.print("{s}: {s}\n", .{ prefix, message.string });
                    return common.CommandError.CommandFailed;
                }
            }
        }
    }
    try stderr.print("{s}: state transition failed\n", .{prefix});
    return common.CommandError.CommandFailed;
}

fn findStartedState(team: std.json.Value) ?StateRef {
    const states = common.getObjectField(team, "states") orelse return null;
    const nodes = common.getArrayField(states, "nodes") orelse return null;

    var best: ?StateRef = null;
    for (nodes.items) |node| {
        if (node != .object) continue;
        const type_value = common.getStringField(node, "type") orelse continue;
        if (!std.mem.eql(u8, type_value, "started")) continue;
        const id = common.getStringField(node, "id") orelse continue;
        const position = statePosition(node);
        if (best) |current| {
            if (!(position < current.position)) continue;
        }
        best = .{
            .id = id,
            .name = common.getStringField(node, "name") orelse "",
            .position = position,
        };
    }
    return best;
}

/// `WorkflowState.position` is a GraphQL Float. A state without one sorts last
/// rather than winning by accident.
fn statePosition(node: std.json.Value) f64 {
    const value = node.object.get("position") orelse return std.math.inf(f64);
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch std.math.inf(f64),
        else => std.math.inf(f64),
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
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--force")) {
            opts.yes = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--branch")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.branch = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--branch=")) {
            opts.branch = arg["--branch=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--from-ref")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.from_ref = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--from-ref=")) {
            opts.from_ref = arg["--from-ref=".len..];
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
        \\Usage: linear issue start [ID|IDENTIFIER] [--branch NAME] [--from-ref REF] [--yes] [--quiet] [--data-only] [--help]
        \\Checks out the issue's git branch and moves the issue into the team's first 'started' workflow state.
        \\Without an identifier the issue is inferred from the current branch name.
        \\Flags:
        \\  --branch NAME    Use this branch instead of the issue's Linear branchName
        \\  --from-ref REF   Base a newly created branch on REF (ignored when the branch exists)
        \\  --yes            Skip confirmation prompt (alias: --force)
        \\  --quiet          Print only the identifier
        \\  --data-only      Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help           Show this help message
        \\Examples:
        \\  linear issue start ENG-123 --yes
        \\  linear issue start ENG-123 --from-ref main --yes
        \\  linear issue start --branch fix/eng-123 --yes
        \\
    , .{});
}
