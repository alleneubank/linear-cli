const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const common = @import("common");
const git = @import("git");

const Allocator = std.mem.Allocator;

const prefix = "issue pr";

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
    base: ?[]const u8 = null,
    head: ?[]const u8 = null,
    draft: bool = false,
    web: bool = false,
    yes: bool = false,
    help: bool = false,
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

    if (!opts.yes) {
        try stderr.print("{s}: confirmation required; re-run with --yes to proceed\n", .{prefix});
        return 1;
    }

    // `--base`/`--head` are git refs handed straight to `gh`; the same
    // leading-dash rule as every other ref argument applies.
    if (opts.base) |value| {
        git.validateRefArg(value) catch |err| {
            try stderr.print("{s}: --base {s}\n", .{ prefix, git.refErrorText(err) });
            return 1;
        };
    }
    if (opts.head) |value| {
        git.validateRefArg(value) catch |err| {
            try stderr.print("{s}: --head {s}\n", .{ prefix, git.refErrorText(err) });
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
        \\query IssuePullRequest($id: String!) {
        \\  issue(id: $id) {
        \\    identifier
        \\    title
        \\    url
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, prefix, &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "IssuePullRequest",
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

    const identifier = common.getStringField(issue, "identifier") orelse target;
    const title = common.getStringField(issue, "title") orelse "";
    const url = common.getStringField(issue, "url") orelse {
        try stderr.print("{s}: issue url missing in response\n", .{prefix});
        return 1;
    };

    // One allocated string, passed as one argv element. The issue title is
    // attacker-influenceable, so it must never be concatenated into anything a
    // shell would parse -- and no shell is involved here at all.
    const pr_title = try std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ identifier, title });
    defer ctx.allocator.free(pr_title);

    // The Linear issue URL in the body is what Linear's GitHub integration
    // uses to attach the pull request to the issue.
    const argv = try git.pullRequestArgv(ctx.allocator, .{
        .title = pr_title,
        .body = url,
        .base = opts.base,
        .head = opts.head,
        .draft = opts.draft,
        .web = opts.web,
    });
    defer ctx.allocator.free(argv);

    // stdio is inherited so `gh`'s own interactive prompts keep working.
    const exit = runner.inherit(ctx.allocator, ctx.io, argv) catch |err| {
        try stderr.print("{s}: {s} {s}\n", .{ prefix, git.gh_binary, git.errorText(err) });
        return 1;
    };
    if (!exit.ok()) {
        try stderr.print("{s}: gh pr create exited with status {d}\n", .{ prefix, exit.code() });
        return exit.code();
    }
    return 0;
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
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--force")) {
            opts.yes = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--draft")) {
            opts.draft = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--web")) {
            opts.web = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--base")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.base = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--base=")) {
            opts.base = arg["--base=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--head")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.head = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--head=")) {
            opts.head = arg["--head=".len..];
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
        \\Usage: linear issue pr [ID|IDENTIFIER] [--base BRANCH] [--head BRANCH] [--draft] [--web] [--yes] [--help]
        \\Runs 'gh pr create' with the issue identifier and title as the PR title and the issue URL as the body.
        \\Without an identifier the issue is inferred from the current branch name.
        \\Output comes from 'gh', which inherits the terminal so its interactive prompts still work.
        \\Flags:
        \\  --base BRANCH  Pull request base branch (passed to gh)
        \\  --head BRANCH  Pull request head branch (passed to gh)
        \\  --draft        Create the pull request as a draft
        \\  --web          Open the pull request form in a browser
        \\  --yes          Skip confirmation prompt (alias: --force)
        \\  --help         Show this help message
        \\Examples:
        \\  linear issue pr --yes
        \\  linear issue pr ENG-123 --base main --draft --yes
        \\
    , .{});
}
