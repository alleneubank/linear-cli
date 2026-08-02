//! Git and GitHub CLI integration.
//!
//! Process execution itself lives in `process.zig`; this file only builds argv
//! arrays and interprets the results. The two rules that govern every spawn
//! still hold here:
//!
//!   1. Every invocation is described by an explicit argv array. No shell is
//!      ever spawned, no command string is ever assembled, and nothing is
//!      interpolated into one. Issue titles and branch names come from Linear
//!      and are therefore attacker-influenceable, so they may only reach a
//!      child process as a single discrete argv element.
//!   2. The subprocess itself is reached through `Runner`, so the parsing and
//!      argv-construction logic can be exercised without spawning anything.
//!
//! Callers that hold a `?Runner` treat `null` as "process execution is not
//! available", which is what keeps the command layer inert in tests: nothing
//! spawns unless a runner was deliberately installed.
//!
//! The `Runner`/`Captured`/`Exit`/`Error` names are re-exported from
//! `process.zig` so existing call sites keep reading as `git.Runner`. There is
//! exactly one spawning path in this codebase; do not add another.

const std = @import("std");
const process = @import("process");
const Allocator = std.mem.Allocator;

pub const git_binary = "git";
pub const gh_binary = "gh";

pub const Error = process.Error;
pub const errorText = process.errorText;
pub const Exit = process.Exit;
pub const Captured = process.Captured;
pub const CaptureOptions = process.CaptureOptions;
pub const CaptureFn = process.CaptureFn;
pub const InheritFn = process.InheritFn;
pub const Runner = process.Runner;
pub const system_runner = process.system_runner;

// ---------------------------------------------------------------------------
// argv construction (pure)
// ---------------------------------------------------------------------------

pub const current_branch_argv = [_][]const u8{ git_binary, "symbolic-ref", "--short", "HEAD" };

/// Probe used only to tell "detached HEAD" apart from "not a git repository";
/// `git symbolic-ref` fails identically for both.
pub const inside_work_tree_argv = [_][]const u8{ git_binary, "rev-parse", "--is-inside-work-tree" };

pub fn verifyRefArgv(ref: []const u8) [4][]const u8 {
    return .{ git_binary, "rev-parse", "--verify", ref };
}

pub fn checkoutArgv(branch: []const u8) [3][]const u8 {
    return .{ git_binary, "checkout", branch };
}

/// Fills `buffer` with `git checkout -b <branch> [<from_ref>]` and returns the
/// populated prefix. A buffer keeps the variable-length argv allocation-free.
pub fn checkoutNewArgv(buffer: *[5][]const u8, branch: []const u8, from_ref: ?[]const u8) []const []const u8 {
    buffer[0] = git_binary;
    buffer[1] = "checkout";
    buffer[2] = "-b";
    buffer[3] = branch;
    if (from_ref) |ref| {
        buffer[4] = ref;
        return buffer[0..5];
    }
    return buffer[0..4];
}

pub const PullRequestOptions = struct {
    title: []const u8,
    body: []const u8,
    base: ?[]const u8 = null,
    head: ?[]const u8 = null,
    draft: bool = false,
    web: bool = false,
};

/// Builds `gh pr create ...`. The title carries the issue title verbatim and
/// the body carries the Linear issue URL (that URL is what Linear's GitHub
/// integration keys off to link the PR back to the issue). Both are single
/// argv elements, so their contents are never parsed by anything but `gh`.
///
/// Caller owns the returned slice; the elements are borrowed from `opts`.
pub fn pullRequestArgv(allocator: Allocator, opts: PullRequestOptions) Allocator.Error![][]const u8 {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    errdefer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        gh_binary,
        "pr",
        "create",
        "--title",
        opts.title,
        "--body",
        opts.body,
    });
    if (opts.base) |value| try argv.appendSlice(allocator, &.{ "--base", value });
    if (opts.head) |value| try argv.appendSlice(allocator, &.{ "--head", value });
    if (opts.draft) try argv.append(allocator, "--draft");
    if (opts.web) try argv.append(allocator, "--web");

    return argv.toOwnedSlice(allocator);
}

pub const RefError = error{ EmptyRef, LeadingDash, IllegalCharacter };

/// Rejects ref arguments that git would read as an option or could not accept.
///
/// Branch names reach git as positional arguments and originate either from
/// `Issue.branchName` (server-controlled) or from `--branch`/`--from-ref`
/// (user-controlled), so a leading `-` must be refused before the spawn rather
/// than silently turning into a git flag.
pub fn validateRefArg(value: []const u8) RefError!void {
    if (value.len == 0) return RefError.EmptyRef;
    if (value[0] == '-') return RefError.LeadingDash;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return RefError.IllegalCharacter;
    }
}

pub fn refErrorText(err: RefError) []const u8 {
    return switch (err) {
        RefError.EmptyRef => "must not be empty",
        RefError.LeadingDash => "must not start with '-'",
        RefError.IllegalCharacter => "must not contain whitespace or control characters",
    };
}

// ---------------------------------------------------------------------------
// branch -> issue identifier (pure)
// ---------------------------------------------------------------------------

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Leftmost match of `\b([A-Za-z0-9]+)-([1-9][0-9]*)\b`, borrowed from `branch`.
///
/// This is the naming convention Linear itself emits in `Issue.branchName`, so
/// a branch created from Linear's "copy git branch name" button maps back to
/// its issue. Two consequences of `\b` are deliberate and match the reference
/// implementation: `_` counts as a word character (`feat_eng-123` does not
/// match), and a leading zero is not a valid issue number (`eng-0123` does not
/// match).
pub fn matchIdentifier(branch: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < branch.len) : (start += 1) {
        if (!std.ascii.isAlphanumeric(branch[start])) continue;
        // Start-of-match word boundary.
        if (start > 0 and isWordByte(branch[start - 1])) continue;

        var key_end = start;
        while (key_end < branch.len and std.ascii.isAlphanumeric(branch[key_end])) key_end += 1;
        if (key_end >= branch.len or branch[key_end] != '-') continue;

        const number_start = key_end + 1;
        if (number_start >= branch.len) continue;
        if (branch[number_start] < '1' or branch[number_start] > '9') continue;

        var number_end = number_start + 1;
        while (number_end < branch.len and std.ascii.isDigit(branch[number_end])) number_end += 1;
        // End-of-match word boundary. Backtracking the digit run cannot help:
        // a shorter run is followed by a digit, which is also a word byte.
        if (number_end < branch.len and isWordByte(branch[number_end])) continue;

        return branch[start..number_end];
    }
    return null;
}

/// `matchIdentifier` with the team key uppercased, because Linear identifiers
/// are canonically uppercase while branch names usually are not. Caller owns
/// the result.
pub fn extractIdentifier(allocator: Allocator, branch: []const u8) Allocator.Error!?[]u8 {
    const matched = matchIdentifier(branch) orelse return null;
    const owned = try allocator.dupe(u8, matched);
    _ = std.ascii.upperString(owned, owned);
    return owned;
}

// ---------------------------------------------------------------------------
// branch inference (spawns)
// ---------------------------------------------------------------------------

pub const BranchStatus = union(enum) {
    /// Caller owns the name.
    branch: []u8,
    detached,
    not_a_repository,

    pub fn deinit(self: BranchStatus, allocator: Allocator) void {
        switch (self) {
            .branch => |name| allocator.free(name),
            .detached, .not_a_repository => {},
        }
    }
};

/// Name of the branch HEAD points at.
///
/// A detached HEAD is not an error: it simply has no branch, so there is
/// nothing to infer from. Being outside a repository is reported separately
/// because it deserves a different diagnostic.
pub fn currentBranch(runner: Runner, allocator: Allocator, io: std.Io) Error!BranchStatus {
    var result = try runner.capture(allocator, io, &current_branch_argv);
    defer result.deinit(allocator);

    if (result.ok()) {
        const trimmed = result.trimmedStdout();
        if (trimmed.len > 0) {
            return .{ .branch = try allocator.dupe(u8, trimmed) };
        }
    }

    var probe = try runner.capture(allocator, io, &inside_work_tree_argv);
    defer probe.deinit(allocator);
    if (!probe.ok()) return .not_a_repository;
    return .detached;
}

pub const Inference = union(enum) {
    /// Caller owns the identifier.
    identifier: []u8,
    /// Caller owns the branch name; kept for the diagnostic.
    no_match: []u8,
    detached,
    not_a_repository,

    pub fn deinit(self: Inference, allocator: Allocator) void {
        switch (self) {
            .identifier => |value| allocator.free(value),
            .no_match => |value| allocator.free(value),
            .detached, .not_a_repository => {},
        }
    }
};

pub fn inferIdentifier(runner: Runner, allocator: Allocator, io: std.Io) Error!Inference {
    const status = try currentBranch(runner, allocator, io);
    switch (status) {
        .detached => return .detached,
        .not_a_repository => return .not_a_repository,
        .branch => |name| {
            errdefer allocator.free(name);
            if (try extractIdentifier(allocator, name)) |identifier| {
                allocator.free(name);
                return .{ .identifier = identifier };
            }
            return .{ .no_match = name };
        },
    }
}

pub const InferenceError = error{IdentifierUnavailable};

/// Resolves the issue identifier implied by the current branch, or prints a
/// `<prefix>: <message>` diagnostic and fails. Caller owns the result.
///
/// Every failure mode — no runner, missing binary, no repository, detached
/// HEAD, unrecognisable branch — produces one line on stderr and a single
/// error, so callers only ever have to `catch { return 1; }`.
pub fn requireInferredIdentifier(
    runner: ?Runner,
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    prefix: []const u8,
) ![]u8 {
    const active = runner orelse {
        try stderr.print("{s}: no issue identifier given and branch inference is unavailable\n", .{prefix});
        return InferenceError.IdentifierUnavailable;
    };

    const inference = inferIdentifier(active, allocator, io) catch |err| {
        try stderr.print(
            "{s}: {s} {s}; pass an issue identifier explicitly\n",
            .{ prefix, git_binary, errorText(err) },
        );
        return InferenceError.IdentifierUnavailable;
    };
    errdefer inference.deinit(allocator);

    switch (inference) {
        .identifier => |value| return value,
        .no_match => |branch| {
            try stderr.print(
                "{s}: branch '{s}' has no issue identifier; pass one explicitly\n",
                .{ prefix, branch },
            );
            return InferenceError.IdentifierUnavailable;
        },
        .detached => {
            try stderr.print("{s}: HEAD is detached; pass an issue identifier explicitly\n", .{prefix});
            return InferenceError.IdentifierUnavailable;
        },
        .not_a_repository => {
            try stderr.print("{s}: not a git repository; pass an issue identifier explicitly\n", .{prefix});
            return InferenceError.IdentifierUnavailable;
        },
    }
}
