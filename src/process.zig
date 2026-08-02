//! Child process execution.
//!
//! This is the only place in the CLI that starts a child process, and every
//! caller reaches it through `Runner`. Two rules hold for everything built on
//! top of it:
//!
//!   1. Every invocation is described by an explicit argv array. No shell is
//!      ever spawned, no command string is ever assembled, and nothing is
//!      interpolated into one. Issue titles, branch names, and credential
//!      helper commands are all attacker- or operator-influenceable, so they
//!      may only reach a child process as discrete argv elements.
//!   2. The spawn itself is behind two function pointers, so argv construction
//!      and output parsing can be exercised without starting a process.
//!
//! Callers that hold a `?Runner` treat `null` as "process execution is not
//! available", which is what keeps the command layer inert in tests: nothing
//! spawns unless a runner was deliberately installed.
//!
//! `git.zig` re-exports this module's types so the git/gh call sites keep
//! reading as `git.Runner`; `credentials.zig` uses it directly. There is
//! deliberately no second spawning path.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The binary is not installed, or not on PATH.
    BinaryNotFound,
    /// The process could not be started or could not be reaped.
    SpawnFailed,
    /// The process outlived `CaptureOptions.timeout` and was killed.
    TimedOut,
    /// The process wrote past `CaptureOptions.stdout_limit`/`stderr_limit`.
    OutputTooLarge,
    /// `CaptureOptions.stdin` was longer than `max_stdin_bytes`.
    InputTooLarge,
    OutOfMemory,
};

/// Reason text for a `<prefix>: <binary> <text>` diagnostic.
pub fn errorText(err: Error) []const u8 {
    return switch (err) {
        Error.BinaryNotFound => "was not found on PATH",
        Error.SpawnFailed => "could not be started",
        Error.TimedOut => "did not finish in time",
        Error.OutputTooLarge => "produced too much output",
        Error.InputTooLarge => "was given too much input",
        Error.OutOfMemory => "could not be started: out of memory",
    };
}

/// How a child process finished. `abnormal` covers signals, stops, and any
/// other termination that is not a plain exit status.
pub const Exit = union(enum) {
    exited: u8,
    abnormal,

    pub fn ok(self: Exit) bool {
        return switch (self) {
            .exited => |status| status == 0,
            .abnormal => false,
        };
    }

    /// Exit status to propagate onward; abnormal terminations become 1 so a
    /// signal can never be reported to the shell as success.
    pub fn code(self: Exit) u8 {
        return switch (self) {
            .exited => |status| status,
            .abnormal => 1,
        };
    }
};

pub const Captured = struct {
    exit: Exit,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Captured, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn ok(self: Captured) bool {
        return self.exit.ok();
    }

    pub fn trimmedStdout(self: Captured) []const u8 {
        return std.mem.trim(u8, self.stdout, " \t\r\n");
    }

    pub fn trimmedStderr(self: Captured) []const u8 {
        return std.mem.trim(u8, self.stderr, " \t\r\n");
    }
};

/// Ceiling on `CaptureOptions.stdin`.
///
/// The whole payload is handed to the child before either output stream is
/// drained, so it has to fit in one pipe buffer (64 KiB on every platform this
/// targets) or the two processes would deadlock waiting on each other. The
/// only caller feeds a single short command line, so this bound is generous.
pub const max_stdin_bytes: usize = 4096;

pub const CaptureOptions = struct {
    /// Bytes written to the child's stdin, which is then closed so the child
    /// observes EOF. `null` gives the child no stdin at all.
    ///
    /// This exists so a secret can be handed to a child process without ever
    /// appearing in its argv, where any other process on the machine could
    /// read it out of the process table.
    stdin: ?[]const u8 = null,
    stdout_limit: std.Io.Limit = .unlimited,
    stderr_limit: std.Io.Limit = .unlimited,
    /// A child that never exits must not wedge the CLI forever; on expiry the
    /// child is killed and `Error.TimedOut` is returned.
    timeout: std.Io.Timeout = .none,
};

pub const CaptureFn = *const fn (
    context: ?*anyopaque,
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: CaptureOptions,
) Error!Captured;

pub const InheritFn = *const fn (
    context: ?*anyopaque,
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
) Error!Exit;

/// Indirection over process execution so commands can be driven by a fake.
/// `capture` pipes stdout/stderr back to the caller; `inherit` hands the
/// terminal to the child, which is what `gh` needs for its interactive flow.
pub const Runner = struct {
    context: ?*anyopaque = null,
    captureFn: CaptureFn,
    inheritFn: InheritFn,

    pub fn capture(
        self: Runner,
        allocator: Allocator,
        io: std.Io,
        argv: []const []const u8,
    ) Error!Captured {
        return self.captureFn(self.context, allocator, io, argv, .{});
    }

    pub fn captureWith(
        self: Runner,
        allocator: Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: CaptureOptions,
    ) Error!Captured {
        return self.captureFn(self.context, allocator, io, argv, options);
    }

    pub fn inherit(
        self: Runner,
        allocator: Allocator,
        io: std.Io,
        argv: []const []const u8,
    ) Error!Exit {
        return self.inheritFn(self.context, allocator, io, argv);
    }
};

/// Builds a `std.Io.Timeout` from a millisecond budget; `0` means no bound.
pub fn timeoutMs(ms: i64) std.Io.Timeout {
    if (ms <= 0) return .none;
    return .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(ms) } };
}

/// The runner that actually spawns processes. Installed by `main.zig`; tests
/// supply their own so no test ever shells out.
pub const system_runner: Runner = .{
    .captureFn = systemCapture,
    .inheritFn = systemInherit,
};

fn systemCapture(
    context: ?*anyopaque,
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: CaptureOptions,
) Error!Captured {
    _ = context;
    if (options.stdin) |input| return captureFeeding(allocator, io, argv, input, options);

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
        .timeout = options.timeout,
    }) catch |err| return mapRunError(err);
    return .{
        .exit = exitFromTerm(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// `std.process.run` with the child's stdin wired to a pipe this process
/// writes and closes. `std.process.run` itself always passes `.ignore`, so the
/// collection loop is mirrored here rather than reimplemented differently.
fn captureFeeding(
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    input: []const u8,
    options: CaptureOptions,
) Error!Captured {
    if (input.len > max_stdin_bytes) return Error.InputTooLarge;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return mapSpawnError(err);
    defer child.kill(io);

    const stdin_file = child.stdin.?;
    stdin_file.writeStreamingAll(io, input) catch {
        return Error.SpawnFailed;
    };
    // Closing is what makes the child see EOF and get on with exiting.
    stdin_file.close(io);
    child.stdin = null;

    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(allocator, io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);

    while (multi.fill(64, options.timeout)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) return Error.OutputTooLarge;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) return Error.OutputTooLarge;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return Error.TimedOut,
        else => return Error.SpawnFailed,
    }

    multi.checkAnyError() catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.SpawnFailed,
    };

    const term = child.wait(io) catch return Error.SpawnFailed;

    const out = multi.toOwnedSlice(0) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    const err_out = multi.toOwnedSlice(1) catch return Error.OutOfMemory;

    return .{ .exit = exitFromTerm(term), .stdout = out, .stderr = err_out };
}

fn systemInherit(
    context: ?*anyopaque,
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
) Error!Exit {
    _ = context;
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| return mapSpawnError(err);
    defer child.kill(io);
    const term = child.wait(io) catch return Error.SpawnFailed;
    return exitFromTerm(term);
}

fn exitFromTerm(term: std.process.Child.Term) Exit {
    return switch (term) {
        .exited => |status| .{ .exited = status },
        .signal, .stopped, .unknown => .abnormal,
    };
}

fn mapRunError(err: std.process.RunError) Error {
    return switch (err) {
        error.FileNotFound => Error.BinaryNotFound,
        error.OutOfMemory => Error.OutOfMemory,
        error.StreamTooLong => Error.OutputTooLarge,
        error.Timeout => Error.TimedOut,
        else => Error.SpawnFailed,
    };
}

fn mapSpawnError(err: std.process.SpawnError) Error {
    return switch (err) {
        error.FileNotFound => Error.BinaryNotFound,
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.SpawnFailed,
    };
}
