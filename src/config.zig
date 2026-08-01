const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_team_id_value = "";
pub const default_output_value = "table";
pub const default_state_filter_value = [_][]const u8{ "completed", "canceled" };
const linear_api_key_env = "LINEAR_API_KEY";
const linear_config_env = "LINEAR_CONFIG";

/// Config files are created 0600 and their parent directory 0700; the key they
/// hold is a full-write Linear credential.
pub const config_file_mode = 0o600;
pub const config_dir_mode = 0o700;

pub const min_api_key_len = 4;
pub const max_api_key_len = 512;

pub const ApiKeyError = error{InvalidApiKey};

/// Upper bounds on `credential_helper`. A helper is an argv array, not a
/// command line, so these only exist to turn a corrupted config file into a
/// clear diagnostic instead of an unbounded allocation.
pub const max_credential_helper_args = 16;
pub const max_credential_helper_arg_len = 1024;

pub const CredentialHelperError = error{
    /// The array was empty, or a bare string had no non-whitespace content.
    EmptyCredentialHelper,
    /// More than `max_credential_helper_args` elements.
    TooManyCredentialHelperArgs,
    /// An element was empty or longer than `max_credential_helper_arg_len`.
    InvalidCredentialHelperArg,
    /// The JSON value was neither an array of strings nor a string.
    InvalidCredentialHelper,
};

pub fn credentialHelperErrorText(err: CredentialHelperError) []const u8 {
    return switch (err) {
        CredentialHelperError.EmptyCredentialHelper => "credential_helper must name a command",
        CredentialHelperError.TooManyCredentialHelperArgs => "credential_helper has too many arguments",
        CredentialHelperError.InvalidCredentialHelperArg => "credential_helper arguments must be non-empty and shorter than 1024 bytes",
        CredentialHelperError.InvalidCredentialHelper => "credential_helper must be an array of strings",
    };
}

/// Where the effective API key came from.
///
/// The chain is `environment -> helper -> keychain -> file`; only `file` is
/// ever written back to disk. `helper_failed` is a distinct state rather than
/// a silent `none` because a configured helper that fails must not be
/// indistinguishable from having no credentials at all.
pub const KeySource = enum {
    none,
    environment,
    helper,
    keychain,
    file,
    helper_failed,

    pub fn label(self: KeySource) []const u8 {
        return switch (self) {
            .none => "none",
            .environment => "environment",
            .helper => "credential_helper",
            .keychain => "keychain",
            .file => "config file",
            .helper_failed => "credential_helper (failed)",
        };
    }

    /// True when the key must never be written to disk.
    pub fn isEphemeral(self: KeySource) bool {
        return switch (self) {
            .environment, .helper, .keychain => true,
            .none, .file, .helper_failed => false,
        };
    }
};

/// API keys are written verbatim into the `Authorization` request head, so any
/// byte outside `[A-Za-z0-9_-]` (notably CR/LF) would allow header injection
/// from a tampered config file, `LINEAR_CONFIG`, or `LINEAR_API_KEY`. Every
/// ingestion point validates against this charset before the key is stored.
pub fn isValidApiKey(value: []const u8) bool {
    if (value.len < min_api_key_len or value.len > max_api_key_len) return false;
    for (value) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

pub const Config = struct {
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    /// Effective key: the environment value wins over the file value.
    api_key: ?[]const u8 = null,
    /// Key that belongs on disk. Environment keys never reach this field, so
    /// `save` can never leak them, and a file key survives a save performed
    /// while `LINEAR_API_KEY` is set.
    file_api_key: ?[]const u8 = null,
    /// External command whose stdout is the API key. Stored as argv so no
    /// shell is ever involved and nothing is word-split at use time. Owned.
    credential_helper: ?[]const []const u8 = null,
    default_team_id: []const u8 = default_team_id_value,
    default_output: []const u8 = default_output_value,
    default_state_filter: []const []const u8 = &default_state_filter_value,

    owned_api_key: bool = false,
    owned_default_team_id: bool = false,
    owned_default_output: bool = false,
    owned_state_filter: bool = false,
    /// Provenance of `api_key`. Invariant: `api_key != null` exactly when this
    /// is one of `environment`, `helper`, `keychain`, or `file`.
    key_source: KeySource = .none,
    permissions_warning: bool = false,
    config_path: ?[]const u8 = null,
    owned_config_path: bool = false,
    team_cache: std.StringHashMap([]const u8) = undefined,

    pub fn deinit(self: *Config) void {
        if (self.owned_api_key) {
            if (self.api_key) |key| self.allocator.free(key);
        }
        if (self.file_api_key) |key| self.allocator.free(key);
        self.clearCredentialHelper();
        if (self.owned_default_team_id) {
            self.allocator.free(self.default_team_id);
        }
        if (self.owned_default_output) {
            self.allocator.free(self.default_output);
        }
        if (self.owned_state_filter) {
            for (self.default_state_filter) |entry| {
                self.allocator.free(entry);
            }
            self.allocator.free(self.default_state_filter);
        }
        if (self.owned_config_path) {
            if (self.config_path) |path| self.allocator.free(path);
        }

        var it = self.team_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.team_cache.deinit();
    }

    pub fn resolveApiKey(self: *Config, override_key: ?[]const u8) ![]const u8 {
        if (override_key) |key| return key;
        if (self.api_key) |key| return key;
        return error.MissingApiKey;
    }

    pub fn applyEnvOverrides(self: *Config) !void {
        if (self.environ.getAlloc(self.allocator, linear_api_key_env)) |value| {
            defer self.allocator.free(value);
            try self.setApiKeyFromEnv(value);
        } else |err| switch (err) {
            error.EnvironmentVariableMissing => {},
            else => return err,
        }
    }

    pub fn save(self: *const Config, allocator: Allocator, override_path: ?[]const u8) !void {
        const path = try resolveSavePath(self, allocator, override_path);
        defer allocator.free(path);

        if (std.fs.path.dirname(path)) |dir_path| {
            _ = try std.Io.Dir.cwd().createDirPathStatus(self.io, dir_path, .fromMode(config_dir_mode));
        }

        // The permissions are part of the create call so the file is never
        // observable at the default 0644 between creation and the chmod below.
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{
            .truncate = true,
            .read = true,
            .permissions = .fromMode(config_file_mode),
        });
        defer file.close(self.io);

        // Repairs a pre-existing file whose permissions drifted; creating with
        // the mode above only applies to files this call creates.
        try file.setPermissions(self.io, .fromMode(config_file_mode));

        var json_buffer = std.Io.Writer.Allocating.init(allocator);
        defer json_buffer.deinit();
        var jw = std.json.Stringify{ .writer = &json_buffer.writer, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();

        if (self.file_api_key) |key| {
            try jw.objectField("api_key");
            try jw.write(key);
        }

        if (self.credential_helper) |argv| {
            try jw.objectField("credential_helper");
            try jw.beginArray();
            for (argv) |entry| {
                try jw.write(entry);
            }
            try jw.endArray();
        }

        if (self.default_team_id.len != 0) {
            try jw.objectField("default_team_id");
            try jw.write(self.default_team_id);
        }

        if (self.default_output.len != 0) {
            try jw.objectField("default_output");
            try jw.write(self.default_output);
        }

        try jw.objectField("default_state_filter");
        try jw.beginArray();
        for (self.default_state_filter) |state| {
            try jw.write(state);
        }
        try jw.endArray();

        if (self.team_cache.count() > 0) {
            try jw.objectField("team_cache");
            try jw.beginObject();
            var it = self.team_cache.iterator();
            while (it.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.write(entry.value_ptr.*);
            }
            try jw.endObject();
        }

        try jw.endObject();
        try file.writeStreamingAll(self.io, json_buffer.writer.buffered());
    }

    /// `save`, preceded by overwriting whatever is currently on disk.
    ///
    /// Plain `save` truncates, which returns the old blocks — still holding the
    /// previous `api_key` bytes — to the free list where they stay readable.
    /// Overwriting in place first means the removed key is gone from the blocks
    /// the file already owns, so this is what the "remove the plaintext key"
    /// paths use.
    ///
    /// Best effort by nature: on a copy-on-write filesystem (APFS, Btrfs) the
    /// overwrite may land on fresh blocks, and it says nothing about snapshots,
    /// Time Machine copies, or synced folders that already captured the file.
    /// Treat a key that has been on disk as disclosed and rotate it.
    pub fn saveScrubbed(self: *const Config, allocator: Allocator, override_path: ?[]const u8) !void {
        const path = try resolveSavePath(self, allocator, override_path);
        defer allocator.free(path);

        try scrubFile(self.io, path);
        try self.save(allocator, override_path);
    }

    /// Records a key supplied by the config file or an explicit `auth set`.
    /// This is the only provenance `save` writes back to disk.
    pub fn setApiKey(self: *Config, value: []const u8) !void {
        if (!isValidApiKey(value)) return ApiKeyError.InvalidApiKey;

        const effective = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(effective);
        const persisted = try self.allocator.dupe(u8, value);

        self.replaceApiKey(effective, .file);
        self.replaceFileApiKey(persisted);
    }

    /// Records an environment-derived key. The file-backed key is left intact so
    /// a later `save` neither persists the environment value nor drops the key
    /// already on disk.
    pub fn setApiKeyFromEnv(self: *Config, value: []const u8) !void {
        return self.setApiKeyFromProvider(value, .environment);
    }

    /// Records a key produced by a credential backend that is not the config
    /// file. `file_api_key` is deliberately untouched: the same reasoning that
    /// keeps `LINEAR_API_KEY` off disk applies to a helper or the keychain, and
    /// a key already on disk must survive a `save` performed while one of them
    /// is supplying the effective value.
    pub fn setApiKeyFromProvider(self: *Config, value: []const u8, source: KeySource) !void {
        std.debug.assert(source.isEphemeral());
        if (!isValidApiKey(value)) return ApiKeyError.InvalidApiKey;

        const effective = try self.allocator.dupe(u8, value);
        self.replaceApiKey(effective, source);
    }

    /// Drops the effective key while leaving `file_api_key` alone, so the value
    /// on disk survives for `auth migrate` even after the chain refused to use
    /// it. Used when a configured helper fails: falling through to the
    /// deprecated plaintext key would be exactly the silent degradation the
    /// helper was configured to avoid.
    pub fn clearEffectiveApiKey(self: *Config, source: KeySource) void {
        std.debug.assert(!source.isEphemeral());
        if (self.owned_api_key) {
            if (self.api_key) |current| self.allocator.free(current);
        }
        self.api_key = null;
        self.owned_api_key = false;
        self.key_source = source;
    }

    /// Removes the persisted copy of the key so the next `save` writes no
    /// `api_key` field. The effective key is a separate allocation and is left
    /// in place.
    pub fn clearFileApiKey(self: *Config) void {
        if (self.file_api_key) |key| self.allocator.free(key);
        self.file_api_key = null;
        if (self.key_source == .file) self.clearEffectiveApiKey(.none);
    }

    fn replaceApiKey(self: *Config, owned_value: []const u8, source: KeySource) void {
        if (self.owned_api_key) {
            if (self.api_key) |current| self.allocator.free(current);
        }
        self.api_key = owned_value;
        self.owned_api_key = true;
        self.key_source = source;
    }

    fn replaceFileApiKey(self: *Config, owned_value: []const u8) void {
        if (self.file_api_key) |current| self.allocator.free(current);
        self.file_api_key = owned_value;
    }

    /// Stores the helper argv. Elements are copied, so the caller keeps
    /// ownership of what it passed in.
    pub fn setCredentialHelper(self: *Config, argv: []const []const u8) !void {
        try validateCredentialHelper(argv);

        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |entry| self.allocator.free(entry);
            list.deinit(self.allocator);
        }
        for (argv) |entry| {
            const duped = try self.allocator.dupe(u8, entry);
            try list.append(self.allocator, duped);
        }
        const owned = try list.toOwnedSlice(self.allocator);

        self.clearCredentialHelper();
        self.credential_helper = owned;
    }

    pub fn clearCredentialHelper(self: *Config) void {
        const argv = self.credential_helper orelse return;
        for (argv) |entry| self.allocator.free(entry);
        self.allocator.free(argv);
        self.credential_helper = null;
    }

    /// Reads the `credential_helper` config value.
    ///
    /// The documented form is a JSON array of argv elements, which makes
    /// quoting unambiguous. A bare string is accepted for convenience and is
    /// split on ASCII whitespace with *no* shell semantics: no quoting, no
    /// escapes, no variable expansion, no globbing. An argument that needs a
    /// space must use the array form.
    pub fn setCredentialHelperValue(self: *Config, value: std.json.Value) !void {
        switch (value) {
            .array => |arr| {
                var list = std.ArrayList([]const u8).empty;
                defer list.deinit(self.allocator);
                for (arr.items) |entry| {
                    if (entry != .string) return CredentialHelperError.InvalidCredentialHelper;
                    try list.append(self.allocator, entry.string);
                }
                return self.setCredentialHelper(list.items);
            },
            .string => |command| {
                const split = try splitCredentialHelper(self.allocator, command);
                defer self.allocator.free(split);
                return self.setCredentialHelper(split);
            },
            else => return CredentialHelperError.InvalidCredentialHelper,
        }
    }

    pub fn setDefaultTeamId(self: *Config, value: []const u8) !void {
        try replaceRequiredString(self.allocator, &self.default_team_id, &self.owned_default_team_id, value);
    }

    pub fn resetDefaultTeamId(self: *Config) void {
        if (self.owned_default_team_id) {
            self.allocator.free(self.default_team_id);
            self.owned_default_team_id = false;
        }
        self.default_team_id = default_team_id_value;
    }

    pub fn setDefaultOutput(self: *Config, value: []const u8) !void {
        try replaceRequiredString(self.allocator, &self.default_output, &self.owned_default_output, value);
    }

    pub fn resetDefaultOutput(self: *Config) void {
        if (self.owned_default_output) {
            self.allocator.free(self.default_output);
            self.owned_default_output = false;
        }
        self.default_output = default_output_value;
    }

    pub fn resetStateFilter(self: *Config) void {
        if (self.owned_state_filter) {
            for (self.default_state_filter) |entry| self.allocator.free(entry);
            self.allocator.free(self.default_state_filter);
            self.owned_state_filter = false;
        }
        self.default_state_filter = &default_state_filter_value;
    }

    pub fn setStateFilterValues(self: *Config, values: []const []const u8) !void {
        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |entry| self.allocator.free(entry);
            list.deinit(self.allocator);
        }

        for (values) |entry| {
            const duped = try self.allocator.dupe(u8, entry);
            try list.append(self.allocator, duped);
        }

        const new_filter = try list.toOwnedSlice(self.allocator);

        if (self.owned_state_filter) {
            for (self.default_state_filter) |entry| self.allocator.free(entry);
            self.allocator.free(self.default_state_filter);
        }

        self.default_state_filter = new_filter;
        self.owned_state_filter = true;
    }

    pub fn setStateFilter(self: *Config, value: std.json.Value) !void {
        const entries = switch (value) {
            .array => |arr| arr.items,
            else => return error.InvalidConfig,
        };

        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(self.allocator);
        for (entries) |entry| {
            if (entry != .string) return error.InvalidConfig;
            try list.append(self.allocator, entry.string);
        }

        const items = list.items;
        const result = self.setStateFilterValues(items);
        list.deinit(self.allocator);
        return result;
    }

    pub fn cacheTeamId(self: *Config, key: []const u8, id: []const u8) !bool {
        if (self.team_cache.get(key)) |existing| {
            if (std.mem.eql(u8, existing, id)) return false;
        }

        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);
        const duped_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(duped_id);

        if (try self.team_cache.fetchPut(duped_key, duped_id)) |replaced| {
            self.allocator.free(replaced.key);
            self.allocator.free(replaced.value);
        }
        return true;
    }

    pub fn lookupTeamId(self: *const Config, key: []const u8) ?[]const u8 {
        return self.team_cache.get(key);
    }
};

pub fn load(allocator: Allocator, io: std.Io, environ: std.process.Environ, override_path: ?[]const u8) !Config {
    var cfg = Config{ .allocator = allocator, .io = io, .environ = environ };
    cfg.team_cache = std.StringHashMap([]const u8).init(allocator);
    errdefer cfg.team_cache.deinit();

    const path = try resolvePath(allocator, environ, override_path);
    cfg.config_path = path;
    cfg.owned_config_path = true;
    errdefer if (cfg.config_path) |p| allocator.free(p);

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try cfg.applyEnvOverrides();
            return cfg;
        },
        else => return err,
    };
    defer file.close(io);

    const stat = file.stat(io) catch null;
    if (stat) |info| {
        const masked = info.permissions.toMode() & 0o777;
        if (masked != 0 and masked != 0o600) {
            cfg.permissions_warning = true;
        }
    }

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const data = try file_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfig;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "api_key")) {
            if (value != .string) return error.InvalidConfig;
            try cfg.setApiKey(value.string);
        } else if (std.mem.eql(u8, key, "credential_helper")) {
            try cfg.setCredentialHelperValue(value);
        } else if (std.mem.eql(u8, key, "default_team_id")) {
            if (value != .string) return error.InvalidConfig;
            try cfg.setDefaultTeamId(value.string);
        } else if (std.mem.eql(u8, key, "default_output")) {
            if (value != .string) return error.InvalidConfig;
            try cfg.setDefaultOutput(value.string);
        } else if (std.mem.eql(u8, key, "default_state_filter")) {
            try cfg.setStateFilter(value);
        } else if (std.mem.eql(u8, key, "team_cache")) {
            if (value != .object) return error.InvalidConfig;
            var cache_it = value.object.iterator();
            while (cache_it.next()) |cache_entry| {
                if (cache_entry.value_ptr.* != .string) return error.InvalidConfig;
                _ = try cfg.cacheTeamId(cache_entry.key_ptr.*, cache_entry.value_ptr.*.string);
            }
        }
    }

    try cfg.applyEnvOverrides();
    return cfg;
}

fn resolvePath(allocator: Allocator, environ: std.process.Environ, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return allocator.dupe(u8, path);

    if (environ.getAlloc(allocator, linear_config_env)) |value| {
        return value;
    } else |err| switch (err) {
        error.EnvironmentVariableMissing => {},
        else => return err,
    }

    const home = environ.getAlloc(allocator, "HOME") catch {
        return error.MissingHome;
    };
    defer allocator.free(home);

    return std.fs.path.join(allocator, &.{ home, ".config", "linear", "config.json" });
}

/// Checks argv against the bounds above without storing it.
///
/// `setCredentialHelper` runs this itself; it is public so a caller that wants
/// to reject a bad helper *before* spawning it can use the same rules rather
/// than growing a second set that drifts.
pub fn validateCredentialHelper(argv: []const []const u8) CredentialHelperError!void {
    if (argv.len == 0) return CredentialHelperError.EmptyCredentialHelper;
    if (argv.len > max_credential_helper_args) return CredentialHelperError.TooManyCredentialHelperArgs;
    for (argv) |entry| {
        if (entry.len == 0) return CredentialHelperError.InvalidCredentialHelperArg;
        if (entry.len > max_credential_helper_arg_len) return CredentialHelperError.InvalidCredentialHelperArg;
    }
}

/// Splits a bare `credential_helper` string into argv on ASCII whitespace.
///
/// This is not a shell: quotes, backslashes, `$`, `|`, and `;` are all
/// ordinary characters that end up inside an argv element verbatim. Callers
/// that need an argument containing a space must use the array form.
///
/// The returned slice is owned by the caller; the elements borrow `command`.
pub fn splitCredentialHelper(allocator: Allocator, command: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |entry| {
        try list.append(allocator, entry);
    }

    // `errdefer` above owns the cleanup on this path.
    if (list.items.len == 0) return CredentialHelperError.EmptyCredentialHelper;
    return list.toOwnedSlice(allocator);
}

/// Overwrites every byte of `path` with zeros and flushes them to the device.
/// A missing file is not an error: there is then nothing to scrub.
pub fn scrubFile(io: std.Io, path: []const u8) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);

    const size = try file.length(io);
    if (size == 0) return;

    const filler: [512]u8 = @splat(0);
    var offset: u64 = 0;
    while (offset < size) {
        const chunk: usize = @intCast(@min(@as(u64, filler.len), size - offset));
        try file.writePositionalAll(io, filler[0..chunk], offset);
        offset += chunk;
    }
    try file.sync(io);
}

fn replaceRequiredString(allocator: Allocator, target: *[]const u8, owned: *bool, value: []const u8) !void {
    if (owned.*) allocator.free(target.*);
    target.* = try allocator.dupe(u8, value);
    owned.* = true;
}

fn resolveSavePath(self: *const Config, allocator: Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return allocator.dupe(u8, path);
    if (self.config_path) |path| return allocator.dupe(u8, path);
    return resolvePath(allocator, self.environ, null);
}
