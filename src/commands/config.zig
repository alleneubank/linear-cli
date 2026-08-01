const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");
const credentials = @import("credentials");
const process = @import("process");

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
    /// `null` means process execution is unavailable, which is what keeps tests
    /// hermetic. `main.zig` installs `process.system_runner`.
    credential_runner: ?process.Runner = null,
};

const ShowOptions = struct {
    help: bool = false,
};

const SetOptions = struct {
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    help: bool = false,
};

const UnsetOptions = struct {
    key: ?[]const u8 = null,
    help: bool = false,
};

const ConfigKey = enum { default_team_id, default_output, default_state_filter, credential_helper };

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

    if (std.mem.eql(u8, sub, "show")) return runShow(ctx, rest);
    if (std.mem.eql(u8, sub, "set")) return runSet(ctx, rest);
    if (std.mem.eql(u8, sub, "unset")) return runUnset(ctx, rest);

    try stderr.print("config: unknown command: {s}\n", .{sub});
    try usage(stderr);
    return 1;
}

fn runShow(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseShowOptions(args) catch |err| {
        try stderr.print("config show: {s}\n", .{@errorName(err)});
        try showUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try showUsage(&out_writer.interface);
        return 0;
    }

    const filter_display = try formatStateFilter(ctx.allocator, ctx.config.default_state_filter);
    defer ctx.allocator.free(filter_display);

    const helper_display = try formatCredentialHelper(ctx.allocator, ctx.config.credential_helper);
    defer ctx.allocator.free(helper_display);

    const state_filter_value: []const u8 = if (filter_display.len == 0) "(none)" else filter_display;
    const team_value: []const u8 = if (ctx.config.default_team_id.len == 0) "(not set)" else ctx.config.default_team_id;
    const config_path = ctx.config.config_path orelse "(unknown)";

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);

        var json_buffer = std.Io.Writer.Allocating.init(ctx.allocator);
        defer json_buffer.deinit();
        var jw = std.json.Stringify{ .writer = &json_buffer.writer, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("config_path");
        try jw.write(config_path);
        try jw.objectField("default_team_id");
        try jw.write(ctx.config.default_team_id);
        try jw.objectField("default_output");
        try jw.write(ctx.config.default_output);
        try jw.objectField("default_state_filter");
        try jw.beginArray();
        for (ctx.config.default_state_filter) |entry| {
            try jw.write(entry);
        }
        try jw.endArray();
        try jw.objectField("credential_helper");
        if (ctx.config.credential_helper) |argv| {
            try jw.beginArray();
            for (argv) |entry| try jw.write(entry);
            try jw.endArray();
        } else {
            try jw.write(null);
        }
        try jw.endObject();

        try out_writer.interface.writeAll(json_buffer.writer.buffered());
        return 0;
    }

    const pairs = [_]printer.KeyValue{
        .{ .key = "config_path", .value = config_path },
        .{ .key = "default_team_id", .value = team_value },
        .{ .key = "default_output", .value = ctx.config.default_output },
        .{ .key = "default_state_filter", .value = state_filter_value },
        .{ .key = "credential_helper", .value = helper_display },
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try printer.printKeyValues(&out_writer.interface, pairs[0..]);
    return 0;
}

fn runSet(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseSetOptions(args) catch |err| {
        try stderr.print("config set: {s}\n", .{@errorName(err)});
        try setUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try setUsage(&out_writer.interface);
        return 0;
    }

    const key_raw = opts.key orelse {
        try stderr.print("config set: missing KEY\n", .{});
        try setUsage(stderr);
        return 1;
    };
    const value_raw = opts.value orelse {
        try stderr.print("config set: missing VALUE\n", .{});
        try setUsage(stderr);
        return 1;
    };
    const trimmed_value = std.mem.trim(u8, value_raw, " \t\r\n");

    const parsed_key = parseKey(key_raw) orelse {
        try stderr.print("config set: unknown key: {s}\n", .{key_raw});
        try setUsage(stderr);
        return 1;
    };

    if (trimmed_value.len == 0 and parsed_key != .default_state_filter) {
        try stderr.print("config set: VALUE cannot be empty\n", .{});
        return 1;
    }

    const save_result = switch (parsed_key) {
        .default_output => setDefaultOutput(ctx, trimmed_value, stderr),
        .default_state_filter => setDefaultStateFilter(ctx, trimmed_value, stderr),
        .default_team_id => setDefaultTeam(ctx, trimmed_value, stderr),
        .credential_helper => setCredentialHelper(ctx, trimmed_value, stderr),
    };
    save_result catch |err| switch (err) {
        error.InvalidValue => return 1,
        common.CommandError.CommandFailed => return 1,
        else => {
            try stderr.print("config set: {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    if (ctx.config.save(ctx.allocator, ctx.config_path)) |_| {} else |err| {
        try stderr.print("config set: failed to save config: {s}\n", .{@errorName(err)});
        return 1;
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try out_writer.interface.print("{s} saved\n", .{keyLabel(parsed_key)});
    return 0;
}

fn runUnset(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseUnsetOptions(args) catch |err| {
        try stderr.print("config unset: {s}\n", .{@errorName(err)});
        try unsetUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try unsetUsage(&out_writer.interface);
        return 0;
    }

    const key_raw = opts.key orelse {
        try stderr.print("config unset: missing KEY\n", .{});
        try unsetUsage(stderr);
        return 1;
    };
    const parsed_key = parseKey(key_raw) orelse {
        try stderr.print("config unset: unknown key: {s}\n", .{key_raw});
        try unsetUsage(stderr);
        return 1;
    };

    switch (parsed_key) {
        .default_team_id => ctx.config.resetDefaultTeamId(),
        .default_output => ctx.config.resetDefaultOutput(),
        .default_state_filter => ctx.config.resetStateFilter(),
        .credential_helper => ctx.config.clearCredentialHelper(),
    }

    if (ctx.config.save(ctx.allocator, ctx.config_path)) |_| {} else |err| {
        try stderr.print("config unset: failed to save config: {s}\n", .{@errorName(err)});
        return 1;
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try out_writer.interface.print("{s} reset\n", .{keyLabel(parsed_key)});
    return 0;
}

fn setDefaultOutput(ctx: Context, value: []const u8, stderr: anytype) !void {
    if (std.ascii.eqlIgnoreCase(value, "table")) {
        try ctx.config.setDefaultOutput("table");
        return;
    }
    if (std.ascii.eqlIgnoreCase(value, "json")) {
        try ctx.config.setDefaultOutput("json");
        return;
    }

    try stderr.print("config set: default_output must be 'table' or 'json'\n", .{});
    return error.InvalidValue;
}

/// Stores a `credential_helper`, but only after proving the helper works.
///
/// This is the only way to configure a helper, and the only setup route where
/// the API key never touches disk at all — which is the backend's entire
/// premise. Writing the key to `config.json` first and moving it afterwards
/// defeats that: once it has been on disk it has to be rotated regardless.
///
/// What made `config set credential_helper` unsafe was the missing
/// verification, not the command. A stored-but-broken helper is not a soft
/// failure: `credentials.resolve` *clears* the effective key when a configured
/// helper fails rather than falling through to any other backend, so saving one
/// that does not work locks the operator out of their own credential. So the
/// helper is spawned here and has to hand back a usable key before anything is
/// written.
///
/// The key the helper produces is used for exactly one thing — deciding whether
/// to save — and is never printed, logged, stored, or returned. Only the argv,
/// which is operator-supplied configuration rather than a secret, is persisted.
fn setCredentialHelper(ctx: Context, value: []const u8, stderr: anytype) !void {
    const runner = ctx.credential_runner orelse {
        try stderr.print("config set: process execution is unavailable\n", .{});
        return common.CommandError.CommandFailed;
    };

    // Whitespace split with no shell semantics, using the same parser the
    // config file's bare-string form goes through: quotes, pipes, `;`, and
    // `$VAR` are ordinary bytes inside an argv element.
    const argv = config.splitCredentialHelper(ctx.allocator, value) catch |err| switch (err) {
        config.CredentialHelperError.EmptyCredentialHelper => |helper_err| {
            try stderr.print("config set: {s}\n", .{config.credentialHelperErrorText(helper_err)});
            return error.InvalidValue;
        },
        else => return err,
    };
    defer ctx.allocator.free(argv);

    // Bounds first, so an argv that could never be stored is never spawned.
    config.validateCredentialHelper(argv) catch |err| {
        try stderr.print("config set: {s}\n", .{config.credentialHelperErrorText(err)});
        return error.InvalidValue;
    };

    const name = try credentials.helperName(ctx.allocator, argv);
    defer ctx.allocator.free(name);

    const outcome = try credentials.runHelper(runner, ctx.allocator, ctx.io, argv);
    defer outcome.deinit(ctx.allocator);

    switch (outcome) {
        // Discarded without ever being looked at beyond `runHelper`'s own
        // validation. Nothing below this line can reach the key.
        .key => {},
        // `runHelper` never reports `absent`: exit 0 with no output is a
        // failure, not an empty store.
        .absent => unreachable,
        .failure => |failure| {
            try credentials.printFailure(failure, name, stderr, "config set");
            try stderr.print("config set: credential_helper was not saved\n", .{});
            return error.InvalidValue;
        },
    }

    ctx.config.setCredentialHelper(argv) catch |err| switch (err) {
        config.CredentialHelperError.EmptyCredentialHelper,
        config.CredentialHelperError.TooManyCredentialHelperArgs,
        config.CredentialHelperError.InvalidCredentialHelperArg,
        config.CredentialHelperError.InvalidCredentialHelper,
        => |helper_err| {
            try stderr.print("config set: {s}\n", .{config.credentialHelperErrorText(helper_err)});
            return error.InvalidValue;
        },
        else => return err,
    };
}

fn setDefaultStateFilter(ctx: Context, value: []const u8, stderr: anytype) !void {
    const parsed = parseStateFilterValues(ctx.allocator, value) catch |err| {
        try stderr.print("config set: {s}\n", .{@errorName(err)});
        return error.InvalidValue;
    };
    defer ctx.allocator.free(parsed);

    try ctx.config.setStateFilterValues(parsed);
}

/// Validates the team against the workspace and only then persists it.
///
/// The two ways validation can end are kept apart on purpose, because they mean
/// opposite things to the operator:
///
///   * `error.InvalidTeam` — the lookup succeeded and the workspace has no such
///     team. That is a verdict, so it is a hard failure and nothing is written.
///     Warning and saving anyway (what this used to do) is worse than not
///     checking at all: the exit status says the value was accepted, and the
///     mistake only surfaces at the next command that needs a team.
///   * anything else — the lookup itself did not complete (timeout, 5xx, no
///     connectivity). That is not evidence the team is wrong, so the diagnostic
///     names the lookup as the thing that failed. The underlying cause was
///     already printed by `common.send`/`checkResponse`.
///
/// Both paths refuse to write, and neither pretends to be the other. There is
/// deliberately no `--force`: an unverified team id is exactly what this
/// function exists to keep out of the config file, and `linear config unset
/// default_team_id` plus a per-command `--team` covers working offline.
fn setDefaultTeam(ctx: Context, value: []const u8, stderr: anytype) !void {
    const api_key = common.requireApiKey(ctx.config, null, stderr, "config set") catch {
        return common.CommandError.CommandFailed;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    validateTeamSelection(ctx, &client, value, stderr) catch |err| switch (err) {
        error.InvalidTeam => {
            try stderr.print(
                "config set: team '{s}' not found in workspace; default_team_id was not changed\n",
                .{value},
            );
            try stderr.print("config set: run 'linear teams list' to see the available team keys\n", .{});
            return error.InvalidValue;
        },
        else => {
            try stderr.print(
                "config set: could not verify team '{s}'; default_team_id was not changed\n",
                .{value},
            );
            return common.CommandError.CommandFailed;
        },
    };

    try ctx.config.setDefaultTeamId(value);
}

fn validateTeamSelection(ctx: Context, client: *graphql.GraphqlClient, team_value: []const u8, stderr: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    try eq_obj.object.put(var_alloc, "eq", .{ .string = team_value });
    const filter_key = if (isUuid(team_value)) "id" else "key";
    try filter.object.put(var_alloc, filter_key, eq_obj);

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "filter", filter);
    try variables.object.put(var_alloc, "first", .{ .integer = 1 });

    const query =
        \\query TeamLookup($filter: TeamFilter, $first: Int!) {
        \\  teams(filter: $filter, first: $first) {
        \\    nodes { id key }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "config set", client, .{
        .query = query,
        .variables = variables,
        .operation_name = "TeamLookup",
    }, stderr) catch {
        return common.CommandError.CommandFailed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "config set", &response, stderr, client.api_key) catch {
        return common.CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("config set: response missing data\n", .{});
        return common.CommandError.CommandFailed;
    };
    const teams_obj = common.getObjectField(data_value, "teams") orelse {
        try stderr.print("config set: teams missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    const nodes_array = common.getArrayField(teams_obj, "nodes") orelse {
        try stderr.print("config set: team nodes missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    if (nodes_array.items.len == 0) return error.InvalidTeam;

    const first = nodes_array.items[0];
    if (first != .object) {
        try stderr.print("config set: invalid team payload\n", .{});
        return common.CommandError.CommandFailed;
    }
    const id_value = common.getStringField(first, "id") orelse {
        try stderr.print("config set: team id missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    const key_value = common.getStringField(first, "key");

    cacheTeamLookup(ctx, team_value, id_value, key_value, stderr);
}

fn cacheTeamLookup(ctx: Context, provided: []const u8, id_value: []const u8, key_value: ?[]const u8, stderr: anytype) void {
    const cache_targets = [_][]const u8{
        provided,
        key_value orelse "",
    };

    for (cache_targets) |entry| {
        if (entry.len == 0) continue;
        const cached = ctx.config.cacheTeamId(entry, id_value);
        if (cached) |_| {} else |err| {
            stderr.print("config set: warning: failed to cache team id: {s}\n", .{@errorName(err)}) catch {};
        }
    }
}

fn parseShowOptions(args: [][]const u8) !ShowOptions {
    var opts = ShowOptions{};
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

fn parseSetOptions(args: [][]const u8) !SetOptions {
    var opts = SetOptions{};
    var positionals: [2][]const u8 = undefined;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (count >= positionals.len) return error.UnexpectedArgument;
        positionals[count] = arg;
        count += 1;
    }
    if (count > 0) opts.key = positionals[0];
    if (count > 1) opts.value = positionals[1];
    return opts;
}

fn parseUnsetOptions(args: [][]const u8) !UnsetOptions {
    var opts = UnsetOptions{};
    var positionals: [1][]const u8 = undefined;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (count >= positionals.len) return error.UnexpectedArgument;
        positionals[count] = arg;
        count += 1;
    }
    if (count > 0) opts.key = positionals[0];
    return opts;
}

fn parseKey(value: []const u8) ?ConfigKey {
    if (std.ascii.eqlIgnoreCase(value, "default_team_id")) return .default_team_id;
    if (std.ascii.eqlIgnoreCase(value, "default_output")) return .default_output;
    if (std.ascii.eqlIgnoreCase(value, "default_state_filter")) return .default_state_filter;
    if (std.ascii.eqlIgnoreCase(value, "credential_helper")) return .credential_helper;
    return null;
}

fn keyLabel(key: ConfigKey) []const u8 {
    return switch (key) {
        .default_team_id => "default_team_id",
        .default_output => "default_output",
        .default_state_filter => "default_state_filter",
        .credential_helper => "credential_helper",
    };
}

/// Renders the helper argv for display. Helper argv is operator-supplied
/// configuration, not a secret; the key it fetches never passes through here.
fn formatCredentialHelper(allocator: Allocator, argv: ?[]const []const u8) ![]u8 {
    const entries = argv orelse return allocator.dupe(u8, "(not set)");

    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try buffer.append(allocator, ' ');
        try buffer.appendSlice(allocator, entry);
    }
    return buffer.toOwnedSlice(allocator);
}

fn parseStateFilterValues(allocator: Allocator, raw: []const u8) ![]const []const u8 {
    var values = std.ArrayListUnmanaged([]const u8).empty;
    errdefer values.deinit(allocator);

    var iter = std.mem.tokenizeScalar(u8, raw, ',');
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try values.append(allocator, trimmed);
    }

    return values.toOwnedSlice(allocator);
}

fn formatStateFilter(allocator: Allocator, values: []const []const u8) ![]u8 {
    if (values.len == 0) {
        return allocator.dupe(u8, "(none)");
    }

    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    for (values, 0..) |entry, idx| {
        if (idx > 0) try buffer.append(allocator, ',');
        try buffer.appendSlice(allocator, entry);
    }
    return buffer.toOwnedSlice(allocator);
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (value[idx] != '-') return false;
    }
    return true;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear config show|set|unset [args]
        \\Commands:
        \\  show                 Display current config values
        \\  set KEY VALUE        Set a config value (see 'linear help config set')
        \\  unset KEY            Reset a config value to its default
        \\
    , .{});
}

pub fn showUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear config show [--help]
        \\Flags:
        \\  --help    Show this help message
        \\
    , .{});
}

pub fn setUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear config set KEY VALUE [--help]
        \\Keys:
        \\  default_team_id       Default team for commands (team key or UUID).
        \\                        Verified against the workspace; an unknown team
        \\                        is refused and nothing is written.
        \\  default_output        Default output format: table|json
        \\  default_state_filter  Comma-separated state types to exclude by default
        \\  credential_helper     External command whose stdout is the API key.
        \\                        Run once and required to return a usable key
        \\                        before it is saved; a broken helper is refused,
        \\                        because a stored one clears the key instead of
        \\                        falling through to another backend.
        \\                        Split on whitespace into argv with NO shell
        \\                        semantics: quotes, pipes, ';' and $VAR are
        \\                        ordinary characters. Max 16 arguments, 1024
        \\                        bytes each. Remove it with
        \\                        'linear config unset credential_helper'.
        \\Flags:
        \\  --help                Show this help message
        \\Examples:
        \\  linear config set default_team_id ENG
        \\  linear config set default_output json
        \\  linear config set default_state_filter completed,canceled
        \\  linear config set credential_helper "op read op://Private/Linear/api-key"
        \\
    , .{});
}

pub fn unsetUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear config unset KEY [--help]
        \\Keys:
        \\  default_team_id       Default team for commands
        \\  default_output        Default output format
        \\  default_state_filter  Default state exclusion filter
        \\  credential_helper     External command that prints the API key
        \\Flags:
        \\  --help                Show this help message
        \\Examples:
        \\  linear config unset default_team_id
        \\  linear config unset default_output
        \\  linear config unset default_state_filter
        \\  linear config unset credential_helper
        \\
    , .{});
}
