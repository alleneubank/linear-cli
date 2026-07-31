const std = @import("std");

pub const GlobalOptions = struct {
    json: bool = false,
    keep_alive: bool = true,
    retries: u8 = 0,
    timeout_ms: u32 = 10_000,
    config_path: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
};

pub const Parsed = struct {
    opts: GlobalOptions,
    rest: [][]const u8,
};

pub fn parseGlobal(args: [][]const u8) !Parsed {
    var opts = GlobalOptions{};
    if (args.len == 0) return .{ .opts = opts, .rest = args };

    var idx: usize = 1;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-keepalive") or std.mem.eql(u8, arg, "--no-keep-alive")) {
            opts.keep_alive = false;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--retries")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.retries = try std.fmt.parseUnsigned(u8, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--retries=")) {
            opts.retries = try std.fmt.parseUnsigned(u8, arg["--retries=".len..], 10);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.timeout_ms = try std.fmt.parseUnsigned(u32, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--timeout-ms=")) {
            opts.timeout_ms = try std.fmt.parseUnsigned(u32, arg["--timeout-ms=".len..], 10);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--endpoint")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.endpoint = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--endpoint=")) {
            opts.endpoint = arg["--endpoint=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            opts.version = true;
            idx += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            opts.config_path = arg["--config=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.config_path = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            idx += 1;
            break;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        break;
    }

    return .{ .opts = opts, .rest = args[idx..] };
}

pub fn stripTrailingGlobals(allocator: std.mem.Allocator, args: []const []const u8, opts: *GlobalOptions) ![][]const u8 {
    var filtered = std.ArrayListUnmanaged([]const u8).empty;
    errdefer filtered.deinit(allocator);

    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-keepalive") or std.mem.eql(u8, arg, "--no-keep-alive")) {
            opts.keep_alive = false;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--retries")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.retries = try std.fmt.parseUnsigned(u8, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--retries=")) {
            opts.retries = try std.fmt.parseUnsigned(u8, arg["--retries=".len..], 10);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.timeout_ms = try std.fmt.parseUnsigned(u32, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--timeout-ms=")) {
            opts.timeout_ms = try std.fmt.parseUnsigned(u32, arg["--timeout-ms=".len..], 10);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--endpoint")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.endpoint = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--endpoint=")) {
            opts.endpoint = arg["--endpoint=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.config_path = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            opts.config_path = arg["--config=".len..];
            idx += 1;
            continue;
        }

        try filtered.append(allocator, arg);
        idx += 1;
    }

    return filtered.toOwnedSlice(allocator);
}
