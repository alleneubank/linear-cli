//! Shared `--bulk` input collection and the batched executor behind it.
//!
//! Lives in its own module rather than in `common.zig` because it is a distinct
//! concern: `common.zig` holds the GraphQL request/response helpers every
//! command reaches for, while this file owns argument collection, dedupe, and
//! per-item result accounting for the destructive commands only.
//!
//! Execution is deliberately **serial**. Every caller is a delete mutation, this
//! codebase has no concurrency primitives anywhere else, and a predictable,
//! interleaving-free order of destructive requests is worth more than the
//! wall-clock win a concurrent batcher would buy.
const std = @import("std");
const common = @import("common");

const Allocator = std.mem.Allocator;

/// Upper bound on one bulk run. A `--bulk-file` pointed at the wrong file
/// should fail with a diagnostic instead of firing thousands of deletes.
pub const max_targets: usize = 500;

pub const Options = struct {
    /// `--bulk ID,ID,...`
    ids: ?[]const u8 = null,
    /// `--bulk-file PATH` (`-` reads stdin, like every other `--*-file` flag).
    file: ?[]const u8 = null,
    /// `--bulk-stdin`
    stdin: bool = false,

    pub fn requested(self: Options) bool {
        return self.ids != null or self.file != null or self.stdin;
    }
};

/// Consumes a leading bulk flag from `args`, returning how many argv entries it
/// used, or 0 when `args[0]` is not a bulk flag. Commands call this at the top
/// of their own option loop and fall through to their other flags on 0.
pub fn parseFlag(opts: *Options, args: []const []const u8) !usize {
    if (args.len == 0) return 0;
    const arg = args[0];

    if (std.mem.eql(u8, arg, "--bulk")) {
        if (args.len < 2) return error.MissingValue;
        opts.ids = args[1];
        return 2;
    }
    if (std.mem.startsWith(u8, arg, "--bulk=")) {
        opts.ids = arg["--bulk=".len..];
        return 1;
    }
    if (std.mem.eql(u8, arg, "--bulk-file")) {
        if (args.len < 2) return error.MissingValue;
        opts.file = args[1];
        return 2;
    }
    if (std.mem.startsWith(u8, arg, "--bulk-file=")) {
        opts.file = arg["--bulk-file=".len..];
        return 1;
    }
    if (std.mem.eql(u8, arg, "--bulk-stdin")) {
        opts.stdin = true;
        return 1;
    }
    return 0;
}

/// Deduplicated bulk targets. `items` borrows from either argv or `storage`, so
/// the struct has to outlive the run that uses it.
pub const Targets = struct {
    allocator: Allocator,
    items: [][]const u8,
    storage: ?[]u8 = null,

    pub fn deinit(self: *Targets) void {
        self.allocator.free(self.items);
        if (self.storage) |buf| self.allocator.free(buf);
        self.items = &.{};
        self.storage = null;
    }
};

/// Collects bulk targets from whichever source was requested.
///
/// Returns `null` when no bulk flag was passed, which is how callers tell a
/// single-target run from a batch. Input is split on commas and ASCII
/// whitespace so `--bulk a,b` and a newline-delimited file both work, and
/// duplicates are dropped keeping first-seen order — a destructive mutation
/// must never be sent twice for the same id.
pub fn collect(
    allocator: Allocator,
    io: std.Io,
    opts: Options,
    stderr: anytype,
    prefix: []const u8,
) !?Targets {
    var sources: usize = 0;
    if (opts.ids != null) sources += 1;
    if (opts.file != null) sources += 1;
    if (opts.stdin) sources += 1;

    if (sources == 0) return null;
    if (sources > 1) {
        try stderr.print("{s}: use only one of --bulk, --bulk-file, or --bulk-stdin\n", .{prefix});
        return common.CommandError.CommandFailed;
    }

    var storage: ?[]u8 = null;
    errdefer if (storage) |buf| allocator.free(buf);

    const raw: []const u8 = blk: {
        if (opts.ids) |value| break :blk value;
        const path = if (opts.stdin) common.stdin_marker else opts.file.?;
        const buf = try common.readContentFile(allocator, io, path, stderr, prefix);
        storage = buf;
        break :blk buf;
    };

    var items = std.ArrayListUnmanaged([]const u8).empty;
    errdefer items.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var iter = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
    while (iter.next()) |token| {
        const gop = try seen.getOrPut(token);
        if (gop.found_existing) continue;
        try items.append(allocator, token);
    }

    if (items.items.len == 0) {
        try stderr.print("{s}: bulk input contained no ids\n", .{prefix});
        return common.CommandError.CommandFailed;
    }
    if (items.items.len > max_targets) {
        try stderr.print(
            "{s}: bulk input has {d} ids; the limit is {d}\n",
            .{ prefix, items.items.len, max_targets },
        );
        return common.CommandError.CommandFailed;
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
        .storage = storage,
    };
}

/// Result of a single item. Anything the user needs to see has already been
/// printed by the callback; this only feeds the counters.
pub const Outcome = enum { succeeded, failed };

pub const Summary = struct {
    succeeded: usize = 0,
    failed: usize = 0,

    pub fn total(self: Summary) usize {
        return self.succeeded + self.failed;
    }

    /// Any failed item makes the whole run non-zero, so a script that batches
    /// deletes still notices a partial failure.
    pub fn exitCode(self: Summary) u8 {
        return if (self.failed > 0) 1 else 0;
    }
};

/// Runs `runItem(ctx, index, target)` once per target, in order, on this
/// thread. `runItem` must return `!Outcome`: a `.failed` outcome is counted and
/// the run continues, while a returned error (a writer or allocator failure) is
/// unexpected and aborts the batch.
pub fn execute(
    comptime Ctx: type,
    ctx: Ctx,
    targets: []const []const u8,
    comptime runItem: anytype,
) !Summary {
    var summary = Summary{};
    for (targets, 0..) |target, index| {
        switch (try runItem(ctx, index, target)) {
            .succeeded => summary.succeeded += 1,
            .failed => summary.failed += 1,
        }
    }
    return summary;
}

/// One-line batch report. Callers send this to stderr and skip it under
/// `--json` so machine-readable stdout stays the only thing a consumer parses.
pub fn printSummary(writer: anytype, prefix: []const u8, summary: Summary) !void {
    try writer.print(
        "{s}: bulk complete; {d} succeeded, {d} failed\n",
        .{ prefix, summary.succeeded, summary.failed },
    );
}
