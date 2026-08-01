const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const Allocator = std.mem.Allocator;

pub const CommandError = error{CommandFailed};

/// Upper bound for `--*-file` content flags. Linear rejects far larger bodies
/// anyway, so this exists to turn a runaway file or an unterminated stdin pipe
/// into a clear diagnostic instead of an unbounded allocation.
pub const max_content_bytes: usize = 1024 * 1024;

/// Value every `--*-file` flag accepts to mean "read stdin instead of a path".
pub const stdin_marker = "-";

pub const ResolvedContent = struct {
    value: ?[]const u8 = null,
    owned: bool = false,

    pub fn deinit(self: ResolvedContent, allocator: Allocator) void {
        if (!self.owned) return;
        if (self.value) |value| allocator.free(value);
    }
};

/// Collapses a `--<flag>` / `--<flag>-file` pair into a single value.
///
/// Supplying both is an error rather than a silent precedence rule, so a
/// mistyped invocation can never quietly send the wrong content. Returns a
/// null value when neither flag was given; callers decide whether that is
/// allowed.
pub fn resolveContent(
    allocator: Allocator,
    io: std.Io,
    text: ?[]const u8,
    path: ?[]const u8,
    stderr: anytype,
    prefix: []const u8,
    flag: []const u8,
) !ResolvedContent {
    if (text != null and path != null) {
        try stderr.print("{s}: cannot use both {s} and {s}-file\n", .{ prefix, flag, flag });
        return CommandError.CommandFailed;
    }
    if (text) |value| return .{ .value = value };
    const file_path = path orelse return .{};
    return .{ .value = try readContentFile(allocator, io, file_path, stderr, prefix), .owned = true };
}

/// Reads long-form content for a `--*-file` flag; `stdin_marker` reads stdin.
/// Caller owns the returned bytes.
pub fn readContentFile(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    stderr: anytype,
    prefix: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, path, stdin_marker)) return readContentStdin(allocator, io, stderr, prefix);

    // The limit is exclusive, so read one byte past the cap: a file of exactly
    // `max_content_bytes` is accepted and anything larger trips StreamTooLong.
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_content_bytes + 1)) catch |err| {
        switch (err) {
            error.StreamTooLong => try stderr.print(
                "{s}: file '{s}' exceeds the {d} byte limit\n",
                .{ prefix, path, max_content_bytes },
            ),
            else => try stderr.print("{s}: cannot read file '{s}': {s}\n", .{ prefix, path, @errorName(err) }),
        }
        return CommandError.CommandFailed;
    };
}

fn readContentStdin(allocator: Allocator, io: std.Io, stderr: anytype, prefix: []const u8) ![]u8 {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    return stdin_reader.interface.allocRemaining(allocator, .limited(max_content_bytes + 1)) catch |err| {
        switch (err) {
            error.StreamTooLong => try stderr.print(
                "{s}: stdin exceeds the {d} byte limit\n",
                .{ prefix, max_content_bytes },
            ),
            else => try stderr.print("{s}: cannot read from stdin: {s}\n", .{ prefix, @errorName(err) }),
        }
        return CommandError.CommandFailed;
    };
}

pub fn requireApiKey(cfg: *config.Config, override_key: ?[]const u8, stderr: anytype, prefix: []const u8) ![]const u8 {
    const key = cfg.resolveApiKey(override_key) catch {
        try stderr.print("{s}: missing API key; set LINEAR_API_KEY or run 'linear auth set'\n", .{prefix});
        return CommandError.CommandFailed;
    };
    return key;
}

pub fn checkResponse(
    io: std.Io,
    prefix: []const u8,
    resp: *const graphql.GraphqlClient.Response,
    stderr: anytype,
    api_key: ?[]const u8,
) !void {
    if (!resp.isSuccessStatus()) {
        try stderr.print("{s}: HTTP status {d}\n", .{ prefix, resp.status });
        if (resp.firstErrorMessage()) |msg| {
            try stderr.print("{s}: {s}\n", .{ prefix, msg });
        }
        if (resp.status == 401) {
            if (api_key) |key| {
                var buf: [64]u8 = undefined;
                const redacted = redactKey(key, &buf);
                try stderr.print(
                    "{s}: unauthorized (key {s}); verify LINEAR_API_KEY or run 'linear auth set'\n",
                    .{ prefix, redacted },
                );
            } else {
                try stderr.print("{s}: unauthorized; verify LINEAR_API_KEY or run 'linear auth set'\n", .{prefix});
            }
        }
        try printRateLimit(io, prefix, resp.rate_limit, stderr);
        return CommandError.CommandFailed;
    }

    if (resp.hasGraphqlErrors()) {
        if (resp.firstErrorMessage()) |msg| {
            try stderr.print("{s}: {s}\n", .{ prefix, msg });
        } else {
            try stderr.print("{s}: GraphQL errors present\n", .{prefix});
        }
        try printRateLimit(io, prefix, resp.rate_limit, stderr);
        return CommandError.CommandFailed;
    }
}

pub fn getStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get(key)) |found| {
        if (found == .string) return found.string;
    }
    return null;
}

pub fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    if (value.object.get(key)) |found| {
        if (found == .object) return found;
    }
    return null;
}

pub fn getArrayField(value: std.json.Value, key: []const u8) ?std.json.Array {
    if (value != .object) return null;
    if (value.object.get(key)) |found| {
        if (found == .array) return found.array;
    }
    return null;
}

pub fn getBoolField(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    if (value.object.get(key)) |found| {
        if (found == .bool) return found.bool;
    }
    return null;
}

pub fn send(
    allocator: Allocator,
    prefix: []const u8,
    client: *graphql.GraphqlClient,
    req: graphql.GraphqlClient.Request,
    stderr: anytype,
) !graphql.GraphqlClient.Response {
    return client.send(allocator, req) catch |err| {
        if (err == graphql.GraphqlClient.Error.RequestTimedOut) {
            try stderr.print("{s}: request timed out after {d}ms\n", .{ prefix, client.timeout_ms });
            return CommandError.CommandFailed;
        }
        try stderr.print("{s}: request failed: {s}\n", .{ prefix, @errorName(err) });
        return CommandError.CommandFailed;
    };
}

fn printRateLimit(io: std.Io, prefix: []const u8, info: graphql.GraphqlClient.RateLimitInfo, stderr: anytype) !void {
    if (!info.hasData()) return;
    try stderr.print("{s}: rate limit:", .{prefix});

    var emitted = false;
    if (info.remaining) |remaining| {
        try stderr.print(" remaining {d}", .{remaining});
        if (info.limit) |limit| {
            try stderr.print("/{d}", .{limit});
        }
        emitted = true;
    } else if (info.limit) |limit| {
        try stderr.print(" limit {d}", .{limit});
        emitted = true;
    }

    if (info.retry_after_ms) |retry_ms| {
        try stderr.print("{s} retry after ~{d}ms", .{ if (emitted) ";" else "", retry_ms });
        emitted = true;
    }

    if (info.reset_epoch_ms) |reset_ms| {
        const now_ms_i64: i64 = std.Io.Clock.real.now(io).toMilliseconds();
        const now_ms: u64 = if (now_ms_i64 > 0) @intCast(now_ms_i64) else 0;
        if (reset_ms > now_ms) {
            try stderr.print("{s} reset in ~{d}ms", .{ if (emitted) ";" else "", reset_ms - now_ms });
        } else {
            try stderr.print("{s} reset at {d}", .{ if (emitted) ";" else "", reset_ms });
        }
        emitted = true;
    }

    if (!emitted) return;
    try stderr.print("\n", .{});
}

/// Result of a cursor walk, as every paginating list command reports it.
///
/// The walk itself stays per-entity — each command has its own connection
/// field, node projection and output modes — but the closing report is pure
/// formatting with no entity in it, so it lives here instead of being retyped
/// six times and drifting.
pub const PageProgress = struct {
    /// Items actually emitted, which is not the number fetched when
    /// `--max-items` truncated the final page.
    items: usize = 0,
    pages: usize = 0,
    more_available: bool = false,
    end_cursor: ?[]const u8 = null,
    max_items_reached: bool = false,
};

/// Prints the fetched-count summary and, when the walk stopped early, the
/// `--max-items` notice.
///
/// The summary is suppressed under `--json` so it never has to be filtered out
/// of a machine-readable run; the `--max-items` notice is not, because it
/// reports a deliberately truncated result set.
pub fn printPageSummary(
    stderr: anytype,
    prefix: []const u8,
    progress: PageProgress,
    json_output: bool,
) !void {
    if (!json_output) {
        const plural: []const u8 = if (progress.pages == 1) "" else "s";
        if (progress.more_available) {
            const cursor_value = progress.end_cursor orelse "(unknown)";
            try stderr.print(
                "{s}: fetched {d} items across {d} page{s}; more available, resume with --cursor {s}\n",
                .{ prefix, progress.items, progress.pages, plural, cursor_value },
            );
        } else {
            try stderr.print(
                "{s}: fetched {d} items across {d} page{s}\n",
                .{ prefix, progress.items, progress.pages, plural },
            );
        }
    }
    if (progress.max_items_reached) {
        try stderr.print("{s}: stopped after {d} items due to --max-items\n", .{ prefix, progress.items });
    }
}

pub const ResolvedId = struct {
    value: []const u8,
    owned: bool = false,
};

pub fn resolveViewerId(
    allocator: Allocator,
    client: *graphql.GraphqlClient,
    stderr: anytype,
    prefix: []const u8,
) ![]const u8 {
    const query = "query Viewer { viewer { id } }";

    var response = send(allocator, prefix, client, .{
        .query = query,
        .variables = null,
        .operation_name = "Viewer",
    }, stderr) catch {
        return CommandError.CommandFailed;
    };
    defer response.deinit();

    checkResponse(client.io, prefix, &response, stderr, client.api_key) catch {
        return CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const viewer_obj = getObjectField(data_value, "viewer") orelse {
        try stderr.print("{s}: viewer not found in response\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const id_value = getStringField(viewer_obj, "id") orelse {
        try stderr.print("{s}: viewer id missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };

    const duped = allocator.dupe(u8, id_value) catch {
        try stderr.print("{s}: failed to allocate viewer id\n", .{prefix});
        return CommandError.CommandFailed;
    };
    return duped;
}

pub fn resolveIssueId(
    allocator: Allocator,
    client: *graphql.GraphqlClient,
    identifier: []const u8,
    stderr: anytype,
    prefix: []const u8,
) !ResolvedId {
    const trimmed = std.mem.trim(u8, identifier, " \t");
    if (trimmed.len == 0) {
        try stderr.print("{s}: missing issue identifier\n", .{prefix});
        return CommandError.CommandFailed;
    }
    if (looksLikeIssueId(trimmed)) return .{ .value = trimmed };

    const dash_index = std.mem.lastIndexOfScalar(u8, trimmed, '-') orelse {
        try stderr.print("{s}: invalid issue identifier; expected TEAM-NUMBER\n", .{prefix});
        return CommandError.CommandFailed;
    };
    if (dash_index + 1 >= trimmed.len) {
        try stderr.print("{s}: invalid issue identifier; expected TEAM-NUMBER\n", .{prefix});
        return CommandError.CommandFailed;
    }

    const team_key = trimmed[0..dash_index];
    const number_raw = trimmed[dash_index + 1 ..];
    const number_value = std.fmt.parseInt(u64, number_raw, 10) catch {
        try stderr.print("{s}: invalid issue identifier; expected TEAM-NUMBER\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const number_i64: i64 = std.math.cast(i64, number_value) orelse {
        try stderr.print("{s}: issue number out of range\n", .{prefix});
        return CommandError.CommandFailed;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var filter: std.json.Value = .{ .object = std.json.ObjectMap.empty };

    var team_obj: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    var key_cmp: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    try key_cmp.object.put(var_alloc, "eq", .{ .string = team_key });
    try team_obj.object.put(var_alloc, "key", key_cmp);
    try filter.object.put(var_alloc, "team", team_obj);

    var number_cmp: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    try number_cmp.object.put(var_alloc, "eq", .{ .integer = number_i64 });
    try filter.object.put(var_alloc, "number", number_cmp);

    var variables: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "filter", filter);
    try variables.object.put(var_alloc, "first", .{ .integer = 1 });

    const query =
        \\query IssueLookup($filter: IssueFilter!, $first: Int!) {
        \\  issues(filter: $filter, first: $first) {
        \\    nodes { id }
        \\  }
        \\}
    ;

    var response = send(allocator, prefix, client, .{
        .query = query,
        .variables = variables,
        .operation_name = "IssueLookup",
    }, stderr) catch {
        return CommandError.CommandFailed;
    };
    defer response.deinit();

    checkResponse(client.io, prefix, &response, stderr, client.api_key) catch {
        return CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const issues_obj = getObjectField(data_value, "issues") orelse {
        try stderr.print("{s}: issues not found in response\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const nodes_array = getArrayField(issues_obj, "nodes") orelse {
        try stderr.print("{s}: nodes missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };
    if (nodes_array.items.len == 0) {
        try stderr.print("{s}: issue '{s}' not found\n", .{ prefix, trimmed });
        return CommandError.CommandFailed;
    }
    const node = nodes_array.items[0];
    if (node != .object) {
        try stderr.print("{s}: invalid issue payload\n", .{prefix});
        return CommandError.CommandFailed;
    }
    const id_value = getStringField(node, "id") orelse {
        try stderr.print("{s}: issue id missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };

    const duped = allocator.dupe(u8, id_value) catch {
        try stderr.print("{s}: failed to allocate issue id\n", .{prefix});
        return CommandError.CommandFailed;
    };
    return .{ .value = duped, .owned = true };
}

pub fn resolveProjectId(
    allocator: Allocator,
    client: *graphql.GraphqlClient,
    identifier: []const u8,
    stderr: anytype,
    prefix: []const u8,
) !ResolvedId {
    if (looksLikeProjectId(identifier)) {
        return .{ .value = identifier };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var filter: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    var slug_obj: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    try slug_obj.object.put(var_alloc, "eq", .{ .string = identifier });
    try filter.object.put(var_alloc, "slugId", slug_obj);

    var variables: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "filter", filter);
    try variables.object.put(var_alloc, "first", .{ .integer = 1 });

    const query =
        \\query ProjectLookup($filter: ProjectFilter!, $first: Int!) {
        \\  projects(filter: $filter, first: $first) {
        \\    nodes { id }
        \\  }
        \\}
    ;

    var response = send(allocator, prefix, client, .{
        .query = query,
        .variables = variables,
        .operation_name = "ProjectLookup",
    }, stderr) catch {
        return CommandError.CommandFailed;
    };
    defer response.deinit();

    checkResponse(client.io, prefix, &response, stderr, client.api_key) catch {
        return CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const projects_obj = getObjectField(data_value, "projects") orelse {
        try stderr.print("{s}: projects missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const nodes_array = getArrayField(projects_obj, "nodes") orelse {
        try stderr.print("{s}: nodes missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };
    if (nodes_array.items.len == 0) {
        try stderr.print("{s}: project not found\n", .{prefix});
        return CommandError.CommandFailed;
    }
    const node = nodes_array.items[0];
    if (node != .object) {
        try stderr.print("{s}: invalid project payload\n", .{prefix});
        return CommandError.CommandFailed;
    }
    const id_value = getStringField(node, "id") orelse {
        try stderr.print("{s}: project id missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };

    const duped = allocator.dupe(u8, id_value) catch {
        try stderr.print("{s}: failed to allocate project id\n", .{prefix});
        return CommandError.CommandFailed;
    };
    return .{ .value = duped, .owned = true };
}

pub fn resolveProjectStatusId(
    allocator: Allocator,
    client: *graphql.GraphqlClient,
    state: []const u8,
    stderr: anytype,
    prefix: []const u8,
) ![]const u8 {
    const query =
        \\query ProjectStatuses {
        \\  projectStatuses { nodes { id type } }
        \\}
    ;

    var response = send(allocator, prefix, client, .{
        .query = query,
        .variables = null,
        .operation_name = "ProjectStatuses",
    }, stderr) catch {
        return CommandError.CommandFailed;
    };
    defer response.deinit();

    checkResponse(client.io, prefix, &response, stderr, client.api_key) catch {
        return CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const statuses_obj = getObjectField(data_value, "projectStatuses") orelse {
        try stderr.print("{s}: projectStatuses missing in response\n", .{prefix});
        return CommandError.CommandFailed;
    };
    const nodes = getArrayField(statuses_obj, "nodes") orelse {
        try stderr.print("{s}: projectStatuses nodes missing\n", .{prefix});
        return CommandError.CommandFailed;
    };

    for (nodes.items) |node| {
        if (node != .object) continue;
        const type_value = getStringField(node, "type") orelse continue;
        if (!std.ascii.eqlIgnoreCase(type_value, state)) continue;
        const id_value = getStringField(node, "id") orelse continue;
        const duped = allocator.dupe(u8, id_value) catch {
            try stderr.print("{s}: failed to allocate status id\n", .{prefix});
            return CommandError.CommandFailed;
        };
        return duped;
    }

    try stderr.print("{s}: project status '{s}' not found\n", .{ prefix, state });
    return CommandError.CommandFailed;
}

pub fn isValidProjectState(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "backlog") or
        std.ascii.eqlIgnoreCase(value, "planned") or
        std.ascii.eqlIgnoreCase(value, "started") or
        std.ascii.eqlIgnoreCase(value, "paused") or
        std.ascii.eqlIgnoreCase(value, "completed") or
        std.ascii.eqlIgnoreCase(value, "canceled");
}

pub fn looksLikeWorkflowStateId(value: []const u8) bool {
    return isUuid(value) or isLikelyCuid(value);
}

fn looksLikeProjectId(value: []const u8) bool {
    return isUuid(value) or std.mem.startsWith(u8, value, "proj_");
}

fn looksLikeIssueId(value: []const u8) bool {
    return isUuid(value) or
        std.mem.startsWith(u8, value, "iss_") or
        std.mem.startsWith(u8, value, "issue-") or
        isLikelyCuid(value);
}

fn isLikelyCuid(value: []const u8) bool {
    if (value.len < 20 or value.len > 36) return false;
    if (!std.ascii.isAlphabetic(value[0])) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (value[idx] != '-') return false;
    }
    return true;
}

/// Below this length the first-4/last-4 hint would expose half or more of the
/// secret, so those keys are replaced wholesale.
pub const min_redactable_key_len = 16;

pub fn redactKey(key: []const u8, buffer: []u8) []const u8 {
    if (buffer.len == 0 or key.len < min_redactable_key_len) return "<redacted>";

    return std.fmt.bufPrint(buffer, "{s}...{s}", .{
        key[0..4],
        key[key.len - 4 ..],
    }) catch "<redacted>";
}

test "checkResponse reports auth errors and redacts key" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "errors": [ { "message": "bad request" } ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    var resp = graphql.GraphqlClient.Response{
        .status = 401,
        .parsed = parsed,
    };
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    const fake_key = "abcdefghijklmnop1234";
    try std.testing.expectError(
        CommandError.CommandFailed,
        checkResponse(std.testing.io, "issues", &resp, &buffer.writer, fake_key),
    );
    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP status 401") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "abcd...1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, fake_key) == null);
}

test "redactKey hides short inputs entirely" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("<redacted>", redactKey("k", &buf));
    try std.testing.expectEqualStrings("<redacted>", redactKey("abcd1234", &buf));
    try std.testing.expectEqualStrings("abcd...3456", redactKey("abcdefghij123456", &buf));
}
