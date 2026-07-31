const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
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
    /// `null` disables branch inference. `main.zig` installs
    /// `git.system_runner`; tests inject a fake.
    git_runner: ?git.Runner = null,
};

/// The four single-purpose accessors. Each writes plain text to stdout and
/// nothing else, so the output can be substituted directly into a shell
/// command; output-format flags deliberately do not apply.
pub const Mode = enum {
    id,
    url,
    title,
    describe,

    fn prefix(self: Mode) []const u8 {
        return switch (self) {
            .id => "issue id",
            .url => "issue url",
            .title => "issue title",
            .describe => "issue describe",
        };
    }
};

const Options = struct {
    identifier: ?[]const u8 = null,
    references: bool = false,
    help: bool = false,
};

pub fn modeFromName(name: []const u8) ?Mode {
    if (std.mem.eql(u8, name, "id")) return .id;
    if (std.mem.eql(u8, name, "url")) return .url;
    if (std.mem.eql(u8, name, "title")) return .title;
    if (std.mem.eql(u8, name, "describe")) return .describe;
    return null;
}

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;

    if (ctx.args.len == 0) {
        try usage(stderr);
        return 1;
    }

    const mode = modeFromName(ctx.args[0]) orelse {
        try stderr.print("issue: unknown command: {s}\n", .{ctx.args[0]});
        try usage(stderr);
        return 1;
    };
    return runMode(ctx, mode, ctx.args[1..]);
}

fn runMode(ctx: Context, mode: Mode, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const prefix = mode.prefix();

    const opts = parseOptions(mode, args) catch |err| {
        const message = switch (err) {
            error.UnsupportedFlag => "--references is only valid for 'issue describe'",
            else => @errorName(err),
        };
        try stderr.print("{s}: {s}\n", .{ prefix, message });
        try modeUsage(mode, stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try modeUsage(mode, &out_writer.interface);
        return 0;
    }

    var inferred: ?[]u8 = null;
    defer if (inferred) |value| ctx.allocator.free(value);
    const target = opts.identifier orelse blk: {
        inferred = git.requireInferredIdentifier(ctx.git_runner, ctx.allocator, ctx.io, stderr, prefix) catch {
            return 1;
        };
        break :blk inferred.?;
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    // `issue id` is answered entirely from the branch (or the argument), which
    // is the point of it: no request, no API key.
    if (mode == .id) {
        try stdout_iface.writeAll(target);
        try stdout_iface.writeByte('\n');
        return 0;
    }

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
        \\query IssueRef($id: String!) {
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
        .operation_name = "IssueRef",
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
    const url = common.getStringField(issue, "url") orelse "";

    switch (mode) {
        .id => unreachable, // handled above, before the request
        .url => {
            try stdout_iface.writeAll(url);
            try stdout_iface.writeByte('\n');
        },
        .title => {
            try stdout_iface.writeAll(title);
            try stdout_iface.writeByte('\n');
        },
        .describe => {
            try writeDescription(stdout_iface, identifier, title, url, opts.references);
        },
    }
    return 0;
}

/// Commit-message body: a subject line, then git trailers Linear can parse.
pub fn writeDescription(
    writer: *std.Io.Writer,
    identifier: []const u8,
    title: []const u8,
    url: []const u8,
    references: bool,
) !void {
    const verb: []const u8 = if (references) "References" else "Fixes";
    try writer.print("{s} {s}\n\nLinear-issue: {s} {s}\nLinear-issue-url: {s}\n", .{
        identifier,
        title,
        verb,
        identifier,
        url,
    });
}

pub fn parseOptions(mode: Mode, args: []const []const u8) !Options {
    var opts = Options{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--references")) {
            if (mode != .describe) return error.UnsupportedFlag;
            opts.references = true;
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

fn modeUsage(mode: Mode, writer: *std.Io.Writer) !void {
    return switch (mode) {
        .id => idUsage(writer),
        .url => urlUsage(writer),
        .title => titleUsage(writer),
        .describe => describeUsage(writer),
    };
}

pub fn idUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue id [ID|IDENTIFIER] [--help]
        \\Prints the issue identifier on a single line. Without an argument it is inferred
        \\from the current branch name. Makes no API request, so no API key is needed and
        \\an explicit argument is echoed back unchanged.
        \\Examples:
        \\  linear issue id
        \\  git commit -m "$(linear issue id): fix the thing"
        \\
    , .{});
}

pub fn urlUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue url [ID|IDENTIFIER] [--help]
        \\Prints the issue URL on a single line. Without an argument the issue is inferred
        \\from the current branch name.
        \\Examples:
        \\  linear issue url
        \\  open "$(linear issue url ENG-123)"
        \\
    , .{});
}

pub fn titleUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue title [ID|IDENTIFIER] [--help]
        \\Prints the issue title on a single line. Without an argument the issue is inferred
        \\from the current branch name.
        \\Examples:
        \\  linear issue title
        \\  linear issue title ENG-123
        \\
    , .{});
}

pub fn describeUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue describe [ID|IDENTIFIER] [--references] [--help]
        \\Prints a commit message body: a "<IDENTIFIER> <title>" subject line followed by
        \\Linear-issue and Linear-issue-url trailers. Without an argument the issue is
        \\inferred from the current branch name.
        \\Flags:
        \\  --references  Emit "References <ID>" instead of "Fixes <ID>"
        \\  --help        Show this help message
        \\Examples:
        \\  linear issue describe
        \\  git commit -m "$(linear issue describe)"
        \\  git commit -m "$(linear issue describe --references)"
        \\
    , .{});
}

pub fn usage(writer: anytype) !void {
    try idUsage(writer);
    try writer.writeByte('\n');
    try urlUsage(writer);
    try writer.writeByte('\n');
    try titleUsage(writer);
    try writer.writeByte('\n');
    try describeUsage(writer);
}
