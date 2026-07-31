//! Credential provider chain.
//!
//! Resolution order, highest precedence first:
//!
//!     LINEAR_API_KEY  ->  credential_helper  ->  keychain (macOS)  ->  config file
//!
//! The helper outranks the keychain deliberately: explicit configuration must
//! beat auto-detection. If an auto-detected keychain item could shadow a
//! configured helper, the helper would be silently ignored and the operator
//! would end up with the secret in two places without knowing which one is
//! live.
//!
//! Two rules apply to everything in this file:
//!
//!   * Nothing here ever logs, prints, or embeds a backend's stdout. A failing
//!     helper is reported by exit status and stderr only, because stdout is
//!     where the secret would be.
//!   * Every spawn goes through `process.Runner`, so tests drive the whole
//!     chain with a fake and no test ever runs `op`, `pass`, or `security`.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const process = @import("process");

const Allocator = std.mem.Allocator;

/// Absolute path, not `security`: this reads a secret, so it must not be
/// resolvable through a caller-controlled PATH.
pub const keychain_binary = "/usr/bin/security";
pub const keychain_service = "linear-cli";
pub const keychain_account = "api-key";

/// macOS is the only platform where a first-party secret store is reachable
/// with no extra dependency. Everywhere else this backend does not exist at
/// all — there is no silent downgrade to some weaker local store.
pub const keychain_supported = builtin.os.tag == .macos;

/// A helper may legitimately block on a biometric or 2FA prompt (`op read`
/// does), and a human fumbling with Touch ID can easily take half a minute, so
/// the budget is generous. It exists to stop a wedged helper from hanging the
/// CLI forever, not to enforce latency.
pub const helper_timeout_ms: i64 = 60_000;
/// `security` either answers immediately or is waiting on an unlock prompt.
pub const keychain_timeout_ms: i64 = 20_000;

/// Cap on what a backend may write. A key is at most `max_api_key_len` bytes;
/// this leaves room for a stray banner while still bounding the read.
pub const max_output_bytes: usize = 4096;
/// A failing backend's stderr is quoted into the diagnostic, so it is capped
/// too, and only the first line is used.
pub const max_detail_bytes: usize = 200;

pub const FailureKind = enum {
    /// The binary could not be started (missing, not executable, timed out).
    spawn,
    /// The binary ran and exited non-zero.
    exit,
    /// The binary exited 0 and produced nothing.
    empty,
    /// The binary produced more than `max_output_bytes`.
    oversized,
    /// The binary produced something that is not a usable API key.
    invalid,
};

pub const Failure = struct {
    kind: FailureKind,
    /// Only meaningful for `.spawn`.
    spawn_error: process.Error = process.Error.SpawnFailed,
    /// Only meaningful for `.exit`.
    exit_code: u8 = 0,
    /// First line of the backend's stderr, owned. Never its stdout.
    detail: []u8 = &.{},

    pub fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.detail);
    }
};

/// What a backend produced. `absent` means the backend ran fine and simply
/// holds nothing, which is a normal outcome for the keychain probe.
pub const Outcome = union(enum) {
    /// Owned by the caller.
    key: []u8,
    absent,
    failure: Failure,

    pub fn deinit(self: Outcome, allocator: Allocator) void {
        switch (self) {
            .key => |value| allocator.free(value),
            .absent => {},
            .failure => |failure| failure.deinit(allocator),
        }
    }
};

// ---------------------------------------------------------------------------
// argv construction (pure)
// ---------------------------------------------------------------------------

/// `security find-generic-password -w -s <service> -a <account>`.
///
/// The read is on the hot path — every command that needs a key runs it — and
/// nothing sensitive appears in argv: the secret comes back on stdout.
pub fn keychainReadArgv() [7][]const u8 {
    return .{
        keychain_binary,
        "find-generic-password",
        "-w",
        "-s",
        keychain_service,
        "-a",
        keychain_account,
    };
}

/// `security -i`.
///
/// The write is driven through `security`'s own interactive mode, with the
/// `add-generic-password` line delivered on stdin by `keychainWriteInput`.
/// `security add-generic-password -w <secret>` would put the key in argv,
/// where every process on the machine can read it out of the process table —
/// which is the exact hazard `--api-key` was removed for. There is no argv
/// fallback: if this path cannot be used the write is refused.
pub fn keychainWriteArgv() [2][]const u8 {
    return .{ keychain_binary, "-i" };
}

pub const KeychainWriteError = error{
    /// The key would be read as an option by `security`'s tokenizer.
    LeadingDash,
    OutOfMemory,
};

/// Builds the line fed to `security -i`. Caller owns the result.
///
/// `security`'s interactive tokenizer splits on whitespace and has no quoting
/// rules worth relying on, so this is only sound because `isValidApiKey` has
/// already constrained the key to `[A-Za-z0-9_-]`: no spaces, no newlines, no
/// metacharacters. The one residual hazard is a leading `-`, which would be
/// taken for a flag, and that is refused rather than worked around.
pub fn keychainWriteInput(allocator: Allocator, key: []const u8) KeychainWriteError![]u8 {
    std.debug.assert(config.isValidApiKey(key));
    // The assert states the precondition; the length guard keeps the index
    // below defined even in a build that strips asserts.
    if (key.len == 0 or key[0] == '-') return KeychainWriteError.LeadingDash;

    return std.fmt.allocPrint(
        allocator,
        "add-generic-password -a {s} -s {s} -U -w {s}\n",
        .{ keychain_account, keychain_service, key },
    );
}

// ---------------------------------------------------------------------------
// backends (spawn)
// ---------------------------------------------------------------------------

/// Runs `argv` and interprets its stdout as an API key.
///
/// Trailing whitespace is trimmed because every secret manager worth using
/// terminates its output with a newline, and the result is validated before it
/// can reach an `Authorization` header.
pub fn runHelper(
    runner: process.Runner,
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
) Allocator.Error!Outcome {
    return runBackend(runner, allocator, io, argv, .{
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .timeout = process.timeoutMs(helper_timeout_ms),
    }, false);
}

/// Reads the keychain item. A non-zero exit means "no such item", which is an
/// ordinary outcome: the chain simply moves on to the config file.
pub fn readKeychain(
    runner: process.Runner,
    allocator: Allocator,
    io: std.Io,
) Allocator.Error!Outcome {
    const argv = keychainReadArgv();
    return runBackend(runner, allocator, io, &argv, .{
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .timeout = process.timeoutMs(keychain_timeout_ms),
    }, true);
}

/// Stores `key` in the keychain without it ever appearing in an argv.
pub fn writeKeychain(
    runner: process.Runner,
    allocator: Allocator,
    io: std.Io,
    key: []const u8,
) (Allocator.Error || KeychainWriteError)!Outcome {
    const input = try keychainWriteInput(allocator, key);
    // The secret lives in this buffer only as long as the spawn takes.
    defer {
        @memset(input, 0);
        allocator.free(input);
    }

    const argv = keychainWriteArgv();
    var result = runner.captureWith(allocator, io, &argv, .{
        .stdin = input,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .timeout = process.timeoutMs(keychain_timeout_ms),
    }) catch |err| return .{ .failure = .{ .kind = .spawn, .spawn_error = err } };
    defer result.deinit(allocator);

    if (!result.ok()) {
        return .{ .failure = .{
            .kind = .exit,
            .exit_code = result.exit.code(),
            .detail = try detailFrom(allocator, result.trimmedStderr()),
        } };
    }
    return .absent;
}

fn runBackend(
    runner: process.Runner,
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: process.CaptureOptions,
    missing_on_exit: bool,
) Allocator.Error!Outcome {
    var result = runner.captureWith(allocator, io, argv, options) catch |err| switch (err) {
        process.Error.OutOfMemory => return Allocator.Error.OutOfMemory,
        process.Error.OutputTooLarge => return .{ .failure = .{ .kind = .oversized } },
        else => return .{ .failure = .{ .kind = .spawn, .spawn_error = err } },
    };
    defer result.deinit(allocator);

    if (!result.ok()) {
        if (missing_on_exit) return .absent;
        return .{ .failure = .{
            .kind = .exit,
            .exit_code = result.exit.code(),
            .detail = try detailFrom(allocator, result.trimmedStderr()),
        } };
    }

    const value = result.trimmedStdout();
    if (value.len == 0) return .{ .failure = .{ .kind = .empty } };
    if (value.len > config.max_api_key_len) return .{ .failure = .{ .kind = .oversized } };
    if (!config.isValidApiKey(value)) return .{ .failure = .{ .kind = .invalid } };

    return .{ .key = try allocator.dupe(u8, value) };
}

/// First line of `text`, truncated. Control bytes are dropped so a backend
/// cannot smuggle escape sequences into the terminal through its stderr.
fn detailFrom(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..@min(line_end, max_detail_bytes)];

    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    for (line) |byte| {
        if (byte < 0x20 or byte == 0x7f) continue;
        try buffer.append(allocator, byte);
    }
    return buffer.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// diagnostics
// ---------------------------------------------------------------------------

/// Prints a `<prefix>: <message>` line for a backend failure.
///
/// `name` identifies the backend, never the secret. The backend's stdout is
/// not available here by construction: `Failure` has no field for it.
pub fn printFailure(
    failure: Failure,
    name: []const u8,
    stderr: anytype,
    prefix: []const u8,
) !void {
    switch (failure.kind) {
        .spawn => try stderr.print(
            "{s}: {s} {s}\n",
            .{ prefix, name, process.errorText(failure.spawn_error) },
        ),
        .exit => {
            if (failure.detail.len > 0) {
                try stderr.print(
                    "{s}: {s} exited {d}: {s}\n",
                    .{ prefix, name, failure.exit_code, failure.detail },
                );
            } else {
                try stderr.print(
                    "{s}: {s} exited {d}\n",
                    .{ prefix, name, failure.exit_code },
                );
            }
        },
        .empty => try stderr.print("{s}: {s} produced no output\n", .{ prefix, name }),
        // Both the process-level read cap and the key-length check land here,
        // and the key bound is the smaller of the two, so quoting it is true
        // either way and tells the operator the number that actually matters.
        .oversized => try stderr.print(
            "{s}: {s} produced more than {d} characters, which cannot be an API key\n",
            .{ prefix, name, config.max_api_key_len },
        ),
        .invalid => try stderr.print(
            "{s}: {s} produced something that is not a valid API key; expected {d}-{d} characters from [A-Za-z0-9_-]\n",
            .{ prefix, name, config.min_api_key_len, config.max_api_key_len },
        ),
    }
}

/// Human-readable name of the configured helper, for diagnostics. Caller owns
/// the result. Helper argv is operator-supplied configuration, not a secret.
pub fn helperName(allocator: Allocator, argv: []const []const u8) Allocator.Error![]u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, "credential_helper '");
    for (argv, 0..) |entry, idx| {
        if (idx > 0) try buffer.append(allocator, ' ');
        try buffer.appendSlice(allocator, entry);
    }
    try buffer.append(allocator, '\'');
    return buffer.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// chain
// ---------------------------------------------------------------------------

/// Fills in `cfg.api_key`/`cfg.key_source` from the highest-precedence backend
/// that yields a key, and warns when the deprecated file backend is what ends
/// up supplying it.
///
/// `config.load` has already applied both ends of the chain — the file key and
/// the `LINEAR_API_KEY` override — so only the two middle backends are left,
/// and only when the environment did not already win.
///
/// A `null` runner means process execution is unavailable; the chain then
/// degrades to exactly what `config.load` produced.
pub fn resolve(
    cfg: *config.Config,
    runner: ?process.Runner,
    io: std.Io,
    stderr: anytype,
) !void {
    if (cfg.key_source != .environment) {
        if (runner) |active| try resolveBackends(cfg, active, io, stderr);
    }

    if (cfg.key_source == .file) {
        try stderr.print(
            "warning: API key read from {s}; the config file stores it in plaintext. " ++
                "Move it with 'linear auth migrate --to helper <command>' or " ++
                "'linear auth migrate --to keychain'.\n",
            .{cfg.config_path orelse "the config file"},
        );
    }
}

fn resolveBackends(
    cfg: *config.Config,
    runner: process.Runner,
    io: std.Io,
    stderr: anytype,
) !void {
    if (cfg.credential_helper) |argv| {
        const outcome = try runHelper(runner, cfg.allocator, io, argv);
        defer outcome.deinit(cfg.allocator);

        switch (outcome) {
            .key => |key| try cfg.setApiKeyFromProvider(key, .helper),
            // `runHelper` never reports `absent`: a helper that exits 0 with no
            // output is a failure, not an empty store.
            .absent => unreachable,
            .failure => |failure| {
                // A configured helper that fails must not silently degrade to
                // the plaintext file key it was configured to replace.
                cfg.clearEffectiveApiKey(.helper_failed);
                const name = try helperName(cfg.allocator, argv);
                defer cfg.allocator.free(name);
                try printFailure(failure, name, stderr, "linear");
            },
        }
        return;
    }

    if (!keychain_supported) return;

    const outcome = try readKeychain(runner, cfg.allocator, io);
    defer outcome.deinit(cfg.allocator);

    switch (outcome) {
        .key => |key| try cfg.setApiKeyFromProvider(key, .keychain),
        // Auto-detected, not configured: "no item here" just means the next
        // backend gets its turn, with no diagnostic.
        .absent => {},
        .failure => |failure| {
            // The item exists but is unusable, or `security` itself is broken.
            // Say so, then let the file backend try, because the keychain was
            // never something the operator asked for.
            const name = keychain_binary;
            try printFailure(failure, name, stderr, "linear");
        },
    }
}
