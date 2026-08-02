const std = @import("std");
const config = @import("config");
const common = @import("common");

const Allocator = std.mem.Allocator;

pub const upload_prefix = "https://uploads.linear.app/";
const stdout_marker = "-";
const transfer_buffer_len: usize = 16 * 1024;

/// Downloaded attachments may carry private issue content, so they are created
/// owner-only rather than at the process umask default. Matches the mode
/// `issue view --attachment-dir` uses for the same bytes.
pub const download_file_mode = 0o600;

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
    url: ?[]const u8 = null,
    output: ?[]const u8 = null,
    help: bool = false,
};

const OutputTarget = union(enum) {
    stdout,
    path: []const u8,
};

pub const DownloadError = error{
    InvalidUrl,
    MissingFilename,
    EmptyOutputPath,
    RequestTimedOut,
    HttpStatus,
    ResponseReadFailed,
    UnsupportedCompressionMethod,
    RedirectMissingLocation,
    TooManyRedirects,
} || std.mem.Allocator.Error || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || std.http.Reader.BodyError || std.Io.Writer.Error;

pub fn run(ctx: Context) !u8 {
    _ = ctx.json_output;
    _ = ctx.retries;
    _ = ctx.endpoint;

    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        try stderr.print("download: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const url = opts.url orelse {
        try stderr.print("download: missing URL\n", .{});
        return 1;
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "download") catch {
        return 1;
    };

    const output_target = resolveOutputTarget(opts.output, url) catch |err| {
        const message = switch (err) {
            error.InvalidUrl => "invalid upload URL (expected uploads.linear.app)",
            error.MissingFilename => "unable to derive filename from URL",
            error.EmptyOutputPath => "output path cannot be empty",
            else => @errorName(err),
        };
        try stderr.print("download: {s}\n", .{message});
        return 1;
    };

    var status_code: u16 = 0;

    switch (output_target) {
        .stdout => {
            var stdout_buf: [0]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buf);
            downloadOnce(ctx.allocator, ctx.io, api_key, url, &stdout_writer.interface, ctx.timeout_ms, &status_code) catch |err| {
                try reportDownloadError(stderr, api_key, url, err, status_code, ctx.timeout_ms);
                return 1;
            };
        },
        .path => |path| {
            const file = createOutputFile(ctx.io, path) catch |err| {
                try stderr.print("download: failed to create {s}: {s}\n", .{ path, @errorName(err) });
                return 1;
            };
            defer file.close(ctx.io);

            var file_buf: [0]u8 = undefined;
            var file_writer = file.writer(ctx.io, &file_buf);
            downloadOnce(ctx.allocator, ctx.io, api_key, url, &file_writer.interface, ctx.timeout_ms, &status_code) catch |err| {
                try reportDownloadError(stderr, api_key, url, err, status_code, ctx.timeout_ms);
                return 1;
            };

            var stdout_buf: [0]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buf);
            try stdout_writer.interface.writeAll(path);
            try stdout_writer.interface.writeByte('\n');
        },
    }

    return 0;
}

/// Creates the download target owner-only so the attachment is never readable
/// by other local users, not even between creation and the first write.
pub fn createOutputFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, .{
        .truncate = true,
        .permissions = .fromMode(download_file_mode),
    });
}

pub fn isUploadUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, upload_prefix);
}

pub fn extractFilename(url: []const u8) DownloadError![]const u8 {
    const trimmed = trimUrl(url);
    if (!isUploadUrl(trimmed)) return error.InvalidUrl;
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.MissingFilename;
    if (last_slash + 1 >= trimmed.len) return error.MissingFilename;
    return trimmed[last_slash + 1 ..];
}

const max_redirects: u8 = 5;

pub fn downloadWithClient(
    allocator: Allocator,
    client: *std.http.Client,
    api_key: []const u8,
    url: []const u8,
    writer: *std.Io.Writer,
    timeout_ms: u32,
    status_out: *u16,
) DownloadError!void {
    if (!isUploadUrl(url)) return error.InvalidUrl;

    const start_ms: i64 = std.Io.Clock.real.now(client.io).toMilliseconds();
    const deadline_ms = start_ms + @as(i64, @intCast(timeout_ms));

    // First request to Linear with auth - may redirect to CDN
    var current_uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var redirect_count: u8 = 0;
    var include_auth = true;

    while (true) {
        if (std.Io.Clock.real.now(client.io).toMilliseconds() >= deadline_ms) return error.RequestTimedOut;

        var req = try client.request(.GET, current_uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = if (include_auth) .{ .override = api_key } else .omit,
            },
        });
        defer req.deinit();

        try req.sendBodiless();
        if (std.Io.Clock.real.now(client.io).toMilliseconds() >= deadline_ms) return error.RequestTimedOut;

        var response = try req.receiveHead(&.{});
        status_out.* = @intFromEnum(response.head.status);

        if (std.Io.Clock.real.now(client.io).toMilliseconds() >= deadline_ms) return error.RequestTimedOut;

        // Handle redirects (301, 302, 303, 307, 308)
        if (response.head.status.class() == .redirect) {
            redirect_count += 1;
            if (redirect_count > max_redirects) return error.TooManyRedirects;

            const location = response.head.location orelse return error.RedirectMissingLocation;
            current_uri = std.Uri.parse(location) catch return error.InvalidUrl;
            // Don't send auth to redirect target (likely CDN)
            include_auth = false;
            continue;
        }

        if (status_out.* < 200 or status_out.* >= 300) return error.HttpStatus;

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer switch (response.head.content_encoding) {
            .identity => {},
            else => allocator.free(decompress_buffer),
        };

        var transfer_buffer: [transfer_buffer_len]u8 = undefined;
        var output_buffer: [transfer_buffer_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        while (true) {
            if (std.Io.Clock.real.now(client.io).toMilliseconds() >= deadline_ms) return error.RequestTimedOut;
            const amount = reader.readSliceShort(&output_buffer) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr() orelse error.ResponseReadFailed,
            };
            if (amount == 0) break;
            try writer.writeAll(output_buffer[0..amount]);
        }
        break;
    }
}

fn downloadOnce(
    allocator: Allocator,
    io: std.Io,
    api_key: []const u8,
    url: []const u8,
    writer: *std.Io.Writer,
    timeout_ms: u32,
    status_out: *u16,
) DownloadError!void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    try downloadWithClient(allocator, &client, api_key, url, writer, timeout_ms, status_out);
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
        if (std.mem.eql(u8, arg, "--output")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.output = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) {
            opts.output = arg["--output=".len..];
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (opts.url == null) {
            opts.url = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

fn resolveOutputTarget(output: ?[]const u8, url: []const u8) DownloadError!OutputTarget {
    if (output) |value| {
        if (value.len == 0) return error.EmptyOutputPath;
        if (std.mem.eql(u8, value, stdout_marker)) return .stdout;
        return .{ .path = value };
    }

    const filename = try extractFilename(url);
    return .{ .path = filename };
}

fn trimUrl(url: []const u8) []const u8 {
    var end = url.len;
    if (std.mem.indexOfScalar(u8, url, '?')) |idx| {
        if (idx < end) end = idx;
    }
    if (std.mem.indexOfScalar(u8, url, '#')) |idx| {
        if (idx < end) end = idx;
    }
    return url[0..end];
}

fn reportDownloadError(
    stderr: *std.Io.Writer,
    api_key: []const u8,
    url: []const u8,
    err: DownloadError,
    status_code: u16,
    timeout_ms: u32,
) !void {
    switch (err) {
        error.InvalidUrl => try stderr.print("download: invalid upload URL: {s}\n", .{url}),
        error.MissingFilename => try stderr.print("download: URL missing filename: {s}\n", .{url}),
        error.EmptyOutputPath => try stderr.print("download: output path cannot be empty\n", .{}),
        error.RequestTimedOut => try stderr.print("download: request timed out after {d}ms\n", .{timeout_ms}),
        error.RedirectMissingLocation => try stderr.print("download: redirect response missing Location header\n", .{}),
        error.TooManyRedirects => try stderr.print("download: too many redirects (max {d})\n", .{max_redirects}),
        error.HttpStatus => {
            try stderr.print("download: HTTP status {d}\n", .{status_code});
            if (status_code == 401) {
                var buf: [64]u8 = undefined;
                const redacted = common.redactKey(api_key, &buf);
                try stderr.print("download: unauthorized (key {s}); verify LINEAR_API_KEY or run 'linear auth set'\n", .{redacted});
            }
        },
        else => try stderr.print("download: {s}\n", .{@errorName(err)}),
    }
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear download <URL> [--output FILE] [--help]
        \\Flags:
        \\  --output FILE  Write to FILE (use "-" for stdout; default: filename from URL)
        \\  --help         Show this help message
        \\Examples:
        \\  linear download "https://uploads.linear.app/..." --output screenshot.png
        \\  linear download "https://uploads.linear.app/..." --output -
        \\  linear download "https://uploads.linear.app/..."
        \\
    , .{});
}
