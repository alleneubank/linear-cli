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

const SetOptions = struct {
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

/// Backend `auth migrate` moves the key to. There is no default: picking one
/// silently would decide where the operator's credential lives for them.
pub const MigrateTarget = enum { helper, keychain };

pub const MigrateOptions = struct {
    target: ?MigrateTarget = null,
    /// argv for `--to helper`, borrowed from the command line.
    helper_argv: []const []const u8 = &.{},
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
    if (std.mem.eql(u8, sub, "migrate")) {
        return runMigrate(ctx, rest);
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

    ctx.config.setApiKey(key.?) catch |err| switch (err) {
        config.ApiKeyError.InvalidApiKey => {
            try stderr.print(
                "auth set: invalid API key; expected {d}-{d} characters from [A-Za-z0-9_-]\n",
                .{ config.min_api_key_len, config.max_api_key_len },
            );
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

/// Moves the plaintext key out of the config file and into a real backend.
///
/// The order is deliberate: write, then read back and compare, and only then
/// remove the plaintext copy. A half-finished migration that has already
/// deleted the file key would leave the operator with no credential at all.
fn runMigrate(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseMigrateOptions(args) catch |err| {
        try stderr.print("auth migrate: {s}\n", .{@errorName(err)});
        try migrateUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try migrateUsage(&out_writer.interface);
        return 0;
    }

    const target = opts.target orelse {
        try stderr.print("auth migrate: missing --to; expected '--to helper <command>' or '--to keychain'\n", .{});
        try migrateUsage(stderr);
        return 1;
    };

    // Only the on-disk key is migratable. An environment key is not ours to
    // move, and a key already supplied by a helper or the keychain is done.
    const file_key = ctx.config.file_api_key orelse {
        try stderr.print("auth migrate: no API key in the config file to migrate\n", .{});
        return 1;
    };

    const runner = ctx.credential_runner orelse {
        try stderr.print("auth migrate: process execution is unavailable\n", .{});
        return 1;
    };

    // `file_key` is freed by `clearFileApiKey` below, so the verification and
    // the comparison both work off a copy that outlives it.
    const expected = try ctx.allocator.dupe(u8, file_key);
    defer {
        @memset(expected, 0);
        ctx.allocator.free(expected);
    }

    switch (target) {
        .helper => {
            if (opts.helper_argv.len == 0) {
                try stderr.print("auth migrate: '--to helper' needs the command that prints the API key\n", .{});
                try migrateUsage(stderr);
                return 1;
            }
            const helper_argv = helperArgvFromArgs(ctx.allocator, opts.helper_argv) catch |err| switch (err) {
                config.CredentialHelperError.EmptyCredentialHelper => {
                    try stderr.print("auth migrate: '--to helper' needs the command that prints the API key\n", .{});
                    return 1;
                },
                else => return err,
            };
            defer ctx.allocator.free(helper_argv);

            ctx.config.setCredentialHelper(helper_argv) catch |err| switch (err) {
                config.CredentialHelperError.EmptyCredentialHelper,
                config.CredentialHelperError.TooManyCredentialHelperArgs,
                config.CredentialHelperError.InvalidCredentialHelperArg,
                config.CredentialHelperError.InvalidCredentialHelper,
                => |helper_err| {
                    try stderr.print("auth migrate: {s}\n", .{config.credentialHelperErrorText(helper_err)});
                    return 1;
                },
                else => return err,
            };
            // `setCredentialHelper` only touched memory; nothing is written to
            // disk unless the read-back below succeeds.
            const argv = ctx.config.credential_helper.?;
            const name = try credentials.helperName(ctx.allocator, argv);
            defer ctx.allocator.free(name);

            const outcome = try credentials.runHelper(runner, ctx.allocator, ctx.io, argv);
            defer outcome.deinit(ctx.allocator);

            switch (outcome) {
                .key => |key| {
                    if (!std.mem.eql(u8, key, expected)) {
                        ctx.config.clearCredentialHelper();
                        try stderr.print(
                            "auth migrate: {s} returned a different key than the config file holds; nothing was changed\n",
                            .{name},
                        );
                        return 1;
                    }
                    try ctx.config.setApiKeyFromProvider(key, .helper);
                },
                .absent => unreachable,
                .failure => |failure| {
                    ctx.config.clearCredentialHelper();
                    try credentials.printFailure(failure, name, stderr, "auth migrate");
                    return 1;
                },
            }
        },
        .keychain => {
            if (!credentials.keychain_supported) {
                try stderr.print("auth migrate: the keychain backend is only available on macOS\n", .{});
                return 1;
            }

            const write_outcome = credentials.writeKeychain(runner, ctx.allocator, ctx.io, expected) catch |err| switch (err) {
                credentials.KeychainWriteError.LeadingDash => {
                    try stderr.print(
                        "auth migrate: this API key starts with '-', which {s} would read as an option; " ++
                            "use '--to helper' instead\n",
                        .{credentials.keychain_binary},
                    );
                    return 1;
                },
                else => return err,
            };
            defer write_outcome.deinit(ctx.allocator);

            switch (write_outcome) {
                .failure => |failure| {
                    try credentials.printFailure(failure, credentials.keychain_binary, stderr, "auth migrate");
                    return 1;
                },
                .absent => {},
                .key => unreachable,
            }

            const read_outcome = try credentials.readKeychain(runner, ctx.allocator, ctx.io);
            defer read_outcome.deinit(ctx.allocator);

            switch (read_outcome) {
                .key => |key| {
                    if (!std.mem.eql(u8, key, expected)) {
                        try stderr.print(
                            "auth migrate: the keychain read back a different key than was written; nothing was changed\n",
                            .{},
                        );
                        return 1;
                    }
                    try ctx.config.setApiKeyFromProvider(key, .keychain);
                },
                .absent => {
                    try stderr.print(
                        "auth migrate: the keychain item could not be read back after writing it; nothing was changed\n",
                        .{},
                    );
                    return 1;
                },
                .failure => |failure| {
                    try credentials.printFailure(failure, credentials.keychain_binary, stderr, "auth migrate");
                    return 1;
                },
            }
        },
    }

    // Verified. Only now does the plaintext copy go away, and it goes away by
    // overwriting the bytes rather than truncating over them.
    ctx.config.clearFileApiKey();
    ctx.config.saveScrubbed(ctx.allocator, ctx.config_path) catch |err| {
        try stderr.print("auth migrate: failed to rewrite the config file: {s}\n", .{@errorName(err)});
        return 1;
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try out_writer.interface.print(
        "api key migrated to {s}; the plaintext copy has been removed from the config file\n",
        .{ctx.config.key_source.label()},
    );
    try out_writer.interface.print(
        "the key was on disk in plaintext, so treat it as disclosed and consider rotating it\n",
        .{},
    );
    return 0;
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

fn parseSetOptions(args: [][]const u8) !SetOptions {
    var opts = SetOptions{};
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

/// `--to helper` consumes every remaining argument as argv elements, which is
/// how the array form is expressed on the command line. A single argument
/// containing whitespace is split instead, so a copy-pasted one-liner works
/// too — with no shell semantics, so quoting inside it is not supported.
pub fn parseMigrateOptions(args: [][]const u8) !MigrateOptions {
    var opts = MigrateOptions{};
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
            if (std.mem.eql(u8, value, "helper")) {
                opts.target = .helper;
                opts.helper_argv = args[idx + 2 ..];
                return opts;
            }
            if (std.mem.eql(u8, value, "keychain")) {
                opts.target = .keychain;
                idx += 2;
                continue;
            }
            return error.UnknownBackend;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

/// Expands `--to helper`'s trailing arguments into argv.
///
/// Caller owns the returned slice; the elements borrow `args`. A single
/// argument is whitespace-split, anything else is taken verbatim.
pub fn helperArgvFromArgs(allocator: Allocator, args: []const []const u8) ![][]const u8 {
    if (args.len == 1) return config.splitCredentialHelper(allocator, args[0]);
    return allocator.dupe([]const u8, args);
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth <set|test|show|status|migrate> [args]
        \\Commands:
        \\  set      Store an API key in the config file (deprecated; prefer migrate)
        \\  show     Display the configured API key (redacted by default)
        \\  status   Report which backend supplies the API key
        \\  migrate  Move the plaintext config-file key to a real backend
        \\  test     Validate the configured API key
        \\Resolution order:
        \\  LINEAR_API_KEY > credential_helper > keychain (macOS) > config file
        \\Examples:
        \\  linear auth status
        \\  linear auth migrate --to keychain
        \\  linear auth test
        \\
    , .{});
}

pub fn setUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth set [--help]
        \\Reads the API key from piped stdin, or prompts for it with terminal echo
        \\disabled. Keys are never accepted on argv, and a key that came from
        \\LINEAR_API_KEY is never written to disk.
        \\Flags:
        \\  --help           Show this help message
        \\Examples:
        \\  linear auth set
        \\  cat key.txt | linear auth set
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

pub fn migrateUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear auth migrate --to <keychain|helper COMMAND...> [--help]
        \\Moves the plaintext API key out of the config file. The key is written to
        \\the chosen backend, read back, and compared before the plaintext copy is
        \\removed, so a failed migration never leaves you without a credential.
        \\
        \\'--to helper' does not push the key anywhere: put it in your secret manager
        \\first, then point the helper at it. The migration verifies the helper hands
        \\back the same key before removing the plaintext one.
        \\
        \\A helper is an argv array, never a shell command line: no quoting, no pipes,
        \\no variable expansion. A single argument is split on whitespace as a
        \\convenience; pass separate arguments when any of them contains a space.
        \\Flags:
        \\  --to keychain       Store the key in the macOS keychain via /usr/bin/security
        \\  --to helper CMD...  Store the helper argv in credential_helper
        \\  --help              Show this help message
        \\Examples:
        \\  linear auth migrate --to keychain
        \\  linear auth migrate --to helper op read op://Private/Linear/api-key
        \\  linear auth migrate --to helper "pass show linear/api-key"
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
