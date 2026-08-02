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
    body: ?[]const u8 = null,
    body_file: ?[]const u8 = null,
    parent: ?[]const u8 = null,
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
        try stderr.print("issue comment: {s}\n", .{@errorName(err)});
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
            try stderr.print("issue comment: missing issue identifier\n", .{});
            return 1;
        };
        inferred = git.requireInferredIdentifier(runner, ctx.allocator, ctx.io, stderr, "issue comment") catch {
            return 1;
        };
        break :blk inferred.?;
    };

    if (opts.body == null and opts.body_file == null) {
        try stderr.print("issue comment: --body or --body-file is required\n", .{});
        return 1;
    }

    // Resolved before any network work so a bad path or an oversize file fails
    // without touching the API.
    const body_source = common.resolveContent(
        ctx.allocator,
        ctx.io,
        opts.body,
        opts.body_file,
        stderr,
        "issue comment",
        "--body",
    ) catch {
        return 1;
    };
    defer body_source.deinit(ctx.allocator);
    const body_content = body_source.value orelse "";

    if (body_content.len == 0) {
        try stderr.print("issue comment: comment body cannot be empty\n", .{});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue comment") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const issue_id = common.resolveIssueId(ctx.allocator, &client, target, stderr, "issue comment") catch {
        return 1;
    };
    defer if (issue_id.owned) ctx.allocator.free(issue_id.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    try input.object.put(var_alloc, "issueId", .{ .string = issue_id.value });
    try input.object.put(var_alloc, "body", .{ .string = body_content });
    if (opts.parent) |parent_id| {
        const trimmed = std.mem.trim(u8, parent_id, " \t");
        if (trimmed.len == 0) {
            try stderr.print("issue comment: invalid --parent value\n", .{});
            return 1;
        }
        try input.object.put(var_alloc, "parentId", .{ .string = trimmed });
    }

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "input", input);

    if (!opts.yes) {
        try stderr.print("issue comment: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const mutation =
        \\mutation CommentCreate($input: CommentCreateInput!) {
        \\  commentCreate(input: $input) {
        \\    success
        \\    comment {
        \\      id
        \\      body
        \\      url
        \\      parent {
        \\        id
        \\      }
        \\      issue {
        \\        identifier
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue comment", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "CommentCreate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue comment", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue comment: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "commentCreate") orelse {
        try stderr.print("issue comment: commentCreate missing in response\n", .{});
        return 1;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    const comment_obj = common.getObjectField(payload, "comment");
    if (!success) {
        if (payload.object.get("userError")) |user_error| {
            if (user_error == .string) {
                try stderr.print("issue comment: {s}\n", .{user_error.string});
                return 1;
            }
            if (user_error == .object) {
                if (user_error.object.get("message")) |msg| {
                    if (msg == .string) {
                        try stderr.print("issue comment: {s}\n", .{msg.string});
                        return 1;
                    }
                }
            }
        }
        try stderr.print("issue comment: request failed\n", .{});
        return 1;
    }

    const comment = comment_obj orelse {
        try stderr.print("issue comment: comment missing in response\n", .{});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const comment_id = common.getStringField(comment, "id") orelse "(unknown)";
    const url = common.getStringField(comment, "url") orelse "";
    const issue_obj = common.getObjectField(comment, "issue");
    const identifier = if (issue_obj) |iss| common.getStringField(iss, "identifier") else null;
    const identifier_value = identifier orelse target;
    const parent_obj = common.getObjectField(comment, "parent");
    const parent_id = if (parent_obj) |p| common.getStringField(p, "id") else null;

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(comment_id);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    var pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer pairs.deinit(ctx.allocator);
    var data_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer data_pairs.deinit(ctx.allocator);

    try pairs.append(ctx.allocator, .{ .key = "Issue", .value = identifier_value });
    try data_pairs.append(ctx.allocator, .{ .key = "issue", .value = identifier_value });
    try pairs.append(ctx.allocator, .{ .key = "Comment", .value = comment_id });
    try data_pairs.append(ctx.allocator, .{ .key = "comment", .value = comment_id });
    if (parent_id) |value| {
        try pairs.append(ctx.allocator, .{ .key = "Parent", .value = value });
        try data_pairs.append(ctx.allocator, .{ .key = "parent", .value = value });
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
        if (std.mem.eql(u8, arg, "--body")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.body = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--body=")) {
            opts.body = arg["--body=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--body-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.body_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--body-file=")) {
            opts.body_file = arg["--body-file=".len..];
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
        \\Usage: linear issue comment [ID|IDENTIFIER] --body TEXT [--parent COMMENT_ID] [--yes] [--quiet] [--data-only] [--help]
        \\Without an identifier the issue is inferred from the current branch name.
        \\       linear issue comment <ID|IDENTIFIER> --body-file PATH [--parent COMMENT_ID] [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --body TEXT          Comment body text
        \\  --body-file PATH     Read comment body from file (use '-' for stdin)
        \\  --parent COMMENT_ID  Reply to an existing comment (threaded reply)
        \\  --yes                Skip confirmation prompt (alias: --force)
        \\  --quiet              Print only the comment id
        \\  --data-only          Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help               Show this help message
        \\Examples:
        \\  linear issue comment ENG-123 --body "This is a comment" --yes
        \\  linear issue comment ENG-123 --body-file /path/to/comment.md --yes
        \\  cat comment.md | linear issue comment ENG-123 --body-file - --yes
        \\  linear issue comment ENG-123 --body "Replying" --parent comment-1 --yes
        \\
    , .{});
}

test "parseOptions handles --body flag" {
    const args = [_][]const u8{ "ENG-123", "--body", "test comment", "--yes" };
    const opts = try parseOptions(&args);
    try std.testing.expectEqualStrings("ENG-123", opts.identifier.?);
    try std.testing.expectEqualStrings("test comment", opts.body.?);
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.body_file == null);
}

test "parseOptions handles --body= syntax" {
    const args = [_][]const u8{ "ENG-123", "--body=test comment" };
    const opts = try parseOptions(&args);
    try std.testing.expectEqualStrings("ENG-123", opts.identifier.?);
    try std.testing.expectEqualStrings("test comment", opts.body.?);
}

test "parseOptions handles --body-file flag" {
    const args = [_][]const u8{ "ENG-123", "--body-file", "/path/to/file.md", "--yes" };
    const opts = try parseOptions(&args);
    try std.testing.expectEqualStrings("ENG-123", opts.identifier.?);
    try std.testing.expectEqualStrings("/path/to/file.md", opts.body_file.?);
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.body == null);
}

test "parseOptions handles stdin indicator" {
    const args = [_][]const u8{ "ENG-123", "--body-file", "-" };
    const opts = try parseOptions(&args);
    try std.testing.expectEqualStrings("-", opts.body_file.?);
}

test "parseOptions rejects unknown flags" {
    const args = [_][]const u8{ "ENG-123", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseOptions(&args));
}

test "parseOptions handles --help flag" {
    const args = [_][]const u8{"--help"};
    const opts = try parseOptions(&args);
    try std.testing.expect(opts.help);
}

test "parseOptions handles --quiet flag" {
    const args = [_][]const u8{ "ENG-123", "--body", "test", "--quiet" };
    const opts = try parseOptions(&args);
    try std.testing.expect(opts.quiet);
}

test "parseOptions handles --data-only flag" {
    const args = [_][]const u8{ "ENG-123", "--body", "test", "--data-only" };
    const opts = try parseOptions(&args);
    try std.testing.expect(opts.data_only);
}
