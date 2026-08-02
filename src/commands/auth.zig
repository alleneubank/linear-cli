const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");
const credentials = @import("credentials");
const process = @import("process");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("termios.h");
});

const Allocator = std.mem.Allocator;

pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    config: *config.Config,
    args: [][]const u8,
    json_output: bool,
    config_path: ?[]const u8,
    retries: u8,
    timeout_ms: u32,
    endpoint: ?[]const u8 = null,
    /// `null` means process execution is unavailable, which is what keeps
    /// tests hermetic. `main.zig` installs `process.system_runner`.
    credential_runner: ?process.Runner = null,
};

/// Backend `auth set` writes the key to.
///
/// `file` is the historical behaviour and stays the default, so omitting the
/// flag means exactly what it always meant. It is also the deprecated one: the
/// key lands in `config.json` as plaintext and every run that reads it says so.
pub const SetTarget = enum { file, keychain };

const SetOptions = struct {
    target: SetTarget = .file,
    help: bool = false,
};

const TestOptions = struct {
    help: bool = false,
};

const ShowOptions = struct {
    /// Output is redacted unless the operator explicitly opts in, and even then
    /// only when stdout is a terminal.
    reveal: bool = false,
    /// Accepted for backward compatibility; redaction is the default now.
    redacted: bool = false,
    help: bool = false,
};

const StatusOptions = struct {
    help: bool = false,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    if (ctx.args.len == 0) {
        try usage(stderr);
        return 1;
    }

    const sub = ctx.args[0];
    const rest = ctx.args[1..];

    if (std.mem.eql(u8, sub, "set")) {
        return runSet(ctx, rest);
    }
    if (std.mem.eql(u8, sub, "test")) {
        return runTest(ctx, rest);
    }
    if (std.mem.eql(u8, sub, "show")) {
        return runShow(ctx, rest);
    }
    if (std.mem.eql(u8, sub, "status")) {
        return runStatus(ctx, rest);
    }

    try stderr.print("auth: unknown command: {s}\n", .{sub});
    try usage(stderr);
    return 1;
}

fn runSet(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseSetOptions(args) catch |err| {
        try stderr.print("auth set: {s}\n", .{@errorName(err)});
        try setUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try setUsage(&out_writer.interface);
        return 0;
    }

    var stdin_value: ?[]u8 = null;
    var prompt_value: ?[]u8 = null;
    defer {
        if (stdin_value) |buf| ctx.allocator.free(buf);
        if (prompt_value) |buf| ctx.allocator.free(buf);
    }

    var key: ?[]const u8 = null;
    const stdin_file = std.Io.File.stdin();
    if (!try stdin_file.isTty(ctx.io)) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = stdin_file.readerStreaming(ctx.io, &stdin_buf);
        const input = stdin_reader.interface.allocRemaining(ctx.allocator, .limited(64 * 1024)) catch |err| {
            try stderr.print("auth set: failed to read stdin: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (input.len > 0) {
            const trimmed = std.mem.trim(u8, input, " \r\n\t");
            if (trimmed.len > 0) {
                stdin_value = input;
                key = trimmed;
            } else {
                ctx.allocator.free(input);
            }
        } else {
            ctx.allocator.free(input);
        }
    }

    if (key == null) {
        prompt_value = promptForApiKey(ctx.allocator, ctx.io, stderr) catch |err| switch (err) {
            common.CommandError.CommandFailed => return 1,
            else => return err,
        };
        if (prompt_value) |buf| {
            const trimmed = std.mem.trim(u8, buf, " \r\n\t");
            if (trimmed.len > 0) {
                key = trimmed;
            } else {
                ctx.allocator.free(buf);
                prompt_value = null;
            }
        }
    }

    // Never fall back to `ctx.config.api_key`: that value may have come from
    // `LINEAR_API_KEY`, and environment keys are documented as never touching
    // disk.
    if (key == null) {
        try stderr.print(
            "auth set: no API key supplied; pipe one on stdin or run interactively (LINEAR_API_KEY is never written to disk)\n",
            .{},
        );
        return 1;
    }

    return switch (opts.target) {
        .file => setToFile(ctx, key.?, stderr),
        .keychain => setToKeychain(ctx, key.?, stderr),
    };
}

/// The one message for a key that fails `config.isValidApiKey`, shared by both
/// backends so the two cannot drift into describing different rules.
fn printInvalidKey(stderr: anytype) !void {
    try stderr.print(
        "auth set: invalid API key; expected {d}-{d} characters from [A-Za-z0-9_-]\n",
        .{ config.min_api_key_len, config.max_api_key_len },
    );
}

/// Deprecated destination: the key is written to `config.json` in plaintext and
/// every later run that reads it from there warns.
fn setToFile(ctx: Context, key: []const u8, stderr: anytype) !u8 {
    ctx.config.setApiKey(key) catch |err| switch (err) {
        config.ApiKeyError.InvalidApiKey => {
            try printInvalidKey(stderr);
            return 1;
        },
        else => return err,
    };
    try ctx.config.save(ctx.allocator, ctx.config_path);

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try out_writer.interface.print("api key saved\n", .{});
    return 0;
}

/// Stores the key in the login keychain, and never touches the config file.
///
/// The write goes through `credentials.writeKeychain`, which feeds `security
/// -i` on stdin; there is no argv form, because argv is readable from the
/// process table by anything running as this user.
fn setToKeychain(ctx: Context, key: []const u8, stderr: anytype) !u8 {
    // The backend simply does not exist elsewhere, and quietly writing the
    // plaintext file instead would store the key somewhere the operator did
    // not ask for.
    if (!credentials.keychain_supported) {
        try stderr.print(
            "auth set: the keychain backend is only available on macOS; " ++
                "use 'linear config set credential_helper \"<command>\"' instead\n",
            .{},
        );
        return 1;
    }

    // `credentials.keychainWriteInput` asserts this, and its whole safety
    // argument rests on it: the charset is what makes the `security -i` line
    // untokenizable into anything but the intended command.
    if (!config.isValidApiKey(key)) {
        try printInvalidKey(stderr);
        return 1;
    }

    const runner = ctx.credential_runner orelse {
        try stderr.print("auth set: process execution is unavailable\n", .{});
        return 1;
    };

    const write_outcome = credentials.writeKeychain(runner, ctx.allocator, ctx.io, key) catch |err| switch (err) {
        credentials.KeychainWriteError.LeadingDash => {
            try stderr.print(
                "auth set: this API key starts with '-', which {s} would read as an option; " ++
                    "put it in a secret manager and use 'linear config set credential_helper \"<command>\"' instead\n",
                .{credentials.keychain_binary},
            );
            return 1;
        },
        else => return err,
    };
    defer write_outcome.deinit(ctx.allocator);

    switch (write_outcome) {
        .failure => |failure| {
            try credentials.printFailure(failure, credentials.keychain_binary, stderr, "auth set");
            return 1;
        },
        .absent => {},
        .key => unreachable,
    }

    // Read back before claiming success. `security -i` reports on the session
    // rather than on each command it was handed, so a write that quietly did
    // nothing would otherwise look like a stored credential that is not there.
    const read_outcome = try credentials.readKeychain(runner, ctx.allocator, ctx.io);
    defer read_outcome.deinit(ctx.allocator);

    switch (read_outcome) {
        .key => |stored| {
            if (!std.mem.eql(u8, stored, key)) {
                try stderr.print(
                    "auth set: the keychain read back a different key than was written; " ++
                        "the item holds something else\n",
                    .{},
                );
                return 1;
            }
        },
        .absent => {
            try stderr.print(
                "auth set: the keychain item could not be read back after writing it; nothing was stored\n",
                .{},
            );
            return 1;
        },
        .failure => |failure| {
            try credentials.printFailure(failure, credentials.keychain_binary, stderr, "auth set");
            return 1;
        },
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try out_writer.interface.print(
        "api key stored in the keychain (service {s}, account {s})\n",
        .{ credentials.keychain_service, credentials.keychain_account },
    );

    // The keychain outranks the config file, so a plaintext key left behind is
    // no longer the one in use — which is exactly how it gets forgotten.
    if (ctx.config.file_api_key != null) {
        try stderr.print(
            "warning: a plaintext api_key is still in {s}; delete that file to clear it " ++
                "(it also holds default_team_id and team_cache) and rotate the old key in Linear\n",
            .{ctx.config.config_path orelse "the config file"},
        );
    }
    return 0;
}

fn runTest(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseTestOptions(args) catch |err| {
        try stderr.print("auth test: {s}\n", .{@errorName(err)});
        try testUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try testUsage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "auth test") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const query =
        \\query Viewer {
        \\  viewer {
        \\    id
        \\    name
        \\    email
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "auth test", &client, .{
        .query = query,
        .variables = null,
        .operation_name = "Viewer",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "auth test", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("auth test: response missing data\n", .{});
        return 1;
    };

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const viewer = common.getObjectField(data_value, "viewer") orelse {
        try stderr.print("auth test: viewer not found in response\n", .{});
        return 1;
    };

    const id = common.getStringField(viewer, "id") orelse "(unknown)";
    const name = common.getStringField(viewer, "name") orelse "(unknown)";
    const email = common.getStringField(viewer, "email") orelse "(unknown)";

    const row = printer.ViewerRow{
        .id = id,
        .name = name,
        .email = email,
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try printer.printViewerTable(ctx.allocator, &out_writer.interface, &.{row}, .{});
    return 0;
}

fn runShow(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseShowOptions(args) catch |err| {
        try stderr.print("auth show: {s}\n", .{@errorName(err)});
        try showUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try showUsage(&out_writer.interface);
        return 0;
    }

    const key = ctx.config.api_key orelse {
        try stderr.print("auth show: no API key configured\n", .{});
        return 1;
    };

    const stdout_file = std.Io.File.stdout();
    if (opts.reveal and !try stdout_file.isTty(ctx.io)) {
        try stderr.print("auth show: refusing to reveal the API key because stdout is not a terminal\n", .{});
        return 1;
    }

    var redacted_buf: [64]u8 = undefined;
    const display = if (opts.reveal) key else common.redactKey(key, &redacted_buf);

    var out_buf: [0]u8 = undefined;
    var out_writer = stdout_file.writer(ctx.io, &out_buf);
    if (ctx.json_output) {
        var json_buffer = std.Io.Writer.Allocating.init(ctx.allocator);
        defer json_buffer.deinit();
        var jw = std.json.Stringify{ .writer = &json_buffer.writer, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("api_key");
        try jw.write(display);
        try jw.endObject();
        try out_writer.interface.writeAll(json_buffer.writer.buffered());
        try out_writer.interface.writeByte('\n');
        return 0;
    }

    try out_writer.interface.print("api key: {s}\n", .{display});
    return 0;
}

/// Reports which backend supplied the key and whether it is well-formed.
///
/// This is the diagnostic that replaces the urge to run `auth show`: it answers
/// "where is my credential coming from and does it look right" without the key
/// ever reaching stdout, stderr, or a JSON document.
///
/// Deliberately offline: the only check it can make is the charset/length one,
/// so it never claims more than that. A key that Linear has revoked, or a
/// fixture string like `test-key`, is `format-valid` here and still worthless —
/// `auth test` is the only command that round-trips the credential against the
/// API, and every label here points at it rather than implying it already ran.
fn runStatus(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseStatusOptions(args) catch |err| {
        try stderr.print("auth status: {s}\n", .{@errorName(err)});
        try statusUsage(stderr);
        return 1;
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const out = &out_writer.interface;

    if (opts.help) {
        try statusUsage(out);
        return 0;
    }

    const cfg = ctx.config;
    const key_present = cfg.api_key != null;
    // Charset and length only — this says the key *could* be sent, not that it
    // works. A key that reached `Config` has already been validated, so this can
    // only disagree if a future ingestion point forgets to check. Recomputing it
    // here is what makes that a visible `malformed` instead of a 401 later.
    const key_format_valid = if (cfg.api_key) |key| config.isValidApiKey(key) else false;

    var helper_display: ?[]u8 = null;
    defer if (helper_display) |value| ctx.allocator.free(value);
    if (cfg.credential_helper) |argv| {
        helper_display = try joinArgv(ctx.allocator, argv);
    }

    if (ctx.json_output) {
        var json_buffer = std.Io.Writer.Allocating.init(ctx.allocator);
        defer json_buffer.deinit();
        var jw = std.json.Stringify{ .writer = &json_buffer.writer, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("source");
        try jw.write(@tagName(cfg.key_source));
        try jw.objectField("key_present");
        try jw.write(key_present);
        // `key_valid` used to live here and meant only this much; it was renamed
        // rather than kept, so a consumer reading the old name fails loudly
        // instead of silently believing the key was checked against the API.
        try jw.objectField("key_format_valid");
        try jw.write(key_format_valid);
        // Never anything but null: this command does not touch the network, and
        // a `false` here would read as "checked and rejected".
        try jw.objectField("key_verified");
        try jw.write(null);
        try jw.objectField("credential_helper");
        if (cfg.credential_helper) |argv| {
            try jw.beginArray();
            for (argv) |entry| try jw.write(entry);
            try jw.endArray();
        } else {
            try jw.write(null);
        }
        try jw.objectField("keychain_supported");
        try jw.write(credentials.keychain_supported);
        try jw.objectField("file_key_present");
        try jw.write(cfg.file_api_key != null);
        try jw.objectField("config_path");
        try jw.write(cfg.config_path orelse "(unknown)");
        try jw.endObject();

        try out.writeAll(json_buffer.writer.buffered());
        try out.writeByte('\n');
        return if (key_present and key_format_valid) 0 else 1;
    }

    const pairs = [_]printer.KeyValue{
        .{ .key = "source", .value = cfg.key_source.label() },
        .{ .key = "key", .value = if (!key_present)
            "absent"
        else if (key_format_valid)
            "present (format-valid, unverified)"
        else
            "present (malformed)" },
        .{ .key = "verify", .value = "run 'linear auth test' to check the key against the API" },
        .{ .key = "credential_helper", .value = helper_display orelse "(not set)" },
        .{ .key = "keychain", .value = if (credentials.keychain_supported)
            credentials.keychain_binary
        else
            "(unsupported on this platform)" },
        .{ .key = "file_api_key", .value = if (cfg.file_api_key != null)
            "present (deprecated plaintext)"
        else
            "absent" },
        .{ .key = "config_path", .value = cfg.config_path orelse "(unknown)" },
    };
    try printer.printKeyValues(out, pairs[0..]);

    return if (key_present and key_format_valid) 0 else 1;
}

/// Renders argv for display. Helper argv is operator-supplied configuration,
/// not a secret.
fn joinArgv(allocator: Allocator, argv: []const []const u8) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    for (argv, 0..) |entry, idx| {
        if (idx > 0) try buffer.append(allocator, ' ');
        try buffer.appendSlice(allocator, entry);
    }
    return buffer.toOwnedSlice(allocator);
}

/// `--to` names the destination backend and nothing else; the key itself still
/// only ever arrives on stdin or the no-echo prompt. There is no `--api-key`.
pub fn parseSetOptions(args: [][]const u8) !SetOptions {
    var opts = SetOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--to")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            const value = args[idx + 1];
            if (std.mem.eql(u8, value, "file")) {
                opts.target = .file;
            } else if (std.mem.eql(u8, value, "keychain")) {
                opts.target = .keychain;
            } else {
                return error.UnknownBackend;
            }
            idx += 2;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

fn parseTestOptions(args: [][]const u8) !TestOptions {
    var opts = TestOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

fn parseShowOptions(args: [][]const u8) !ShowOptions {
    var opts = ShowOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--reveal")) {
            opts.reveal = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--redacted")) {
            opts.redacted = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn parseStatusOptions(args: [][]const u8) !StatusOptions {
    var opts = StatusOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth <set|test|show|status> [args]
        \\Commands:
        \\  set      Store an API key in the keychain (macOS) or the config file
        \\  show     Display the configured API key (redacted by default)
        \\  status   Report which backend supplies the API key
        \\  test     Validate the configured API key
        \\Resolution order:
        \\  LINEAR_API_KEY > credential_helper > keychain (macOS) > config file
        \\Preferred setup keeps the key off disk entirely:
        \\  linear config set credential_helper "op read op://<vault>/<item>/<field>"
        \\Examples:
        \\  linear auth status
        \\  linear auth set --to keychain
        \\  linear auth test
        \\
    , .{});
}

pub fn setUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth set [--to keychain|file] [--help]
        \\Reads the API key from piped stdin, or prompts for it with terminal echo
        \\disabled. Keys are never accepted on argv, and a key that came from
        \\LINEAR_API_KEY is never written to disk.
        \\
        \\Prefer a credential_helper over either backend below — the key then never
        \\touches disk at all:
        \\  linear config set credential_helper "op read op://<vault>/<item>/<field>"
        \\
        \\To clear old credentials, delete ~/.config/linear/config.json and set up
        \\again; it also holds default_team_id and team_cache, so those reset too.
        \\Rotate the old key in Linear if it was ever stored there in plaintext.
        \\Flags:
        \\  --to keychain    Store the key in the macOS keychain via /usr/bin/security
        \\  --to file        Store the key in the config file, in plaintext. The
        \\                   default, and deprecated: every run that reads it warns
        \\  --help           Show this help message
        \\Examples:
        \\  op read op://Private/Linear/api-key | linear auth set --to keychain
        \\  cat key.txt | linear auth set
        \\  linear auth set
        \\
    , .{});
}

pub fn testUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth test [--help]
        \\Flags:
        \\  --help           Show this help message
        \\Examples:
        \\  linear auth test
        \\
    , .{});
}

pub fn showUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth show [--reveal] [--help]
        \\Flags:
        \\  --reveal        Print the full API key; refused unless stdout is a terminal
        \\  --redacted      No-op; output is redacted by default
        \\  --help          Show this help message
        \\Examples:
        \\  linear auth show
        \\  linear auth show --reveal
        \\
    , .{});
}

pub fn statusUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth status [--help]
        \\Reports which backend supplied the API key and whether it is well-formed.
        \\The key itself is never printed. Exits 0 when a well-formed key was found.
        \\
        \\Offline by design: 'format-valid' means the key matches the expected
        \\charset and length, nothing more. It has not been sent to Linear, so a
        \\revoked or wrong key still reports format-valid. Run 'linear auth test'
        \\to verify the credential against the API.
        \\Resolution order:
        \\  LINEAR_API_KEY > credential_helper > keychain (macOS) > config file
        \\Flags:
        \\  --help          Show this help message
        \\Examples:
        \\  linear auth status
        \\  linear auth status --json
        \\  linear auth test
        \\
    , .{});
}

const EchoState = struct {
    enabled: bool = false,
    previous: std.posix.termios = undefined,
};

fn promptForApiKey(allocator: Allocator, io: std.Io, stderr: anytype) !?[]u8 {
    const stdin_file = std.Io.File.stdin();
    if (!try stdin_file.isTty(io)) return null;

    var prompt_buf: [0]u8 = undefined;
    var prompt_writer = std.Io.File.stderr().writer(io, &prompt_buf);
    try prompt_writer.interface.writeAll("API key: ");

    // Reading with echo left on would type the key straight into the terminal
    // scrollback, so a failure here aborts instead of degrading.
    const echo_state = disableEcho(stdin_file, io) catch |err| {
        try prompt_writer.interface.writeByte('\n');
        try stderr.print("auth set: refusing to read the API key with terminal echo enabled: {s}\n", .{@errorName(err)});
        return common.CommandError.CommandFailed;
    };
    defer restoreEcho(stdin_file, echo_state);

    var input_buf = std.ArrayListUnmanaged(u8).empty;
    defer input_buf.deinit(allocator);

    var tmp: [256]u8 = undefined;
    while (true) {
        const read_len = stdin_file.readStreaming(io, &.{&tmp}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                try stderr.print("auth set: failed to read key: {s}\n", .{@errorName(err)});
                return null;
            },
        };
        if (read_len == 0) break;
        const slice = tmp[0..read_len];
        if (std.mem.indexOfScalar(u8, slice, '\n')) |idx| {
            try input_buf.appendSlice(allocator, slice[0..idx]);
            break;
        }
        try input_buf.appendSlice(allocator, slice);
        if (input_buf.items.len >= 64 * 1024) break;
    }

    const input = try input_buf.toOwnedSlice(allocator);

    try prompt_writer.interface.writeByte('\n');
    return input;
}

fn disableEcho(file: std.Io.File, io: std.Io) !EchoState {
    if (!try file.isTty(io)) return .{};
    if (builtin.os.tag == .windows) return .{};

    const term = try std.posix.tcgetattr(file.handle);
    var no_echo = term;
    no_echo.lflag.ECHO = false;
    try std.posix.tcsetattr(file.handle, .FLUSH, no_echo);
    return .{ .enabled = true, .previous = term };
}

fn restoreEcho(file: std.Io.File, state: EchoState) void {
    if (!state.enabled) return;
    std.posix.tcsetattr(file.handle, .FLUSH, state.previous) catch {};
}
