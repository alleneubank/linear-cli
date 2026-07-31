const std = @import("std");
const posix = std.posix;
const test_io = std.testing.io;
const config = @import("config");
const graphql = @import("graphql");
const common = @import("common");
const auth_cmd = @import("auth");
const teams_cmd = @import("teams_cmd");
const issues_cmd = @import("issues_cmd");
const issue_view_cmd = @import("issue_view_cmd");
const issue_create_cmd = @import("issue_create_cmd");
const issue_delete_cmd = @import("issue_delete_cmd");
const me_cmd = @import("me_cmd");
const gql_cmd = @import("gql_cmd");

const Allocator = std.mem.Allocator;
const default_timeout_ms: u32 = 10_000;

const Env = struct {
    enabled: bool,
    api_key: ?[]u8 = null,
    team_id: ?[]u8 = null,
    issue_id: ?[]u8 = null,
    project_id: ?[]u8 = null,
    milestone_id: ?[]u8 = null,
    allow_mutations: bool = false,

    pub fn deinit(self: *Env, allocator: Allocator) void {
        if (self.api_key) |value| allocator.free(value);
        if (self.team_id) |value| allocator.free(value);
        if (self.issue_id) |value| allocator.free(value);
        if (self.project_id) |value| allocator.free(value);
        if (self.milestone_id) |value| allocator.free(value);
    }
};

fn loadEnv(allocator: Allocator) Env {
    const gate = std.testing.environ.getAlloc(allocator, "LINEAR_ONLINE_TESTS") catch null;
    if (gate) |value| allocator.free(value);
    if (gate == null) return .{ .enabled = false };

    const api_key = std.testing.environ.getAlloc(allocator, "LINEAR_API_KEY") catch null;
    if (api_key == null) return .{ .enabled = false };

    const allow_env = std.testing.environ.getAlloc(allocator, "LINEAR_TEST_ALLOW_MUTATIONS") catch null;
    const allow_mutations = allow_env != null;
    if (allow_env) |value| allocator.free(value);

    var env = Env{
        .enabled = true,
        .api_key = api_key,
        .allow_mutations = allow_mutations,
    };
    env.team_id = std.testing.environ.getAlloc(allocator, "LINEAR_TEST_TEAM_ID") catch null;
    env.issue_id = std.testing.environ.getAlloc(allocator, "LINEAR_TEST_ISSUE_ID") catch null;
    env.project_id = std.testing.environ.getAlloc(allocator, "LINEAR_TEST_PROJECT_ID") catch null;
    env.milestone_id = std.testing.environ.getAlloc(allocator, "LINEAR_TEST_MILESTONE_ID") catch null;
    ensureTeamId(&env, allocator);
    return env;
}

fn makeConfig(allocator: Allocator, env: *const Env) !config.Config {
    var cfg = config.Config{ .allocator = allocator, .io = test_io, .environ = std.testing.environ };
    try cfg.setApiKey(env.api_key.?);
    if (env.team_id) |team| try cfg.setDefaultTeamId(team);
    return cfg;
}

const Capture = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: Capture, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn readAll(allocator: Allocator, fd: posix.fd_t) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);

    var tmp: [256]u8 = undefined;
    while (true) {
        const count = try posix.read(fd, &tmp);
        if (count == 0) break;
        try buffer.appendSlice(allocator, tmp[0..count]);
    }

    return buffer.toOwnedSlice(allocator);
}

fn ensureTeamId(env: *Env, allocator: Allocator) void {
    if (!env.enabled or env.team_id != null or env.api_key == null) return;
    env.team_id = fetchDefaultTeamId(allocator, env.api_key.?) catch null;
}

fn fetchDefaultTeamId(allocator: Allocator, api_key: []const u8) !?[]u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(test_io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var client = graphql.GraphqlClient.init(allocator, test_io, api_key);
    defer graphql.deinitSharedClient(test_io);
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    const query =
        \\query DefaultTeam($first: Int!) {
        \\  teams(first: $first) { nodes { id } }
        \\}
    ;

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "first", .{ .integer = 1 });

    var response = common.send(allocator, "online setup", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "DefaultTeam",
    }, stderr) catch {
        return null;
    };
    defer response.deinit();

    common.checkResponse(test_io, "online setup", &response, stderr, api_key) catch {
        return null;
    };

    const data_value = response.data() orelse return null;
    const teams_obj = common.getObjectField(data_value, "teams") orelse return null;
    const nodes = common.getArrayField(teams_obj, "nodes") orelse return null;
    if (nodes.items.len == 0) return null;
    const node = nodes.items[0];
    if (node != .object) return null;
    const id_value = common.getStringField(node, "id") orelse return null;
    const duped = try allocator.dupe(u8, id_value);
    return duped;
}

/// `std.posix` no longer wraps `pipe`/`dup`/`dup2`/`close`, so the redirection
/// harness calls libc directly and maps failures onto an explicit error.
const RedirectError = error{RedirectFailed};

fn openPipe() RedirectError![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.RedirectFailed;
    return fds;
}

fn dupFd(fd: posix.fd_t) RedirectError!posix.fd_t {
    const duped = std.c.dup(fd);
    if (duped < 0) return error.RedirectFailed;
    return duped;
}

fn dupFdTo(old_fd: posix.fd_t, new_fd: posix.fd_t) RedirectError!void {
    if (std.c.dup2(old_fd, new_fd) < 0) return error.RedirectFailed;
}

fn closeFd(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}

fn captureOutput(allocator: Allocator, context: anytype, run_fn: anytype) !Capture {
    var stdout_pipe = try openPipe();
    defer if (stdout_pipe[0] != -1) closeFd(stdout_pipe[0]);
    defer if (stdout_pipe[1] != -1) closeFd(stdout_pipe[1]);

    var stderr_pipe = try openPipe();
    defer if (stderr_pipe[0] != -1) closeFd(stderr_pipe[0]);
    defer if (stderr_pipe[1] != -1) closeFd(stderr_pipe[1]);

    const saved_stdout = try dupFd(posix.STDOUT_FILENO);
    const saved_stderr = try dupFd(posix.STDERR_FILENO);
    defer closeFd(saved_stdout);
    defer closeFd(saved_stderr);

    try dupFdTo(stdout_pipe[1], posix.STDOUT_FILENO);
    try dupFdTo(stderr_pipe[1], posix.STDERR_FILENO);

    const exit_code = try run_fn(context);

    dupFdTo(saved_stdout, posix.STDOUT_FILENO) catch {};
    dupFdTo(saved_stderr, posix.STDERR_FILENO) catch {};

    closeFd(stdout_pipe[1]);
    stdout_pipe[1] = -1;
    closeFd(stderr_pipe[1]);
    stderr_pipe[1] = -1;

    const stdout_data = try readAll(allocator, stdout_pipe[0]);
    errdefer allocator.free(stdout_data);
    const stderr_data = try readAll(allocator, stderr_pipe[0]);
    errdefer allocator.free(stderr_data);

    return .{ .stdout = stdout_data, .stderr = stderr_data, .exit_code = exit_code };
}

test "online auth test and me" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    const AuthRunner = struct {
        allocator: Allocator,
        cfg: *config.Config,
    };
    const runAuth = struct {
        pub fn call(r: *const AuthRunner) !u8 {
            var args = [_][]const u8{"test"};
            return auth_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = true,
                .config_path = null,
                .retries = 0,
                .timeout_ms = default_timeout_ms,
            });
        }
    }.call;
    const auth_runner = AuthRunner{ .allocator = allocator, .cfg = &cfg };
    const auth_capture = try captureOutput(allocator, &auth_runner, runAuth);
    defer auth_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), auth_capture.exit_code);

    var auth_parsed = try std.json.parseFromSlice(std.json.Value, allocator, auth_capture.stdout, .{});
    defer auth_parsed.deinit();
    const auth_root = auth_parsed.value;
    if (auth_root != .object) return error.TestExpectedResult;
    const auth_viewer = auth_root.object.get("viewer") orelse return error.TestExpectedResult;
    if (auth_viewer != .object) return error.TestExpectedResult;
    const auth_id_value = auth_viewer.object.get("id") orelse return error.TestExpectedResult;
    if (auth_id_value != .string or auth_id_value.string.len == 0) return error.TestExpectedResult;

    const MeRunner = struct {
        allocator: Allocator,
        cfg: *config.Config,
    };
    const runMe = struct {
        pub fn call(r: *const MeRunner) !u8 {
            var args = [_][]const u8{};
            return me_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const me_runner = MeRunner{ .allocator = allocator, .cfg = &cfg };
    const me_capture = try captureOutput(allocator, &me_runner, runMe);
    defer me_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), me_capture.exit_code);

    var me_parsed = try std.json.parseFromSlice(std.json.Value, allocator, me_capture.stdout, .{});
    defer me_parsed.deinit();
    const me_root = me_parsed.value;
    if (me_root != .object) return error.TestExpectedResult;
    const me_viewer = me_root.object.get("viewer") orelse return error.TestExpectedResult;
    if (me_viewer != .object) return error.TestExpectedResult;
    const me_id_value = me_viewer.object.get("id") orelse return error.TestExpectedResult;
    if (me_id_value != .string or me_id_value.string.len == 0) return error.TestExpectedResult;

    try std.testing.expectEqualStrings(auth_id_value.string, me_id_value.string);
}

test "online teams list returns configured team when available" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    const Runner = struct {
        allocator: Allocator,
        cfg: *config.Config,
    };
    const runTeams = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{};
            return teams_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };
    const capture = try captureOutput(allocator, &runner, runTeams);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const teams_value = root.object.get("teams") orelse return error.TestExpectedResult;
    if (teams_value != .object) return error.TestExpectedResult;
    const nodes = teams_value.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try std.testing.expect(nodes.array.items.len > 0);
    if (env.team_id) |team| {
        var found = false;
        for (nodes.array.items) |entry| {
            if (entry != .object) continue;
            if (entry.object.get("id")) |id_val| {
                if (id_val == .string and std.mem.eql(u8, id_val.string, team)) {
                    found = true;
                    break;
                }
            }
        }
        try std.testing.expect(found);
    }
}

test "online issues list succeeds without sub-issues" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    const Runner = struct {
        allocator: Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "1", "--sub-limit", "0" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };
    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const issues_value = root.object.get("issues") orelse return error.TestExpectedResult;
    if (issues_value != .object) return error.TestExpectedResult;
    const nodes = issues_value.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    const page_info = issues_value.object.get("pageInfo") orelse return error.TestExpectedResult;
    if (page_info != .object) return error.TestExpectedResult;
}

test "online issues list filters by state-type with alias" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    // Test that in_progress alias maps to started and doesn't error
    const Runner = struct {
        allocator: Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "1", "--sub-limit", "0", "--state-type", "in_progress,started" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };
    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const issues_value = root.object.get("issues") orelse return error.TestExpectedResult;
    if (issues_value != .object) return error.TestExpectedResult;
    // If we got here without error, the state-type filter worked (in_progress was mapped to started)
}

test "online issues list includes relation fields when enabled" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    const Runner = struct {
        allocator: Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--limit",
                "1",
                "--sub-limit",
                "1",
                "--fields",
                "identifier,title,parent,sub_issues,project,milestone",
                "--include-projects",
            };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };
    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const issues_value = root.object.get("issues") orelse return error.TestExpectedResult;
    if (issues_value != .object) return error.TestExpectedResult;
    const nodes = issues_value.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    if (nodes.array.items.len > 0) {
        const first = nodes.array.items[0];
        if (first != .object) return error.TestExpectedResult;
        const child_value = first.object.get("children") orelse first.object.get("subIssues") orelse return error.TestExpectedResult;
        if (child_value != .object) return error.TestExpectedResult;
        try std.testing.expect(first.object.get("project") != null);
        try std.testing.expect(first.object.get("milestone") != null);
    }
}

test "online issue view returns selected fields when identifier provided" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;
    const identifier = env.issue_id orelse return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    const Runner = struct {
        allocator: Allocator,
        cfg: *config.Config,
        id: []const u8,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                r.id,
                "--fields",
                "identifier,title,parent,sub_issues,project,milestone",
                "--data-only",
                "--sub-limit",
                "1",
            };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg, .id = identifier };
    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const id_field = root.object.get("identifier") orelse return error.TestExpectedResult;
    if (id_field != .string or id_field.string.len == 0) return error.TestExpectedResult;
}

test "online introspection includes issue relations" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled) return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const query_contents =
        \\query IssueSchema {
        \\  issue: __type(name: "Issue") {
        \\    fields { name }
        \\  }
        \\}
    ;
    const query_file = try tmp.dir.createFile(test_io, "schema.graphql", .{ .read = true, .truncate = true });
    defer query_file.close(test_io);
    try query_file.writeStreamingAll(test_io, query_contents);
    const query_path = try tmp.dir.realPathFileAlloc(test_io, "schema.graphql", allocator);
    defer allocator.free(query_path);

    const Runner = struct {
        allocator: Allocator,
        cfg: *config.Config,
        query: []const u8,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--query",
                r.query,
                "--operation-name",
                "IssueSchema",
                "--fields",
                "issue",
            };
            return gql_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = true,
                .retries = 0,
                .timeout_ms = default_timeout_ms,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg, .query = query_path };
    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const issue_obj = root.object.get("issue") orelse return error.TestExpectedResult;
    if (issue_obj != .object) return error.TestExpectedResult;
    const fields_value = issue_obj.object.get("fields") orelse return error.TestExpectedResult;
    if (fields_value != .array) return error.TestExpectedResult;

    var has_children = false;
    var has_project = false;
    var has_project_milestone = false;
    for (fields_value.array.items) |entry| {
        if (entry != .object) continue;
        const name_value = entry.object.get("name") orelse continue;
        if (name_value != .string) continue;
        if (std.mem.eql(u8, name_value.string, "children") or std.mem.eql(u8, name_value.string, "subIssues")) has_children = true;
        if (std.mem.eql(u8, name_value.string, "project")) has_project = true;
        if (std.mem.eql(u8, name_value.string, "projectMilestone") or std.mem.eql(u8, name_value.string, "milestone")) {
            has_project_milestone = true;
        }
    }

    try std.testing.expect(has_children);
    try std.testing.expect(has_project);
    try std.testing.expect(has_project_milestone);
}

test "online issue create and delete (opt-in)" {
    const allocator = std.testing.allocator;
    var env = loadEnv(allocator);
    defer env.deinit(allocator);
    if (!env.enabled or !env.allow_mutations) return;
    const team_id = env.team_id orelse return;

    var cfg = try makeConfig(allocator, &env);
    defer cfg.deinit();
    defer graphql.deinitSharedClient(test_io);

    const timestamp = std.Io.Clock.real.now(test_io).toSeconds();
    var title_buffer: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buffer, "CLI online test {d}", .{timestamp});

    const CreateRunner = struct {
        allocator: Allocator,
        cfg: *config.Config,
        team: []const u8,
        title: []const u8,
    };
    const runCreate = struct {
        pub fn call(r: *const CreateRunner) !u8 {
            var args = [_][]const u8{ "--team", r.team, "--title", r.title, "--yes", "--data-only" };
            return issue_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = true,
            });
        }
    }.call;
    const create_runner = CreateRunner{ .allocator = allocator, .cfg = &cfg, .team = team_id, .title = title };
    const create_capture = try captureOutput(allocator, &create_runner, runCreate);
    defer create_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), create_capture.exit_code);

    var create_parsed = try std.json.parseFromSlice(std.json.Value, allocator, create_capture.stdout, .{});
    defer create_parsed.deinit();
    const create_root = create_parsed.value;
    if (create_root != .object) return error.TestExpectedResult;
    const identifier_field = create_root.object.get("identifier") orelse return error.TestExpectedResult;
    if (identifier_field != .string or identifier_field.string.len == 0) return error.TestExpectedResult;
    const identifier = identifier_field.string;

    const DeleteRunner = struct {
        allocator: Allocator,
        cfg: *config.Config,
        id: []const u8,
    };
    const runDelete = struct {
        pub fn call(r: *const DeleteRunner) !u8 {
            var args = [_][]const u8{ r.id, "--yes" };
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = default_timeout_ms,
                .json_output = false,
            });
        }
    }.call;
    const delete_runner = DeleteRunner{ .allocator = allocator, .cfg = &cfg, .id = identifier };
    const delete_capture = try captureOutput(allocator, &delete_runner, runDelete);
    defer delete_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), delete_capture.exit_code);
}
