const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("stdlib.h");
});
const env_name = "LINEAR_API_KEY";
const env_name_z = "LINEAR_API_KEY\x00";
const config_env_name = "LINEAR_CONFIG";
const config_env_name_z = "LINEAR_CONFIG\x00";
const test_io = std.testing.io;
const config = @import("config");
const config_cmd = @import("config_cmd");
const auth_cmd = @import("auth_test");
const common = @import("common");
const cli = @import("cli");
const gql = @import("gql");
const issues_cmd = @import("issues_test");
const search_cmd = @import("search_test");
const issue_create_cmd = @import("issue_create_test");
const issue_view_cmd = @import("issue_view_test");
const issue_delete_cmd = @import("issue_delete_test");
const issue_update_cmd = @import("issue_update_test");
const issue_link_cmd = @import("issue_link_test");
const issue_comment_cmd = @import("issue_comment_test");
const issue_comments_cmd = @import("issue_comments_test");
const download_cmd = @import("download_test");
const me_cmd = @import("me_test");
const teams_cmd = @import("teams_test");
const projects_cmd = @import("projects_test");
const labels_cmd = @import("labels_test");
const users_cmd = @import("users_test");
const states_cmd = @import("states_test");
const project_view_cmd = @import("project_view_test");
const project_create_cmd = @import("project_create_test");
const project_update_cmd = @import("project_update_test");
const project_delete_cmd = @import("project_delete_test");
const project_issues_cmd = @import("project_issues_test");
const issue_start_cmd = @import("issue_start_test");
const issue_pr_cmd = @import("issue_pr_test");
const issue_info_cmd = @import("issue_info_test");
const milestones_cmd = @import("milestones_test");
const bulk = @import("bulk");
const printer = @import("printer");
const graphql = @import("graphql");
const git = @import("git");
const process = @import("process");
const credentials = @import("credentials");
const mock_graphql = @import("graphql_mock");
const fixtures = struct {
    pub const issues_response = @embedFile("fixtures/issues.json");
    pub const issues_page2_response = @embedFile("fixtures/issues_page2.json");
    pub const issues_with_subs_response = @embedFile("fixtures/issues_with_subs.json");
    pub const issues_table = @embedFile("fixtures/issues_table.txt");
    pub const issues_json = @embedFile("fixtures/issues_json.txt");
    pub const issues_pagination_stderr = @embedFile("fixtures/issues_pagination_stderr.txt");
    pub const teams_response = @embedFile("fixtures/teams.json");
    pub const teams_table = @embedFile("fixtures/teams_table.txt");
    pub const viewer_response = @embedFile("fixtures/viewer.json");
    pub const viewer_table = @embedFile("fixtures/me_table.txt");
    pub const issue_create_team_lookup = @embedFile("fixtures/issue_create_team_lookup.json");
    pub const team_lookup_empty = @embedFile("fixtures/team_lookup_empty.json");
    pub const issue_create_response = @embedFile("fixtures/issue_create_response.json");
    pub const issue_delete_response = @embedFile("fixtures/issue_delete_response.json");
    pub const issue_delete_lookup = @embedFile("fixtures/issue_delete_lookup.json");
    pub const issue_view_response = @embedFile("fixtures/issue_view.json");
    pub const issue_view_project = @embedFile("fixtures/issue_view_project.json");
    pub const issue_view_relations = @embedFile("fixtures/issue_view_relations.json");
    pub const issue_view_comments = @embedFile("fixtures/issue_view_comments.json");
    pub const issue_update_response = @embedFile("fixtures/issue_update_response.json");
    pub const issue_state_lookup_response = @embedFile("fixtures/issue_state_lookup_response.json");
    pub const issue_lookup_response = @embedFile("fixtures/issue_lookup_response.json");
    pub const issue_link_response = @embedFile("fixtures/issue_link_response.json");
    pub const project_create_response = @embedFile("fixtures/project_create_response.json");
    pub const projects_response = @embedFile("fixtures/projects_response.json");
    pub const project_view_response = @embedFile("fixtures/project_view_response.json");
    pub const project_update_response = @embedFile("fixtures/project_update_response.json");
    pub const project_delete_response = @embedFile("fixtures/project_delete_response.json");
    pub const project_add_issue_response = @embedFile("fixtures/project_add_issue_response.json");
    pub const project_remove_issue_response = @embedFile("fixtures/project_remove_issue_response.json");
    pub const project_statuses_response = @embedFile("fixtures/project_statuses_response.json");
    pub const comment_create_response = @embedFile("fixtures/comment_create_response.json");
    pub const issue_comments_response = @embedFile("fixtures/issue_comments_response.json");
    pub const issue_comments_table = @embedFile("fixtures/issue_comments_table.txt");
    pub const comment_update_response = @embedFile("fixtures/comment_update_response.json");
    pub const comment_delete_response = @embedFile("fixtures/comment_delete_response.json");
    pub const labels_response = @embedFile("fixtures/labels_response.json");
    pub const labels_table = @embedFile("fixtures/labels_table.txt");
    pub const users_response = @embedFile("fixtures/users_response.json");
    pub const users_table = @embedFile("fixtures/users_table.txt");
    pub const states_response = @embedFile("fixtures/states_response.json");
    pub const states_table = @embedFile("fixtures/states_table.txt");
    pub const issue_start_response = @embedFile("fixtures/issue_start_response.json");
    pub const issue_start_already_started = @embedFile("fixtures/issue_start_already_started.json");
    pub const issue_start_no_started = @embedFile("fixtures/issue_start_no_started.json");
    pub const issue_start_update_response = @embedFile("fixtures/issue_start_update_response.json");
    pub const issue_ref_response = @embedFile("fixtures/issue_ref_response.json");
    pub const issue_pr_response = @embedFile("fixtures/issue_pr_response.json");
    pub const milestones_response = @embedFile("fixtures/milestones_response.json");
    pub const milestones_table = @embedFile("fixtures/milestones_table.txt");
    pub const milestone_project_lookup = @embedFile("fixtures/milestone_project_lookup.json");
    pub const milestone_view_response = @embedFile("fixtures/milestone_view_response.json");
    pub const milestone_create_response = @embedFile("fixtures/milestone_create_response.json");
    pub const milestone_update_response = @embedFile("fixtures/milestone_update_response.json");
    pub const milestone_delete_response = @embedFile("fixtures/milestone_delete_response.json");
    pub const milestone_delete_lookup = @embedFile("fixtures/milestone_delete_lookup.json");
};

test "config save and load roundtrip" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("file-key");
    try cfg.setDefaultTeamId("team-123");
    try cfg.setDefaultOutput("json");
    try cfg.save(allocator, config_path);

    var loaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer loaded.deinit();
    try std.testing.expect(loaded.api_key != null);
    try std.testing.expectEqualStrings("file-key", loaded.api_key.?);
    try std.testing.expectEqualStrings("team-123", loaded.default_team_id);
    try std.testing.expectEqualStrings("json", loaded.default_output);
    try std.testing.expect(loaded.default_state_filter.len == config.default_state_filter_value.len);
}

test "config env override precedence" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("file-key");
    try cfg.save(allocator, config_path);
    try setEnvValue("env-key", allocator);

    var loaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("env-key", loaded.api_key.?);
}

test "config path honors LINEAR_CONFIG" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const default_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(default_path);
    const override_path = try std.fs.path.join(allocator, &.{ dir_path, "override.json" });
    defer allocator.free(override_path);

    var default_cfg = try config.load(allocator, test_io, testEnviron(), default_path);
    defer default_cfg.deinit();
    try default_cfg.setApiKey("default-key");
    try default_cfg.save(allocator, default_path);

    var override_cfg = try config.load(allocator, test_io, testEnviron(), override_path);
    defer override_cfg.deinit();
    try override_cfg.setApiKey("override-key");
    try override_cfg.save(allocator, override_path);

    try setConfigEnvValue(override_path, allocator);

    var loaded = try config.load(allocator, test_io, testEnviron(), null);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("override-key", loaded.api_key.?);
    try std.testing.expect(loaded.config_path != null);
    try std.testing.expectEqualStrings(override_path, loaded.config_path.?);
}

test "config warns on loose permissions" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    const file = try tmp.dir.createFile(test_io, "config.json", .{ .read = true, .truncate = true });
    defer file.close(test_io);
    try file.writeStreamingAll(test_io, "{\"api_key\":\"file-key\"}");
    try file.setPermissions(test_io, .fromMode(0o644));

    var loaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer loaded.deinit();
    try std.testing.expect(loaded.permissions_warning);
}

test "config caches team ids" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("file-key");
    try std.testing.expect(try cfg.cacheTeamId("ABC", "team-id-1"));
    try cfg.save(allocator, config_path);

    var loaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer loaded.deinit();
    const cached = loaded.lookupTeamId("ABC") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("team-id-1", cached);
}

test "config rejects invalid types" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    const file = try tmp.dir.createFile(test_io, "config.json", .{ .read = true, .truncate = true });
    defer file.close(test_io);
    try file.writeStreamingAll(test_io, "{\"api_key\":123,\"default_state_filter\":\"todo\"}");

    try std.testing.expectError(error.InvalidConfig, config.load(allocator, test_io, testEnviron(), config_path));
}

test "config env api key is not persisted" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    const previous_home = testEnviron().getAlloc(allocator, "HOME") catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
        restoreEnv("HOME\x00", previous_home, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    try setEnvValue("env-only-key", allocator);
    try setEnvPair("HOME\x00", dir_path, allocator);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("env-only-key", cfg.api_key.?);
    try cfg.save(allocator, config_path);

    const contents = try tmp.dir.readFileAlloc(test_io, "config.json", allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "env-only-key") == null);
}

test "config command sets default output" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{ "set", "default_output", "json" };
    const runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "default_output saved") != null);

    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("json", reloaded.default_output);
}

test "config command rejects invalid default output" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{ "set", "default_output", "csv" };
    const runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "default_output must be 'table' or 'json'") != null);
    try std.testing.expectEqualStrings(config.default_output_value, cfg.default_output);
}

test "config command validates team selection" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    const response =
        \\{
        \\  "data": {
        \\    "teams": {
        \\      "nodes": [
        \\        { "id": "team-id-1", "key": "ENG" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    try server.set("TeamLookup", response);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{ "set", "default_team_id", "ENG" };
    var runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ENG", cfg.default_team_id);
    const cached = cfg.lookupTeamId("ENG") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("team-id-1", cached);

    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    const persisted = reloaded.lookupTeamId("ENG") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("team-id-1", persisted);
}

test "config command refuses to save an unknown team" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    const response = "{\"data\":{\"teams\":{\"nodes\":[]}}}";
    try server.set("TeamLookup", response);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{ "set", "default_team_id", "MISSING" };
    var runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);

    // A lookup that succeeded and found nothing is a verdict, not a warning:
    // persisting the value anyway would report success for a team id that fails
    // at the next command that needs one.
    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "team 'MISSING' not found in workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "was not changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "teams list") != null);
    try std.testing.expectEqual(@as(usize, 0), cfg.default_team_id.len);
    try std.testing.expectEqualStrings("", capture.stdout);

    // Nothing reached the config file either, so there is no bad value to find
    // on the next run.
    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), reloaded.default_team_id.len);
}

test "config command separates a failed team lookup from a missing team" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // No `TeamLookup` fixture: the request itself fails, which stands in for a
    // timeout, a 5xx, or no connectivity. The workspace was never asked, so the
    // team is unverified rather than known-bad.

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{ "set", "default_team_id", "ENG" };
    var runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "could not verify team 'ENG'") != null);
    // The real cause is named rather than being reported as a bad team.
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "request failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "not found in workspace") == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.default_team_id.len);
}

test "config command unsets state filter" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var set_args = [_][]const u8{ "set", "default_state_filter", "backlog" };
    var runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = set_args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const set_capture = try captureOutput(allocator, &runner, runConfig);
    defer set_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), set_capture.exit_code);
    try std.testing.expectEqual(@as(usize, 1), cfg.default_state_filter.len);
    try std.testing.expectEqualStrings("backlog", cfg.default_state_filter[0]);

    var unset_args = [_][]const u8{ "unset", "default_state_filter" };
    runner.ctx.args = unset_args[0..];
    const unset_capture = try captureOutput(allocator, &runner, runConfig);
    defer unset_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), unset_capture.exit_code);
    try std.testing.expectEqual(config.default_state_filter_value.len, cfg.default_state_filter.len);
    for (cfg.default_state_filter, 0..) |entry, idx| {
        try std.testing.expectEqualStrings(config.default_state_filter_value[idx], entry);
    }
}

test "config command unsets default output" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var set_args = [_][]const u8{ "set", "default_output", "json" };
    var runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = set_args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const set_capture = try captureOutput(allocator, &runner, runConfig);
    defer set_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), set_capture.exit_code);
    try std.testing.expectEqualStrings("json", cfg.default_output);

    var unset_args = [_][]const u8{ "unset", "default_output" };
    runner.ctx.args = unset_args[0..];
    const unset_capture = try captureOutput(allocator, &runner, runConfig);
    defer unset_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), unset_capture.exit_code);
    try std.testing.expectEqualStrings(config.default_output_value, cfg.default_output);

    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings(config.default_output_value, reloaded.default_output);
}

test "config command unsets default team id" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey("test-key");
    try cfg.setDefaultTeamId("TEAM-123");

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{ "unset", "default_team_id" };
    const runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = false,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqual(@as(usize, 0), cfg.default_team_id.len);

    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), reloaded.default_team_id.len);
}

test "config show returns json" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setDefaultTeamId("ENG");
    try cfg.setDefaultOutput("json");
    const states = [_][]const u8{ "backlog", "started" };
    try cfg.setStateFilterValues(states[0..]);

    const Runner = struct { ctx: config_cmd.Context };
    const runConfig = struct {
        pub fn call(r: *const Runner) !u8 {
            return config_cmd.run(r.ctx);
        }
    }.call;

    var args = [_][]const u8{"show"};
    const runner = Runner{ .ctx = .{
        .allocator = allocator,
        .io = test_io,
        .config = &cfg,
        .args = args[0..],
        .json_output = true,
        .config_path = config_path,
        .retries = 0,
        .timeout_ms = 10_000,
    } };

    const capture = try captureOutput(allocator, &runner, runConfig);
    defer capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    const config_path_value = obj.get("config_path") orelse return error.TestExpectedResult;
    try std.testing.expect(config_path_value == .string);
    try std.testing.expectEqualStrings(config_path, config_path_value.string);

    const team_value = obj.get("default_team_id") orelse return error.TestExpectedResult;
    try std.testing.expect(team_value == .string);
    try std.testing.expectEqualStrings("ENG", team_value.string);

    const output_value = obj.get("default_output") orelse return error.TestExpectedResult;
    try std.testing.expect(output_value == .string);
    try std.testing.expectEqualStrings("json", output_value.string);

    const state_value = obj.get("default_state_filter") orelse return error.TestExpectedResult;
    try std.testing.expect(state_value == .array);
    try std.testing.expectEqual(@as(usize, 2), state_value.array.items.len);
    try std.testing.expect(state_value.array.items[0] == .string);
    try std.testing.expect(state_value.array.items[1] == .string);
    try std.testing.expectEqualStrings("backlog", state_value.array.items[0].string);
    try std.testing.expectEqualStrings("started", state_value.array.items[1].string);
}

test "parse gql options" {
    const args = [_][]const u8{ "--query", "file.graphql", "--vars", "{\"a\":1}", "--data-only", "--fields", "data" };
    const opts = try gql.parseOptions(args[0..]);
    try std.testing.expect(opts.query_path != null);
    try std.testing.expect(opts.vars_json != null);
    try std.testing.expect(opts.data_only);
    try std.testing.expectEqualStrings("data", opts.fields.?);
}

test "parse search options" {
    const args = [_][]const u8{
        "agent",
        "--team",
        "ENG",
        "--fields",
        "title,comments,identifier",
        "--state-type",
        "backlog,started",
        "--assignee",
        "user-1",
        "--limit",
        "10",
        "--case-sensitive",
    };
    const opts = try search_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("agent", opts.query.?);
    try std.testing.expectEqualStrings("ENG", opts.team.?);
    try std.testing.expectEqualStrings("title,comments,identifier", opts.fields.?);
    try std.testing.expectEqualStrings("backlog,started", opts.state_type.?);
    try std.testing.expectEqualStrings("user-1", opts.assignee.?);
    try std.testing.expectEqual(@as(usize, 10), opts.limit);
    try std.testing.expect(opts.case_sensitive);
}

test "parse search rejects zero limit" {
    const args = [_][]const u8{ "query", "--limit", "0" };
    try std.testing.expectError(error.InvalidLimit, search_cmd.parseOptions(args[0..]));
}

test "parse search unknown flag errors" {
    const args = [_][]const u8{ "query", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, search_cmd.parseOptions(args[0..]));
}

test "parse issues options" {
    const args = [_][]const u8{
        "--team",
        "TEAM",
        "--state-type",
        "todo,in_progress",
        "--state-id",
        "state-1",
        "--assignee",
        "user-1",
        "--label",
        "label-1",
        "--project",
        "proj-1",
        "--milestone",
        "ms-1",
        "--updated-since",
        "2024-01-01T00:00:00Z",
        "--sort",
        "updated:asc",
        "--limit",
        "5",
        "--max-items",
        "50",
        "--sub-limit",
        "3",
        "--cursor",
        "abc",
        "--pages",
        "2",
        "--fields",
        "identifier,title",
        "--include-projects",
        "--plain",
        "--no-truncate",
        "--human-time",
        "--quiet",
        "--data-only",
    };
    const opts = try issues_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("TEAM", opts.team.?);
    try std.testing.expectEqualStrings("todo,in_progress", opts.state_type.?);
    try std.testing.expectEqualStrings("state-1", opts.state_id.?);
    try std.testing.expectEqualStrings("user-1", opts.assignee.?);
    try std.testing.expectEqualStrings("label-1", opts.label.?);
    try std.testing.expectEqualStrings("proj-1", opts.project.?);
    try std.testing.expectEqualStrings("ms-1", opts.milestone.?);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", opts.updated_since.?);
    try std.testing.expect(opts.sort != null);
    try std.testing.expectEqualStrings("updated", @tagName(opts.sort.?.field));
    try std.testing.expectEqualStrings("asc", @tagName(opts.sort.?.direction));
    try std.testing.expectEqual(@as(usize, 5), opts.limit);
    try std.testing.expectEqual(@as(usize, 50), opts.max_items.?);
    try std.testing.expectEqual(@as(usize, 3), opts.sub_limit);
    try std.testing.expectEqualStrings("abc", opts.cursor.?);
    try std.testing.expectEqual(@as(usize, 2), opts.pages.?);
    try std.testing.expectEqualStrings("identifier,title", opts.fields.?);
    try std.testing.expect(opts.include_projects);
    try std.testing.expect(opts.plain);
    try std.testing.expect(opts.no_truncate);
    try std.testing.expect(opts.human_time);
    try std.testing.expect(!opts.all);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
}

test "normalize state type aliases" {
    // in_progress variations map to started
    try std.testing.expectEqualStrings("started", issues_cmd.normalizeStateType("in_progress"));
    try std.testing.expectEqualStrings("started", issues_cmd.normalizeStateType("in-progress"));
    try std.testing.expectEqualStrings("started", issues_cmd.normalizeStateType("inprogress"));
    try std.testing.expectEqualStrings("started", issues_cmd.normalizeStateType("IN_PROGRESS"));
    try std.testing.expectEqualStrings("started", issues_cmd.normalizeStateType("In-Progress"));

    // todo maps to unstarted
    try std.testing.expectEqualStrings("unstarted", issues_cmd.normalizeStateType("todo"));
    try std.testing.expectEqualStrings("unstarted", issues_cmd.normalizeStateType("TODO"));

    // canonical values pass through unchanged
    try std.testing.expectEqualStrings("started", issues_cmd.normalizeStateType("started"));
    try std.testing.expectEqualStrings("unstarted", issues_cmd.normalizeStateType("unstarted"));
    try std.testing.expectEqualStrings("backlog", issues_cmd.normalizeStateType("backlog"));
    try std.testing.expectEqualStrings("triage", issues_cmd.normalizeStateType("triage"));
    try std.testing.expectEqualStrings("completed", issues_cmd.normalizeStateType("completed"));
    try std.testing.expectEqualStrings("canceled", issues_cmd.normalizeStateType("canceled"));
}

test "parse issue create options" {
    const args = [_][]const u8{ "--team", "team-1", "--title", "hello", "--priority", "2", "--labels", "a,b", "--quiet", "--data-only" };
    const opts = try issue_create_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("team-1", opts.team.?);
    try std.testing.expectEqualStrings("hello", opts.title.?);
    try std.testing.expect(opts.priority.? == 2);
    try std.testing.expect(opts.labels != null);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
}

test "parse issue update options" {
    const args = [_][]const u8{
        "ENG-123",
        "--assignee",
        "me",
        "--parent",
        "ENG-100",
        "--state",
        "state-1",
        "--priority",
        "2",
        "--title",
        "Updated",
        "--description",
        "Updated description",
        "--yes",
        "--quiet",
    };
    const opts = try issue_update_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG-123", opts.identifier.?);
    try std.testing.expectEqualStrings("me", opts.assignee.?);
    try std.testing.expectEqualStrings("ENG-100", opts.parent.?);
    try std.testing.expectEqualStrings("state-1", opts.state.?);
    try std.testing.expectEqual(@as(i64, 2), opts.priority.?);
    try std.testing.expectEqualStrings("Updated", opts.title.?);
    try std.testing.expectEqualStrings("Updated description", opts.description.?);
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.quiet);
}

test "parse issue update rejects unknown flag" {
    const args = [_][]const u8{ "ENG-123", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, issue_update_cmd.parseOptions(args[0..]));
}

test "parse issue link options blocks" {
    const args = [_][]const u8{ "ENG-123", "--blocks", "ENG-456", "--yes" };
    const opts = try issue_link_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG-123", opts.identifier.?);
    try std.testing.expectEqualStrings("ENG-456", opts.blocks.?);
    try std.testing.expect(opts.related == null);
    try std.testing.expect(opts.duplicate == null);
    try std.testing.expect(opts.yes);
}

test "parse issue link options related" {
    const args = [_][]const u8{ "ENG-123", "--related", "ENG-789", "--yes" };
    const opts = try issue_link_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG-789", opts.related.?);
    try std.testing.expect(opts.blocks == null);
}

test "parse issue link options duplicate" {
    const args = [_][]const u8{ "ENG-123", "--duplicate", "ENG-100", "--yes" };
    const opts = try issue_link_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG-100", opts.duplicate.?);
}

test "parse issue link rejects unknown flag" {
    const args = [_][]const u8{ "ENG-123", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, issue_link_cmd.parseOptions(args[0..]));
}

test "parse project create options" {
    var args = [_][]const u8{
        "--name",
        "Roadmap",
        "--team",
        "ENG",
        "--description",
        "Desc",
        "--start-date",
        "2024-01-01",
        "--target-date",
        "2024-06-30",
        "--state",
        "started",
        "--yes",
        "--quiet",
        "--data-only",
    };
    const opts = try project_create_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("Roadmap", opts.name.?);
    try std.testing.expectEqualStrings("ENG", opts.team.?);
    try std.testing.expectEqualStrings("Desc", opts.description.?);
    try std.testing.expectEqualStrings("2024-01-01", opts.start_date.?);
    try std.testing.expectEqualStrings("2024-06-30", opts.target_date.?);
    try std.testing.expectEqualStrings("started", opts.state.?);
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
}

test "parse project update options" {
    var args = [_][]const u8{ "proj_123", "--name", "New Name", "--description", "Updated", "--state", "started", "--yes", "--quiet", "--data-only" };
    const opts = try project_update_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("proj_123", opts.identifier.?);
    try std.testing.expectEqualStrings("New Name", opts.name.?);
    try std.testing.expectEqualStrings("Updated", opts.description.?);
    try std.testing.expectEqualStrings("started", opts.state.?);
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
}

test "parse project issue modification options" {
    var args = [_][]const u8{ "proj_123", "ENG-42", "--yes", "--quiet", "--data-only" };
    const opts = try project_issues_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("proj_123", opts.project_id.?);
    try std.testing.expectEqualStrings("ENG-42", opts.issue_id.?);
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
}

test "global flags parsed after subcommand" {
    const allocator = std.testing.allocator;
    var opts = cli.GlobalOptions{};
    const args = [_][]const u8{ "issues", "list", "--json", "--timeout-ms", "2000" };
    const cleaned = try cli.stripTrailingGlobals(allocator, args[0..], &opts);
    defer allocator.free(cleaned);

    try std.testing.expect(opts.json);
    try std.testing.expectEqual(@as(u32, 2000), opts.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), cleaned.len);
    try std.testing.expectEqualStrings("issues", cleaned[0]);
    try std.testing.expectEqualStrings("list", cleaned[1]);
}

test "endpoint flag parsed from globals" {
    var args = [_][]const u8{ "linear", "--endpoint", "http://localhost:3000/mock", "issues" };
    const parsed = try cli.parseGlobal(args[0..]);
    try std.testing.expect(parsed.opts.endpoint != null);
    try std.testing.expectEqualStrings("http://localhost:3000/mock", parsed.opts.endpoint.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.rest.len);
    try std.testing.expectEqualStrings("issues", parsed.rest[0]);
}

test "parseGlobal handles keepalive and version flags" {
    var args = [_][]const u8{ "linear", "--no-keepalive", "--version", "issues" };
    const parsed = try cli.parseGlobal(args[0..]);
    try std.testing.expect(!parsed.opts.keep_alive);
    try std.testing.expect(parsed.opts.version);
    try std.testing.expectEqualStrings("issues", parsed.rest[0]);
}

test "parseGlobal errors on missing value" {
    var args = [_][]const u8{ "linear", "--timeout-ms" };
    try std.testing.expectError(error.MissingValue, cli.parseGlobal(args[0..]));
}

test "parseGlobal errors on unknown flag" {
    var args = [_][]const u8{ "linear", "--bogus" };
    try std.testing.expectError(error.UnknownFlag, cli.parseGlobal(args[0..]));
}

test "stripTrailingGlobals stops at separator" {
    const allocator = std.testing.allocator;
    var opts = cli.GlobalOptions{};
    const args = [_][]const u8{ "issues", "--", "--json", "list" };
    const cleaned = try cli.stripTrailingGlobals(allocator, args[0..], &opts);
    defer allocator.free(cleaned);
    try std.testing.expectEqual(@as(usize, 3), cleaned.len);
    try std.testing.expectEqualStrings("issues", cleaned[0]);
    try std.testing.expectEqualStrings("--", cleaned[1]);
    try std.testing.expectEqualStrings("list", cleaned[2]);
    try std.testing.expect(opts.json);
}

test "printer issue table includes headers" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    const rows = [_]printer.IssueRow{
        .{
            .identifier = "ISS-1",
            .title = "Example",
            .state = "todo",
            .assignee = "None",
            .priority = "High",
            .parent = "",
            .sub_issues = "",
            .project = "",
            .milestone = "",
            .updated = "2024-05-10T12:00:00Z",
        },
    };

    try printer.printIssueTable(allocator, &buffer.writer, &rows, printer.issue_default_fields[0..], .{});
    const output = buffer.written();
    try std.testing.expect(std.mem.startsWith(u8, output, "Identifier"));
    try std.testing.expect(std.mem.indexOf(u8, output, "ISS-1") != null);
}

test "printer key values plain includes trailing newline" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    const pairs = [_]printer.KeyValue{
        .{ .key = "id", .value = "ISS-1" },
        .{ .key = "title", .value = "Example" },
    };

    try printer.printKeyValuesPlain(&buffer.writer, pairs[0..]);
    try std.testing.expectEqualStrings("id\tISS-1\ntitle\tExample\n", buffer.written());
}

test "printer issue table plain preserves long values" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    const long_title = "This is a very long issue title that should remain visible";
    const rows = [_]printer.IssueRow{
        .{
            .identifier = "ISS-99",
            .title = long_title,
            .state = "todo",
            .assignee = "None",
            .priority = "High",
            .parent = "",
            .sub_issues = "",
            .project = "",
            .milestone = "",
            .updated = "2024-05-10T12:00:00Z",
        },
    };

    const opts = printer.TableOptions{ .pad = false, .truncate = false };
    try printer.printIssueTable(allocator, &buffer.writer, &rows, printer.issue_default_fields[0..], opts);
    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "...") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, long_title) != null);
}

test "human time renders relative days" {
    const allocator = std.testing.allocator;
    const formatted = try printer.humanTime(allocator, std.testing.io, "1970-01-02T00:00:00Z", 86400 * 3);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("2d ago", formatted);
}

test "printJsonFields filters root object" {
    const allocator = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    defer obj.object.deinit(allocator);
    try obj.object.put(allocator, "a", .{ .string = "1" });
    try obj.object.put(allocator, "b", .{ .string = "2" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try printer.printJsonFields(obj, &out.writer, true, &.{"b"});
    try std.testing.expectEqualStrings("{\n  \"b\": \"2\"\n}\n", out.written());
}

test "gql fields filter data without data-only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const query_file = try tmp.dir.createFile(test_io, "viewer.graphql", .{ .read = true, .truncate = true });
    defer query_file.close(test_io);
    try query_file.writeStreamingAll(test_io, "query Viewer { viewer { id name email } }");
    const query_path = try tmp.dir.realPathFileAlloc(test_io, "viewer.graphql", allocator);
    defer allocator.free(query_path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Viewer", fixtures.viewer_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
        query: []const u8,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--query",
                r.query,
                "--operation-name",
                "Viewer",
                "--fields",
                "viewer",
            };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg, .query = query_path };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    const expected =
        \\{
        \\  "viewer": {
        \\    "id": "user-1",
        \\    "name": "Offline User",
        \\    "email": "offline@example.com"
        \\  }
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "gql enforces mutually exclusive vars options" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const query_file = try tmp.dir.createFile(test_io, "query.graphql", .{ .read = true, .truncate = true });
    defer query_file.close(test_io);
    try query_file.writeStreamingAll(test_io, "query Viewer { viewer { id } }");
    const query_path = try tmp.dir.realPathFileAlloc(test_io, "query.graphql", allocator);
    defer allocator.free(query_path);
    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
        query: []const u8,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--query",
                r.query,
                "--vars",
                "{}",
                "--vars-file",
                "vars.json",
            };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg, .query = query_path };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "only one of --vars") != null);
}

test "gql data-only requires data field" {
    const allocator = std.testing.allocator;
    const missing_data = "{}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const query_file = try tmp.dir.createFile(test_io, "query.graphql", .{ .read = true, .truncate = true });
    defer query_file.close(test_io);
    try query_file.writeStreamingAll(test_io, "query Viewer { viewer { id } }");
    const query_path = try tmp.dir.realPathFileAlloc(test_io, "query.graphql", allocator);
    defer allocator.free(query_path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Viewer", missing_data);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
        query: []const u8,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--query", r.query, "--data-only", "--operation-name", "Viewer" };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg, .query = query_path };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "response did not include a data field") != null);
}

test "parse issues all without pages" {
    const args = [_][]const u8{"--all"};
    const opts = try issues_cmd.parseOptions(args[0..]);
    try std.testing.expect(opts.all);
    try std.testing.expect(opts.pages == null);
}

test "parse issues pages/all conflict" {
    const args = [_][]const u8{ "--pages", "1", "--all" };
    try std.testing.expectError(error.ConflictingPageFlags, issues_cmd.parseOptions(args[0..]));
}

test "parse issues rejects zero limit" {
    const args = [_][]const u8{ "--limit", "0" };
    try std.testing.expectError(error.InvalidLimit, issues_cmd.parseOptions(args[0..]));
}

test "parse issues unknown flag errors" {
    const args = [_][]const u8{"--unknown"};
    try std.testing.expectError(error.UnknownFlag, issues_cmd.parseOptions(args[0..]));
}

fn setEnvValue(value: []const u8, allocator: std.mem.Allocator) !void {
    try setEnvPair(env_name_z, value, allocator);
}

fn clearEnv() void {
    clearEnvVar(env_name_z);
    clearEnvVar(config_env_name_z);
}

/// The environment block captured at process start goes stale as soon as libc
/// `setenv`/`unsetenv` reallocate `environ`, so rebuild the view from libc's
/// live pointer for every lookup.
fn testEnviron() std.process.Environ {
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .block = .{ .slice = std.c.environ[0..count :null] } };
}

fn setConfigEnvValue(value: []const u8, allocator: std.mem.Allocator) !void {
    try setEnvPair(config_env_name_z, value, allocator);
}

fn setEnvPair(name_z: [*:0]const u8, value: []const u8, allocator: std.mem.Allocator) !void {
    var buf = try allocator.alloc(u8, value.len + 1);
    defer allocator.free(buf);
    std.mem.copyForwards(u8, buf[0..value.len], value);
    buf[value.len] = 0;
    _ = c.setenv(name_z, buf.ptr, 1);
}

fn clearEnvVar(name_z: [*:0]const u8) void {
    _ = c.unsetenv(name_z);
}

fn restoreEnv(name_z: [*:0]const u8, previous: ?[]u8, allocator: std.mem.Allocator) void {
    if (previous) |value| {
        setEnvPair(name_z, value, allocator) catch {};
        allocator.free(value);
    } else {
        clearEnvVar(name_z);
    }
}

fn makeTestConfig(allocator: std.mem.Allocator) !config.Config {
    var cfg = config.Config{ .allocator = allocator, .io = test_io, .environ = testEnviron() };
    cfg.team_cache = std.StringHashMap([]const u8).init(allocator);
    try cfg.setApiKey("test-key");
    try cfg.setDefaultTeamId("test-team-id");
    return cfg;
}

const Capture = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

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

fn captureOutput(allocator: std.mem.Allocator, context: anytype, run_fn: anytype) !Capture {
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

/// Same as `captureOutput`, but also feeds `stdin_data` to the command on a
/// pipe. Commands that read stdin would otherwise consume the test runner's
/// own stdin.
fn captureOutputWithStdin(
    allocator: std.mem.Allocator,
    context: anytype,
    run_fn: anytype,
    stdin_data: []const u8,
) !Capture {
    var stdin_pipe = try openPipe();
    defer if (stdin_pipe[0] != -1) closeFd(stdin_pipe[0]);
    defer if (stdin_pipe[1] != -1) closeFd(stdin_pipe[1]);

    if (stdin_data.len > 0) {
        const written = std.c.write(stdin_pipe[1], stdin_data.ptr, stdin_data.len);
        if (written < 0 or @as(usize, @intCast(written)) != stdin_data.len) return error.RedirectFailed;
    }
    closeFd(stdin_pipe[1]);
    stdin_pipe[1] = -1;

    const saved_stdin = try dupFd(posix.STDIN_FILENO);
    defer closeFd(saved_stdin);
    try dupFdTo(stdin_pipe[0], posix.STDIN_FILENO);
    defer dupFdTo(saved_stdin, posix.STDIN_FILENO) catch {};

    return captureOutput(allocator, context, run_fn);
}

fn readAll(allocator: std.mem.Allocator, fd: posix.fd_t) ![]u8 {
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

test "search renders table and warns about pagination with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("SearchIssues", fixtures.issues_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runSearch = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{"offline"};
            return search_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runSearch);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.issues_table, capture.stdout);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "pagination not implemented") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "cursor-2") != null);
}

test "search builds filters for selected fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Viewer", fixtures.viewer_response);
    try server.set("SearchIssues", fixtures.issues_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runSearch = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "Agent",
                "--team",
                "TEAM",
                "--fields",
                "title,comments",
                "--state-type",
                "backlog,started",
                "--assignee",
                "me",
                "--limit",
                "3",
                "--case-sensitive",
            };
            return search_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = true,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runSearch);
    defer capture.deinit(allocator);
    if (capture.exit_code != 0) {
        std.debug.print("search stdout: {s}\nstderr: {s}\n", .{ capture.stdout, capture.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("SearchIssues", recorded.operation);

    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;

    const first_value = root.object.get("first") orelse return error.TestExpectedResult;
    if (first_value != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 3), first_value.integer);

    const filter = root.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;

    const or_value = filter.object.get("or") orelse return error.TestExpectedResult;
    if (or_value != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 2), or_value.array.items.len);

    const title_entry = or_value.array.items[0];
    if (title_entry != .object) return error.TestExpectedResult;
    const title_filter = title_entry.object.get("title") orelse return error.TestExpectedResult;
    if (title_filter != .object) return error.TestExpectedResult;
    const contains_title = title_filter.object.get("contains") orelse return error.TestExpectedResult;
    if (contains_title != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Agent", contains_title.string);
    try std.testing.expect(title_filter.object.get("containsIgnoreCase") == null);

    const comments_entry = or_value.array.items[1];
    if (comments_entry != .object) return error.TestExpectedResult;
    const comments_filter = comments_entry.object.get("comments") orelse return error.TestExpectedResult;
    if (comments_filter != .object) return error.TestExpectedResult;
    const some_filter = comments_filter.object.get("some") orelse return error.TestExpectedResult;
    if (some_filter != .object) return error.TestExpectedResult;
    const body_filter = some_filter.object.get("body") orelse return error.TestExpectedResult;
    if (body_filter != .object) return error.TestExpectedResult;
    const body_contains = body_filter.object.get("contains") orelse return error.TestExpectedResult;
    if (body_contains != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Agent", body_contains.string);

    const state_filter = filter.object.get("state") orelse return error.TestExpectedResult;
    if (state_filter != .object) return error.TestExpectedResult;
    const type_filter = state_filter.object.get("type") orelse return error.TestExpectedResult;
    if (type_filter != .object) return error.TestExpectedResult;
    const in_filter = type_filter.object.get("in") orelse return error.TestExpectedResult;
    if (in_filter != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 2), in_filter.array.items.len);
    if (in_filter.array.items[0] != .string) return error.TestExpectedResult;
    if (in_filter.array.items[1] != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("backlog", in_filter.array.items[0].string);
    try std.testing.expectEqualStrings("started", in_filter.array.items[1].string);

    const assignee_filter = filter.object.get("assignee") orelse return error.TestExpectedResult;
    if (assignee_filter != .object) return error.TestExpectedResult;
    const assignee_id = assignee_filter.object.get("id") orelse return error.TestExpectedResult;
    if (assignee_id != .object) return error.TestExpectedResult;
    const eq_assignee = assignee_id.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_assignee != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("user-1", eq_assignee.string);

    const team_filter = filter.object.get("team") orelse return error.TestExpectedResult;
    if (team_filter != .object) return error.TestExpectedResult;
    const team_key = team_filter.object.get("key") orelse return error.TestExpectedResult;
    if (team_key != .object) return error.TestExpectedResult;
    const team_eq = team_key.object.get("eq") orelse return error.TestExpectedResult;
    if (team_eq != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("TEAM", team_eq.string);
}

test "issues list renders table and warns about pagination with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "2" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.issues_table, capture.stdout);
    try std.testing.expectEqualStrings(fixtures.issues_pagination_stderr, capture.stderr);
}

test "issues list prints json output with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssuesJson = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{};
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssuesJson);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.issues_json, capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issues list data-only json includes sub-issues and project fields when enabled" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_with_subs_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            // Sub-issues and parents are only fetched when asked for, so the
            // "enabled" path has to select those columns explicitly.
            var args = [_][]const u8{
                "--limit",
                "1",
                "--data-only",
                "--include-projects",
                "--fields",
                "identifier,title,state,assignee,priority,updated,parent,sub_issues",
            };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    if (capture.exit_code != 0) {
        std.debug.print("issues list stdout: {s}\nstderr: {s}\n", .{ capture.stdout, capture.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const nodes_value = root.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes_value != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), nodes_value.array.items.len);
    const first = nodes_value.array.items[0];
    if (first != .object) return error.TestExpectedResult;
    try std.testing.expect(first.object.get("sub_issue_identifiers") != null);
    try std.testing.expect(first.object.get("parent_identifier") != null);
    try std.testing.expect(first.object.get("project") != null);
    try std.testing.expect(first.object.get("milestone") != null);
    const page_info = root.object.get("pageInfo") orelse return error.TestExpectedResult;
    if (page_info != .object) return error.TestExpectedResult;
    const limit_value = root.object.get("limit") orelse return error.TestExpectedResult;
    if (limit_value != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 1), limit_value.integer);
}

test "issues list data-only json hides sub-issues when disabled" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_with_subs_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "1", "--data-only", "--sub-limit", "0" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    if (capture.exit_code != 0) {
        std.debug.print("issues list stdout: {s}\nstderr: {s}\n", .{ capture.stdout, capture.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const nodes_value = root.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes_value != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), nodes_value.array.items.len);
    const first = nodes_value.array.items[0];
    if (first != .object) return error.TestExpectedResult;
    try std.testing.expect(first.object.get("sub_issue_identifiers") == null);
    try std.testing.expect(first.object.get("parent_identifier") == null);
    try std.testing.expect(first.object.get("project") == null);
    try std.testing.expect(first.object.get("milestone") == null);
    const page_info = root.object.get("pageInfo") orelse return error.TestExpectedResult;
    if (page_info != .object) return error.TestExpectedResult;
    const limit_value = root.object.get("limit") orelse return error.TestExpectedResult;
    if (limit_value != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 1), limit_value.integer);
}

test "issues list warns when sub-issues truncated" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_with_subs_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "1", "--sub-limit", "1", "--quiet" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "sub-issues limited") != null);
}

test "issues list paginates across pages when multiple requests allowed" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Issues", &.{ fixtures.issues_response, fixtures.issues_page2_response });
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "3", "--pages", "2" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "LIN-101") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "LIN-102") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "LIN-103") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "across 2 page") != null);
}

test "issues list quiet prints identifiers only to stdout" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "2", "--quiet" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqualStrings("LIN-101\nLIN-102\n", capture.stdout);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "fetched 2 items") != null);
}

test "issues list honors max-items" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "2", "--max-items", "1", "--quiet" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqualStrings("LIN-101\n", capture.stdout);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "stopped after 1 items") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "more available") != null);
}

test "issues list applies created-since and project filters" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--limit",
                "1",
                "--created-since",
                "2024-01-01T00:00:00Z",
                "--project",
                "proj-123",
            };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);
    if (capture.exit_code != 0) {
        std.debug.print("issues created-since stdout: {s}\nstderr: {s}\n", .{ capture.stdout, capture.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expect(recorded.variables_json != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, recorded.variables_json.?, .{});
    defer parsed.deinit();
    const vars_root = parsed.value;
    if (vars_root != .object) return error.TestExpectedResult;
    const filter = vars_root.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;
    const created_at = filter.object.get("createdAt") orelse return error.TestExpectedResult;
    if (created_at != .object) return error.TestExpectedResult;
    const gt_value = created_at.object.get("gt") orelse return error.TestExpectedResult;
    if (gt_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", gt_value.string);

    const project = filter.object.get("project") orelse return error.TestExpectedResult;
    if (project != .object) return error.TestExpectedResult;
    const id_obj = project.object.get("id") orelse return error.TestExpectedResult;
    if (id_obj != .object) return error.TestExpectedResult;
    const eq_value = id_obj.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("proj-123", eq_value.string);
}

test "issues list resolves assignee me before applying filter" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Viewer", &.{ fixtures.viewer_response, fixtures.viewer_response });
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--assignee", " me ", "--limit", "1" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const viewer_series = server.fixtures.getPtr("Viewer") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), viewer_series.*.next);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Issues", recorded.operation);

    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars_root = parsed.value;
    if (vars_root != .object) return error.TestExpectedResult;

    const filter = vars_root.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;

    const assignee = filter.object.get("assignee") orelse return error.TestExpectedResult;
    if (assignee != .object) return error.TestExpectedResult;
    const id_obj = assignee.object.get("id") orelse return error.TestExpectedResult;
    if (id_obj != .object) return error.TestExpectedResult;
    const eq_value = id_obj.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("user-1", eq_value.string);
}

test "issues list warns when sub-issues are truncated" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_with_subs_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "1", "--sub-limit", "1" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "sub-issues limited to 1") != null);
}

test "issues list omits the sub-issue query unless sub-issues are requested" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", fixtures.issues_response);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
        args: []const []const u8,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = @constCast(r.args),
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;

    // Default field set has no sub-issue column, so the children sub-query is
    // pure waste and must not be emitted.
    {
        const args = [_][]const u8{ "--limit", "2" };
        const runner = Runner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };
        const capture = try captureOutput(allocator, &runner, runIssues);
        defer capture.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

        const recorded = server.lastRequest() orelse return error.TestExpectedResult;
        try std.testing.expectEqualStrings("Issues", recorded.operation);
        try std.testing.expect(std.mem.indexOf(u8, recorded.query, "children(") == null);
        try std.testing.expect(std.mem.indexOf(u8, recorded.query, "$subLimit") == null);

        const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestExpectedResult;
        try std.testing.expect(parsed.value.object.get("subLimit") == null);
    }

    // Selecting the column opts back in.
    {
        const args = [_][]const u8{ "--limit", "2", "--fields", "identifier,sub_issues" };
        const runner = Runner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };
        const capture = try captureOutput(allocator, &runner, runIssues);
        defer capture.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

        const recorded = server.lastRequest() orelse return error.TestExpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, recorded.query, "children(first: $subLimit)") != null);

        const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestExpectedResult;
        const sub_limit = parsed.value.object.get("subLimit") orelse return error.TestExpectedResult;
        if (sub_limit != .integer) return error.TestExpectedResult;
        try std.testing.expectEqual(@as(i64, 10), sub_limit.integer);
    }

    // An explicit --sub-limit is also an opt-in; the flag must not be a no-op.
    {
        const args = [_][]const u8{ "--limit", "2", "--sub-limit", "3" };
        const runner = Runner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };
        const capture = try captureOutput(allocator, &runner, runIssues);
        defer capture.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

        const recorded = server.lastRequest() orelse return error.TestExpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, recorded.query, "children(first: $subLimit)") != null);
    }

    // ...and --sub-limit 0 still disables it even when the column is selected.
    {
        const args = [_][]const u8{ "--limit", "2", "--fields", "identifier,sub_issues", "--sub-limit", "0" };
        const runner = Runner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };
        const capture = try captureOutput(allocator, &runner, runIssues);
        defer capture.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

        const recorded = server.lastRequest() orelse return error.TestExpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, recorded.query, "children(") == null);
    }
}

test "issues list warns on empty page" {
    const allocator = std.testing.allocator;
    const empty_payload =
        \\{
        \\  "data": {
        \\    "issues": {
        \\      "nodes": [],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-empty" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", empty_payload);
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--limit", "2" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "received empty page") != null);
}

test "issues list fails when team not found" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.team_lookup_empty);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runIssues = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--team", "missing-team" };
            return issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runIssues);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings("issues list: team 'missing-team' not found\n", capture.stderr);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("TeamLookup", recorded.operation);
}

test "teams list renders table with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Teams", fixtures.teams_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
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
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runTeams);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.teams_table, capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

/// Shared runner for the enumeration list commands; they take the same Context
/// shape, so only the args and the json flag vary between cases.
const EnumRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    json_output: bool = false,
};

fn runLabels(r: *const EnumRunner) !u8 {
    return labels_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runUsers(r: *const EnumRunner) !u8 {
    return users_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runStates(r: *const EnumRunner) !u8 {
    return states_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

test "labels list renders table with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.labels_table, capture.stdout);
    // Every paginating list command closes with the same summary line.
    try std.testing.expectEqualStrings("labels list: fetched 3 items across 1 page\n", capture.stderr);
}

test "labels list prints json output with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stderr);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const labels_obj = root.object.get("issueLabels") orelse return error.TestExpectedResult;
    if (labels_obj != .object) return error.TestExpectedResult;
    const nodes = labels_obj.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nodes.array.items.len);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueLabels", recorded.operation);
}

test "labels list projects selected fields with data-only" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,name", "--data-only" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "label-1\tbug\nlabel-2\tfeature\nlabel-3\tneeds-triage\n",
        capture.stdout,
    );
}

test "labels list quiet prints ids only" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{"--quiet"};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("label-1\nlabel-2\nlabel-3\n", capture.stdout);
}

test "labels list plain output drops padding and truncation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "name,description", "--plain" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // Column separators are still written between cells, so the empty trailing
    // description keeps its separator; only padding and ellipsis are dropped.
    try std.testing.expectEqualStrings(
        "Name  Description\n" ++
            "bug  Something is broken\n" ++
            "feature  New capability\n" ++
            "needs-triage  \n",
        capture.stdout,
    );
}

test "labels list reports the resume cursor when more labels remain" {
    const allocator = std.testing.allocator;
    const truncated_payload =
        \\{
        \\  "data": {
        \\    "issueLabels": {
        \\      "nodes": [
        \\        { "id": "label-9", "name": "chore", "color": "#bec2c8", "description": null, "team": { "key": "ENG" } }
        \\      ],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-label-9" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", truncated_payload);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "1", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("label-9\n", capture.stdout);
    // The default page budget is one page, so the walk stops here and hands the
    // caller the cursor to resume from instead of silently dropping the rest.
    try std.testing.expectEqualStrings(
        "labels list: fetched 1 items across 1 page; more available, resume with --cursor cursor-label-9\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "labels list rejects invalid fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,bogus" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings("labels list: invalid --fields value\n", capture.stderr);
}

test "labels list filters by team key" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", fixtures.labels_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--team", "ENG", "--limit", "10" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;

    const first_value = vars.object.get("first") orelse return error.TestExpectedResult;
    if (first_value != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 10), first_value.integer);

    const filter = vars.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;
    const team_filter = filter.object.get("team") orelse return error.TestExpectedResult;
    if (team_filter != .object) return error.TestExpectedResult;
    const key_filter = team_filter.object.get("key") orelse return error.TestExpectedResult;
    if (key_filter != .object) return error.TestExpectedResult;
    const eq_value = key_filter.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ENG", eq_value.string);
    try std.testing.expect(team_filter.object.get("id") == null);
}

test "parse labels list options" {
    const args = [_][]const u8{
        "--team",        "ENG",
        "--limit=25",    "--fields",
        "id,name",       "--plain",
        "--no-truncate", "--quiet",
        "--data-only",
    };
    const opts = try labels_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG", opts.team.?);
    try std.testing.expectEqual(@as(usize, 25), opts.limit);
    try std.testing.expectEqualStrings("id,name", opts.fields.?);
    try std.testing.expect(opts.plain);
    try std.testing.expect(opts.no_truncate);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
    try std.testing.expect(!opts.help);
}

test "parse labels list rejects bad limit and unknown flags" {
    const zero = [_][]const u8{ "--limit", "0" };
    try std.testing.expectError(error.InvalidLimit, labels_cmd.parseOptions(zero[0..]));

    const unknown = [_][]const u8{"--nope"};
    try std.testing.expectError(error.UnknownFlag, labels_cmd.parseOptions(unknown[0..]));

    const missing = [_][]const u8{"--team"};
    try std.testing.expectError(error.MissingValue, labels_cmd.parseOptions(missing[0..]));
}

/// One label per page so a two-entry sequence exercises a real cursor hand-off.
const labels_page1 =
    \\{
    \\  "data": {
    \\    "issueLabels": {
    \\      "nodes": [ { "id": "label-1", "name": "bug", "color": "#eb5757", "description": null, "team": { "key": "ENG" } } ],
    \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-label-1" }
    \\    }
    \\  }
    \\}
;
const labels_page2 =
    \\{
    \\  "data": {
    \\    "issueLabels": {
    \\      "nodes": [ { "id": "label-2", "name": "feature", "color": "#26b5ce", "description": null, "team": { "key": "ENG" } } ],
    \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-label-2" }
    \\    }
    \\  }
    \\}
;

test "labels list walks multiple pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueLabels", &.{ labels_page1, labels_page2 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "1", "--pages", "2", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // Rows from page one are still readable after page two was parsed, which is
    // only true because both responses are kept alive to the end.
    try std.testing.expectEqualStrings("label-1\nlabel-2\n", capture.stdout);
    try std.testing.expectEqualStrings("labels list: fetched 2 items across 2 pages\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-label-1\"") != null);
}

test "labels list truncates at max-items" {
    const allocator = std.testing.allocator;
    const two_on_a_page =
        \\{
        \\  "data": {
        \\    "issueLabels": {
        \\      "nodes": [
        \\        { "id": "label-1", "name": "bug", "color": "#eb5757", "description": null, "team": { "key": "ENG" } },
        \\        { "id": "label-2", "name": "feature", "color": "#26b5ce", "description": null, "team": { "key": "ENG" } }
        \\      ],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-label-2" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", two_on_a_page);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    // --all would otherwise run to the end; --max-items still stops it mid-page.
    var args = [_][]const u8{ "--limit", "2", "--max-items", "1", "--all", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("label-1\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "labels list: fetched 1 items across 1 page; more available, resume with --cursor cursor-label-2\n" ++
            "labels list: stopped after 1 items due to --max-items\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "labels list resumes from a cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLabels", labels_page2);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--cursor", "cursor-label-1", "--limit", "1", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("label-2\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-label-1\"") != null);
}

test "labels list rejects --all with --pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--all", "--pages", "2" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runLabels);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr, "labels list: ConflictingPageFlags\n"));
    try std.testing.expectEqual(@as(usize, 0), server.request_count);

    const conflicting = [_][]const u8{ "--all", "--pages", "2" };
    try std.testing.expectError(error.ConflictingPageFlags, labels_cmd.parseOptions(conflicting[0..]));
}

test "users list renders table with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // The mock replays a canned payload regardless of the filter, so the active
    // filter itself is asserted separately against the recorded variables.
    try server.set("Users", fixtures.users_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.users_table, capture.stdout);
    try std.testing.expectEqualStrings("users list: fetched 3 items across 1 page\n", capture.stderr);
}

test "users list prints json output with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Users", fixtures.users_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const users_obj = root.object.get("users") orelse return error.TestExpectedResult;
    if (users_obj != .object) return error.TestExpectedResult;
    const nodes = users_obj.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nodes.array.items.len);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Users", recorded.operation);
}

test "users list projects selected fields with data-only json" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Users", fixtures.users_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,active", "--data-only" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const nodes = root.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nodes.array.items.len);

    const first = nodes.array.items[0];
    if (first != .object) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 2), first.object.count());
    const id_value = first.object.get("id") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("user-1", id_value.string);
    const active_value = first.object.get("active") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("true", active_value.string);
    try std.testing.expect(first.object.get("email") == null);

    const last = nodes.array.items[2];
    if (last != .object) return error.TestExpectedResult;
    const last_active = last.object.get("active") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("false", last_active.string);
}

test "users list rejects invalid fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Users", fixtures.users_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "nope" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings("users list: invalid --fields value\n", capture.stderr);
}

test "users list defaults to active members and opts in with include-inactive" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Users", fixtures.users_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    {
        var args = [_][]const u8{"--quiet"};
        const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };
        const capture = try captureOutput(allocator, &runner, runUsers);
        defer capture.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

        const recorded = server.lastRequest() orelse return error.TestExpectedResult;
        const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
        defer parsed.deinit();
        const vars = parsed.value;
        if (vars != .object) return error.TestExpectedResult;
        const filter = vars.object.get("filter") orelse return error.TestExpectedResult;
        if (filter != .object) return error.TestExpectedResult;
        const active_filter = filter.object.get("active") orelse return error.TestExpectedResult;
        if (active_filter != .object) return error.TestExpectedResult;
        const eq_value = active_filter.object.get("eq") orelse return error.TestExpectedResult;
        if (eq_value != .bool) return error.TestExpectedResult;
        try std.testing.expect(eq_value.bool);
    }

    {
        var args = [_][]const u8{ "--quiet", "--include-inactive" };
        const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };
        const capture = try captureOutput(allocator, &runner, runUsers);
        defer capture.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

        const recorded = server.lastRequest() orelse return error.TestExpectedResult;
        const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
        defer parsed.deinit();
        const vars = parsed.value;
        if (vars != .object) return error.TestExpectedResult;
        try std.testing.expect(vars.object.get("filter") == null);
    }
}

test "parse users list options" {
    const args = [_][]const u8{ "--limit", "10", "--include-inactive", "--fields=id,email", "--data-only" };
    const opts = try users_cmd.parseOptions(args[0..]);
    try std.testing.expectEqual(@as(usize, 10), opts.limit);
    try std.testing.expect(opts.include_inactive);
    try std.testing.expectEqualStrings("id,email", opts.fields.?);
    try std.testing.expect(opts.data_only);
    try std.testing.expect(!opts.quiet);

    const defaults = [_][]const u8{};
    const default_opts = try users_cmd.parseOptions(defaults[0..]);
    try std.testing.expectEqual(@as(usize, 50), default_opts.limit);
    try std.testing.expect(!default_opts.include_inactive);

    const unknown = [_][]const u8{"--inactive"};
    try std.testing.expectError(error.UnknownFlag, users_cmd.parseOptions(unknown[0..]));
}

/// One user per page so a two-entry sequence exercises a real cursor hand-off.
const users_page1 =
    \\{
    \\  "data": {
    \\    "users": {
    \\      "nodes": [ { "id": "user-1", "name": "Ada Lovelace", "displayName": "ada", "email": "ada@example.com", "active": true } ],
    \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-user-1" }
    \\    }
    \\  }
    \\}
;
const users_page2 =
    \\{
    \\  "data": {
    \\    "users": {
    \\      "nodes": [ { "id": "user-2", "name": "Grace Hopper", "displayName": "grace", "email": "grace@example.com", "active": true } ],
    \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-user-2" }
    \\    }
    \\  }
    \\}
;

test "users list walks multiple pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Users", &.{ users_page1, users_page2 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "1", "--pages", "2", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("user-1\nuser-2\n", capture.stdout);
    try std.testing.expectEqualStrings("users list: fetched 2 items across 2 pages\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-user-1\"") != null);
    // The active-member filter survives the second request.
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"active\":{\"eq\":true}") != null);
}

test "users list truncates at max-items" {
    const allocator = std.testing.allocator;
    const two_on_a_page =
        \\{
        \\  "data": {
        \\    "users": {
        \\      "nodes": [
        \\        { "id": "user-1", "name": "Ada Lovelace", "displayName": "ada", "email": "ada@example.com", "active": true },
        \\        { "id": "user-2", "name": "Grace Hopper", "displayName": "grace", "email": "grace@example.com", "active": true }
        \\      ],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-user-2" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Users", two_on_a_page);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "2", "--max-items", "1", "--all", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("user-1\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "users list: fetched 1 items across 1 page; more available, resume with --cursor cursor-user-2\n" ++
            "users list: stopped after 1 items due to --max-items\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "users list resumes from a cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Users", users_page2);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--cursor", "cursor-user-1", "--limit", "1", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("user-2\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-user-1\"") != null);
}

test "users list rejects --all with --pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--all", "--pages", "2" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runUsers);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr, "users list: ConflictingPageFlags\n"));
    try std.testing.expectEqual(@as(usize, 0), server.request_count);

    const conflicting = [_][]const u8{ "--all", "--pages", "2" };
    try std.testing.expectError(error.ConflictingPageFlags, users_cmd.parseOptions(conflicting[0..]));
}

test "states list renders table with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.states_table, capture.stdout);
    try std.testing.expectEqualStrings("states list: fetched 4 items across 1 page\n", capture.stderr);
}

test "states list prints json output with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const states_obj = root.object.get("workflowStates") orelse return error.TestExpectedResult;
    if (states_obj != .object) return error.TestExpectedResult;
    const nodes = states_obj.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 4), nodes.array.items.len);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("WorkflowStates", recorded.operation);
}

test "states list projects selected fields with data-only" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,position", "--data-only" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // Position is a GraphQL Float, so integral and fractional values both render.
    try std.testing.expectEqualStrings(
        "state-1\t0\nstate-2\t1\nstate-3\t2.5\nstate-4\t3\n",
        capture.stdout,
    );
}

test "states list renders team column for states from several teams" {
    const allocator = std.testing.allocator;

    // Without --team the query spans every team, so two identically named
    // states are only distinguishable by their team key.
    const multi_team_payload =
        \\{
        \\  "data": {
        \\    "workflowStates": {
        \\      "nodes": [
        \\        { "id": "state-eng-3", "name": "In Progress", "type": "started", "position": 2, "team": { "key": "ENG" } },
        \\        { "id": "state-des-3", "name": "In Progress", "type": "started", "position": 2, "team": { "key": "DES" } }
        \\      ],
        \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-state-des-3" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", multi_team_payload);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{};
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "ID           Name         Type     Position  Team\n" ++
            "state-eng-3  In Progress  started  2         ENG \n" ++
            "state-des-3  In Progress  started  2         DES \n",
        capture.stdout,
    );
    try std.testing.expectEqualStrings("states list: fetched 2 items across 1 page\n", capture.stderr);

    // The team key only arrives if the selection set asks for it.
    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, recorded.query, "team { key }") != null);
}

test "states list projects team field with data-only" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,team", "--data-only" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "state-1\tENG\nstate-2\tENG\nstate-3\tENG\nstate-4\tENG\n",
        capture.stdout,
    );
}

test "states list omits team column when fields exclude it" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,name" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "ID       Name       \n" ++
            "state-1  Backlog    \n" ++
            "state-2  Todo       \n" ++
            "state-3  In Progress\n" ++
            "state-4  Done       \n",
        capture.stdout,
    );
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "Team") == null);
}

test "states list rejects invalid fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--fields", "id,color" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings("states list: invalid --fields value\n", capture.stderr);
}

test "states list filters by team uuid" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", fixtures.states_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const team_uuid = "69525da9-b8a9-4f58-a7b9-4187aaf9e02a";
    var args = [_][]const u8{ "--team", team_uuid };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const filter = vars.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;
    const team_filter = filter.object.get("team") orelse return error.TestExpectedResult;
    if (team_filter != .object) return error.TestExpectedResult;
    const id_filter = team_filter.object.get("id") orelse return error.TestExpectedResult;
    if (id_filter != .object) return error.TestExpectedResult;
    const eq_value = id_filter.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings(team_uuid, eq_value.string);
    try std.testing.expect(team_filter.object.get("key") == null);
}

test "parse states list options" {
    const args = [_][]const u8{ "--team=ENG", "--limit", "5", "--fields", "id,name,type,position", "--plain" };
    const opts = try states_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG", opts.team.?);
    try std.testing.expectEqual(@as(usize, 5), opts.limit);
    try std.testing.expectEqualStrings("id,name,type,position", opts.fields.?);
    try std.testing.expect(opts.plain);

    const help = [_][]const u8{"-h"};
    const help_opts = try states_cmd.parseOptions(help[0..]);
    try std.testing.expect(help_opts.help);

    const positional = [_][]const u8{"ENG"};
    try std.testing.expectError(error.UnexpectedArgument, states_cmd.parseOptions(positional[0..]));
}

/// One state per page so a two-entry sequence exercises a real cursor hand-off.
const states_page1 =
    \\{
    \\  "data": {
    \\    "workflowStates": {
    \\      "nodes": [ { "id": "state-1", "name": "Backlog", "type": "backlog", "position": 0, "team": { "key": "ENG" } } ],
    \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-state-1" }
    \\    }
    \\  }
    \\}
;
const states_page2 =
    \\{
    \\  "data": {
    \\    "workflowStates": {
    \\      "nodes": [ { "id": "state-2", "name": "Todo", "type": "unstarted", "position": 1, "team": { "key": "ENG" } } ],
    \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-state-2" }
    \\    }
    \\  }
    \\}
;

test "states list walks multiple pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("WorkflowStates", &.{ states_page1, states_page2 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "1", "--pages", "2", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("state-1\nstate-2\n", capture.stdout);
    try std.testing.expectEqualStrings("states list: fetched 2 items across 2 pages\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-state-1\"") != null);
}

test "states list truncates at max-items" {
    const allocator = std.testing.allocator;
    const two_on_a_page =
        \\{
        \\  "data": {
        \\    "workflowStates": {
        \\      "nodes": [
        \\        { "id": "state-1", "name": "Backlog", "type": "backlog", "position": 0, "team": { "key": "ENG" } },
        \\        { "id": "state-2", "name": "Todo", "type": "unstarted", "position": 1, "team": { "key": "ENG" } }
        \\      ],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-state-2" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", two_on_a_page);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "2", "--max-items", "1", "--all", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("state-1\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "states list: fetched 1 items across 1 page; more available, resume with --cursor cursor-state-2\n" ++
            "states list: stopped after 1 items due to --max-items\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "states list resumes from a cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("WorkflowStates", states_page2);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--cursor", "cursor-state-1", "--limit", "1", "--quiet" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("state-2\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-state-1\"") != null);
}

test "states list rejects --all with --pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--all", "--pages", "2" };
    const runner = EnumRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runStates);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr, "states list: ConflictingPageFlags\n"));
    try std.testing.expectEqual(@as(usize, 0), server.request_count);

    const conflicting = [_][]const u8{ "--all", "--pages", "2" };
    try std.testing.expectError(error.ConflictingPageFlags, states_cmd.parseOptions(conflicting[0..]));
}

test "me prints viewer table with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Viewer", fixtures.viewer_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runViewer = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{};
            return me_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runViewer);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.viewer_table, capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issue create succeeds with quiet output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueCreate", fixtures.issue_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--team",
                "123e4567-e89b-12d3-a456-426614174000",
                "--title",
                "Example created issue",
                "--yes",
                "--quiet",
            };
            return issue_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("LIN-200\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issue create requires confirmation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--team", "ENG", "--title", "Needs confirmation" };
            return issue_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "issue create reports user error" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "issueCreate": {
        \\      "success": false,
        \\      "issue": null,
        \\      "userError": "permission denied",
        \\      "lastSyncId": 0
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);
    try server.set("IssueCreate", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--team", "ENG", "--title", "Example created issue", "--yes" };
            return issue_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "permission denied") != null);
}

test "issue create data-only json output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);
    try server.set("IssueCreate", fixtures.issue_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--team", "ENG", "--title", "Example created issue", "--yes", "--data-only" };
            return issue_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    const expected =
        \\{
        \\  "identifier": "LIN-200",
        \\  "title": "Example created issue",
        \\  "url": "https://linear.app/example/issue/200"
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, capture.stdout);
}

test "issue delete prints identifier and id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDelete", fixtures.issue_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-300", "--yes" };
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("Identifier: LIN-300\nID        : issue-del-1\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issue delete requires target" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDelete", fixtures.issue_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{};
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "missing identifier") != null);
}

test "issue delete rejects --reason" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDelete", fixtures.issue_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    // `issueDelete` accepts `(id, permanentlyDelete)` and nothing else, so a
    // reason could never have reached Linear. It was echoed back into this
    // CLI's own output, which read exactly like an audit trail that existed.
    // Removed outright rather than deprecated, the way `--api-key` was.
    const forms = [_][]const []const u8{
        &.{ "LIN-300", "--yes", "--reason", "duplicate" },
        &.{ "LIN-300", "--yes", "--reason=duplicate" },
    };

    for (forms) |form| {
        const Runner = struct {
            allocator: std.mem.Allocator,
            cfg: *config.Config,
            args: []const []const u8,
        };
        const runDelete = struct {
            pub fn call(r: *const Runner) !u8 {
                const args = try r.allocator.alloc([]const u8, r.args.len);
                defer r.allocator.free(args);
                for (r.args, 0..) |arg, idx| args[idx] = arg;
                return issue_delete_cmd.run(.{
                    .allocator = r.allocator,
                    .io = test_io,
                    .config = r.cfg,
                    .args = args,
                    .retries = 0,
                    .timeout_ms = 10_000,
                    .json_output = false,
                });
            }
        }.call;
        const runner = Runner{ .allocator = allocator, .cfg = &cfg, .args = form };

        const capture = try captureOutput(allocator, &runner, runDelete);
        defer capture.deinit(allocator);

        try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "UnknownFlag") != null);
        try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "--reason") == null);
        try std.testing.expectEqualStrings("", capture.stdout);
    }

    // Rejected during flag parsing, so no mutation was ever attempted.
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "issue delete usage no longer advertises --reason" {
    const allocator = std.testing.allocator;

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try issue_delete_cmd.usage(&buffer.writer);

    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "--reason") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "--dry-run") != null);
}

test "issue delete dry run validates without mutation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDeleteLookup", fixtures.issue_delete_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-300", "--dry-run" };
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "dry run") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "LIN-300") != null);
}

test "issue delete dry run emits json" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDeleteLookup", fixtures.issue_delete_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-300", "--dry-run" };
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "\"dry_run\": true") != null);
}

test "issue delete data-only plain output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDelete", fixtures.issue_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-300", "--yes", "--data-only" };
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout, "identifier\tLIN-300"));
}

test "issue delete reports failure" {
    const allocator = std.testing.allocator;
    const failure_payload =
        \\{
        \\  "data": {
        \\    "issueDelete": {
        \\      "success": false,
        \\      "entity": { "identifier": "LIN-300", "id": "issue-del-1" },
        \\      "lastSyncId": 0
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDelete", failure_payload);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-300", "--yes" };
            return issue_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "delete failed") != null);
}

test "issue update succeeds with quiet output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--priority", "1", "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("LIN-123\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issue update requires confirmation" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--priority", "1" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "issue update requires at least one field" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--yes" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "at least one field") != null);
}

test "issue update with assignee me resolves viewer" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // The viewer query runs first to resolve "me", then the update mutation
    try server.set("Viewer", fixtures.viewer_response);
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--assignee", "me", "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("LIN-123\n", capture.stdout);
}

test "issue update reports user error" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "issueUpdate": {
        \\      "success": false,
        \\      "issue": null,
        \\      "userError": "permission denied"
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--priority", "1", "--yes" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "permission denied") != null);
}

test "issue update resolves workflow state name" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStateLookup", fixtures.issue_state_lookup_response);
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--state", "done", "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const state_value = input.object.get("stateId") orelse return error.TestExpectedResult;
    if (state_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("69525da9-b8a9-4f58-a7b9-4187aaf9e02a", state_value.string);
}

test "issue update resolves a parent identifier to an issue id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--parent", "LIN-100", "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueUpdate", recorded.operation);
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const parent_value = input.object.get("parentId") orelse return error.TestExpectedResult;
    if (parent_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("issue-1", parent_value.string);
}

test "issue update passes a parent id through without a lookup" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // No IssueLookup fixture: a real id must not trigger the resolution query.
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const parent_uuid = "69525da9-b8a9-4f58-a7b9-4187aaf9e02a";
    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
        parent: []const u8,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--parent", r.parent, "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg, .parent = parent_uuid };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueUpdate", recorded.operation);
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const parent_value = input.object.get("parentId") orelse return error.TestExpectedResult;
    if (parent_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings(parent_uuid, parent_value.string);
}

test "issue update reports missing workflow state name" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStateLookup", fixtures.issue_state_lookup_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--state", "waiting", "--yes" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "state 'waiting' not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "In Progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "Backlog") != null);
    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueStateLookup", recorded.operation);
}

test "issue update data-only json output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--priority", "1", "--yes", "--data-only" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "\"identifier\": \"LIN-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "\"state\": \"In Progress\"") != null);
}

test "issue link succeeds with quiet output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("IssueRelationCreate", fixtures.issue_link_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--blocks", "LIN-456", "--yes", "--quiet" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("relation-1\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issue link requires confirmation" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--blocks", "LIN-456" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "issue link requires exactly one relation type" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--yes" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "exactly one of --blocks") != null);
}

test "issue link rejects multiple relation types" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--blocks", "LIN-456", "--related", "LIN-789", "--yes" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "only one of --blocks") != null);
}

test "issue link data-only json output" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("IssueRelationCreate", fixtures.issue_link_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--blocks", "LIN-456", "--yes", "--data-only" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "\"id\": \"relation-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "\"type\": \"blocks\"") != null);
}

test "issue link reports user error" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "issueRelationCreate": {
        \\      "success": false,
        \\      "issueRelation": null,
        \\      "userError": "relation already exists"
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("IssueRelationCreate", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--blocks", "LIN-456", "--yes" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "relation already exists") != null);
}

test "issue link lookup trims identifiers and accepts direct target ids" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueLookup", &.{ fixtures.issue_lookup_response, fixtures.issue_lookup_response, fixtures.issue_lookup_response });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ " ENG-123 ", "--related", "iss_target_123", "--yes" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "invalid issue identifier") == null);

    const lookup_series = server.fixtures.getPtr("IssueLookup") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), lookup_series.*.next);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueLookup", recorded.operation);

    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;

    const filter = root.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;

    const team_obj = filter.object.get("team") orelse return error.TestExpectedResult;
    if (team_obj != .object) return error.TestExpectedResult;
    const key_obj = team_obj.object.get("key") orelse return error.TestExpectedResult;
    if (key_obj != .object) return error.TestExpectedResult;
    const eq_key = key_obj.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_key != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ENG", eq_key.string);

    const number_obj = filter.object.get("number") orelse return error.TestExpectedResult;
    if (number_obj != .object) return error.TestExpectedResult;
    const eq_number = number_obj.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_number != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 123), eq_number.integer);
}

test "issue link lookup validates target payload and accepts cuid ids" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueLookup", &.{ fixtures.issue_lookup_response, fixtures.issue_lookup_response, fixtures.issue_lookup_response });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runLink = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ckopq3f5u00012qqqs64aqkef", "--blocks", " LIN-456 ", "--yes" };
            return issue_link_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runLink);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "invalid issue identifier") == null);

    const lookup_series = server.fixtures.getPtr("IssueLookup") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), lookup_series.*.next);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueLookup", recorded.operation);

    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;

    const filter = root.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;

    const team_obj = filter.object.get("team") orelse return error.TestExpectedResult;
    if (team_obj != .object) return error.TestExpectedResult;
    const key_obj = team_obj.object.get("key") orelse return error.TestExpectedResult;
    if (key_obj != .object) return error.TestExpectedResult;
    const eq_key = key_obj.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_key != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("LIN", eq_key.string);

    const number_obj = filter.object.get("number") orelse return error.TestExpectedResult;
    if (number_obj != .object) return error.TestExpectedResult;
    const eq_number = number_obj.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_number != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 456), eq_number.integer);
}

test "issue view filters fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-500", "--fields", "identifier,title", "--data-only" };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("{\n  \"identifier\": \"LIN-500\",\n  \"title\": \"Example issue\"\n}\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "issue view includes project and milestone fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_project);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-500", "--fields", "project,milestone", "--data-only" };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const project_field = root.object.get("project") orelse return error.TestExpectedResult;
    const milestone_field = root.object.get("milestone") orelse return error.TestExpectedResult;
    if (project_field != .string or milestone_field != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Offline Project", project_field.string);
    try std.testing.expectEqualStrings("Offline Milestone", milestone_field.string);
}

test "issue view requires identifier" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{};
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "missing identifier") != null);
}

test "issue view rejects invalid fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-500", "--fields", "unknown" };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "invalid --fields") != null);
}

test "issue view quiet prints identifier" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-500", "--quiet" };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("LIN-500\n", capture.stdout);
}

test "issue view reports missing issue" {
    const allocator = std.testing.allocator;
    const missing_payload =
        \\{
        \\  "data": {
        \\    "issue": null
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", missing_payload);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{"LIN-500"};
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "issue not found") != null);
}

test "issue view includes parent and sub-issues with limit" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_relations);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-600", "--fields", "identifier,parent,sub_issues", "--data-only", "--sub-limit", "1" };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const parent_field = root.object.get("parent") orelse return error.TestExpectedResult;
    if (parent_field != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("LIN-500", parent_field.string);
    const subs_field = root.object.get("sub_issue_identifiers") orelse return error.TestExpectedResult;
    if (subs_field != .string) return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, subs_field.string, "LIN-601") != null);
    try std.testing.expect(subs_field.string.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "sub-issues limited") != null);
}

test "issue view includes comments with limit" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_comments);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-700", "--fields", "identifier,comments", "--data-only", "--comment-limit", "1" };
            return issue_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.TestExpectedResult;
    const comments_field = root.object.get("comments") orelse return error.TestExpectedResult;
    if (comments_field != .array) return error.TestExpectedResult;
    try std.testing.expect(comments_field.array.items.len > 0);
    const first_comment = comments_field.array.items[0];
    if (first_comment != .object) return error.TestExpectedResult;
    const body_field = first_comment.object.get("body") orelse return error.TestExpectedResult;
    if (body_field != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("First comment body", body_field.string);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "comments limited") != null);
}

test "project create uses teamIds array" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);
    try server.set("ProjectCreate", fixtures.project_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--name", "New Project", "--team", "ENG", "--yes" };
            return project_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ProjectCreate", recorded.operation);
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const team_ids = input.object.get("teamIds") orelse return error.TestExpectedResult;
    if (team_ids != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), team_ids.array.items.len);
    const first = team_ids.array.items[0];
    if (first != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("team-id-123", first.string);
    try std.testing.expect(input.object.get("teamId") == null);
}

test "project create requires confirmation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--name", "New Project", "--team", "ENG" };
            return project_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "projects list renders rows and reports the resume cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Projects", fixtures.projects_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runProjects = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{};
            return projects_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runProjects);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "Roadmap") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "API revamp") != null);
    try std.testing.expectEqualStrings(
        "projects list: fetched 2 items across 1 page; more available, resume with --cursor cursor-123\n",
        capture.stderr,
    );
}

test "projects list maps state filter to status id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectStatuses", fixtures.project_statuses_response);
    try server.set("Projects", fixtures.projects_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runProjects = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--state", "started" };
            return projects_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runProjects);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Projects", recorded.operation);
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const filter = vars.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;
    const status_filter = filter.object.get("status") orelse return error.TestExpectedResult;
    if (status_filter != .object) return error.TestExpectedResult;
    const id_filter = status_filter.object.get("id") orelse return error.TestExpectedResult;
    if (id_filter != .object) return error.TestExpectedResult;
    const eq_value = id_filter.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("status_started", eq_value.string);
    try std.testing.expect(filter.object.get("statusId") == null);
    try std.testing.expect(filter.object.get("state") == null);
}

test "projects list maps team filter to accessibleTeams some filter" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Projects", fixtures.projects_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runProjects = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "--team", "ENG" };
            return projects_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runProjects);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Projects", recorded.operation);
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const filter = vars.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;
    const teams_filter = filter.object.get("accessibleTeams") orelse return error.TestExpectedResult;
    if (teams_filter != .object) return error.TestExpectedResult;
    const some_filter = teams_filter.object.get("some") orelse return error.TestExpectedResult;
    if (some_filter != .object) return error.TestExpectedResult;
    const key_filter = some_filter.object.get("key") orelse return error.TestExpectedResult;
    if (key_filter != .object) return error.TestExpectedResult;
    const eq_value = key_filter.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ENG", eq_value.string);
    try std.testing.expect(filter.object.get("team") == null);
}

/// `projects list` has no `--quiet`, so its pagination cases project down to the
/// id column and assert the rendered table instead.
const ProjectsRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    json_output: bool = false,
};

fn runProjectsList(r: *const ProjectsRunner) !u8 {
    return projects_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

/// One project per page so a two-entry sequence exercises a real cursor hand-off.
const projects_page1 =
    \\{
    \\  "data": {
    \\    "projects": {
    \\      "nodes": [ { "id": "proj_1", "name": "Roadmap", "slugId": "roadmap", "description": null,
    \\                   "state": "started", "startDate": null, "targetDate": null, "url": "https://linear.app/roadmap" } ],
    \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-proj-1" }
    \\    }
    \\  }
    \\}
;
const projects_page2 =
    \\{
    \\  "data": {
    \\    "projects": {
    \\      "nodes": [ { "id": "proj_2", "name": "API revamp", "slugId": "api", "description": null,
    \\                   "state": "planned", "startDate": null, "targetDate": null, "url": "https://linear.app/api" } ],
    \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-proj-2" }
    \\    }
    \\  }
    \\}
;

test "projects list walks multiple pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Projects", &.{ projects_page1, projects_page2 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "1", "--pages", "2", "--fields", "id" };
    const runner = ProjectsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectsList);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // Page one's row is still intact after page two was parsed.
    try std.testing.expectEqualStrings("ID    \nproj_1\nproj_2\n", capture.stdout);
    try std.testing.expectEqualStrings("projects list: fetched 2 items across 2 pages\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-proj-1\"") != null);
}

test "projects list truncates at max-items" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // The stock fixture has two nodes and hasNextPage true.
    try server.set("Projects", fixtures.projects_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--limit", "2", "--max-items", "1", "--all", "--fields", "id" };
    const runner = ProjectsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectsList);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ID      \nproj_123\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "projects list: fetched 1 items across 1 page; more available, resume with --cursor cursor-123\n" ++
            "projects list: stopped after 1 items due to --max-items\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "projects list resumes from a cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Projects", projects_page2);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--cursor", "cursor-proj-1", "--limit", "1", "--fields", "id" };
    const runner = ProjectsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectsList);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ID    \nproj_2\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-proj-1\"") != null);
}

test "projects list rejects --all with --pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--all", "--pages", "2" };
    const runner = ProjectsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectsList);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr, "projects list: ConflictingPageFlags\n"));
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "project view prints teams and truncated issues warning" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectView", fixtures.project_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runView = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "proj_123", "--fields", "name,teams,issues", "--issue-limit", "1" };
            return project_view_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runView);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "Roadmap") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "ENG (Engineering), DS (Data Science)") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "ENG-10 Kickoff, ENG-20 Ship v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "issues limited to 1") != null);
}

test "project update requires at least one field" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{"proj_123"};
            return project_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "at least one field") != null);
}

test "project update quiet output and payload" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectStatuses", fixtures.project_statuses_response);
    try server.set("ProjectUpdate", fixtures.project_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "proj_123", "--name", "Renamed Roadmap", "--state", "started", "--yes", "--quiet" };
            return project_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("roadmap\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const name_value = input.object.get("name") orelse return error.TestExpectedResult;
    if (name_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("Renamed Roadmap", name_value.string);
    const status_id_value = input.object.get("statusId") orelse return error.TestExpectedResult;
    if (status_id_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("status_started", status_id_value.string);
    try std.testing.expect(input.object.get("description") == null);
}

test "project delete requires confirmation" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{"proj_123"};
            return project_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "project delete prints archive message" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectDelete", fixtures.project_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runDelete = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "proj_123", "--yes" };
            return project_delete_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("project delete: archived proj_123\n", capture.stdout);
}

test "project add-issue sets project id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.project_add_issue_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runAdd = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "add-issue", "proj_123", "ENG-42", "--yes" };
            return project_issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runAdd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "Roadmap") != null);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const project_value = input.object.get("projectId") orelse return error.TestExpectedResult;
    if (project_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("proj_123", project_value.string);
}

test "project remove-issue clears project id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.project_remove_issue_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runRemove = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "remove-issue", "proj_123", "ENG-42", "--yes", "--data-only" };
            return project_issues_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runRemove);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "\"project\": \"proj_123\"") != null);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const project_value = input.object.get("projectId") orelse return error.TestExpectedResult;
    try std.testing.expect(project_value == .null);
}

test "issue create sets projectId when provided" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueCreate", fixtures.issue_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runCreate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "--team",
                "123e4567-e89b-12d3-a456-426614174000",
                "--title",
                "Example created issue",
                "--project",
                "proj_123",
                "--yes",
            };
            return issue_create_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runCreate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const project_value = input.object.get("projectId") orelse return error.TestExpectedResult;
    if (project_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("proj_123", project_value.string);
}

test "issue update sets projectId when provided" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--project", "proj_123", "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const project_value = input.object.get("projectId") orelse return error.TestExpectedResult;
    if (project_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("proj_123", project_value.string);
}

test "issue update sets description when provided" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runUpdate = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "LIN-123", "--description", "New description", "--yes", "--quiet" };
            return issue_update_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runUpdate);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    const input = vars.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    const description_value = input.object.get("description") orelse return error.TestExpectedResult;
    if (description_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings("New description", description_value.string);
}

test "graphql client reuses shared http client across instances" {
    const allocator = std.testing.allocator;

    var first = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    const first_http = first.http_client;
    first.deinit();

    defer graphql.deinitSharedClient(test_io);
    var second = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    defer second.deinit();

    try std.testing.expect(first_http == second.http_client);
}

test "graphql client refreshes tls certs when reused" {
    const allocator = std.testing.allocator;

    var first = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    const shared = first.http_client;
    shared.now = .zero;
    first.deinit();

    defer graphql.deinitSharedClient(test_io);
    var second = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    defer second.deinit();

    try std.testing.expect(second.http_client.now == null);
}

test "graphql client uses configured keep alive setting" {
    const allocator = std.testing.allocator;
    const previous = graphql.getDefaultKeepAlive();
    graphql.setDefaultKeepAlive(false);
    defer graphql.setDefaultKeepAlive(previous);
    defer graphql.deinitSharedClient(test_io);

    var client = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    defer client.deinit();

    try std.testing.expect(!client.keep_alive);
}

test "issue comment succeeds with body" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("CommentCreate", fixtures.comment_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runComment = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ENG-123", "--body", "Test comment", "--yes" };
            return issue_comment_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runComment);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "ENG-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "comment-1") != null);
}

test "issue comment reports user error" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "commentCreate": {
        \\      "success": false,
        \\      "comment": null,
        \\      "userError": "permission denied"
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("CommentCreate", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runComment = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ENG-123", "--body", "Test comment", "--yes" };
            return issue_comment_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runComment);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "permission denied") != null);
}

test "issue comment fails with json output when success is false" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "commentCreate": {
        \\      "success": false,
        \\      "comment": null,
        \\      "userError": "rate limited"
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("CommentCreate", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runComment = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ENG-123", "--body", "Test comment", "--yes" };
            return issue_comment_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = true,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runComment);
    defer capture.deinit(allocator);

    // Key assertion: even with json_output=true, exit code is 1 when success is false
    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "rate limited") != null);
}

test "issue comment requires confirmation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runComment = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ENG-123", "--body", "Test comment" };
            return issue_comment_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runComment);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "issue comment requires body or body-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runComment = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ENG-123", "--yes" };
            return issue_comment_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runComment);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "--body or --body-file is required") != null);
}

test "issue comment rejects both body and body-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runComment = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "ENG-123", "--body", "text", "--body-file", "file.md", "--yes" };
            return issue_comment_cmd.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .retries = 0,
                .timeout_ms = 10_000,
                .json_output = false,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runComment);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "cannot use both --body and --body-file") != null);
}

// ---------------------------------------------------------------------------
// Security regressions
// ---------------------------------------------------------------------------

const fake_api_key = "linapi0123456789wxyz";
const fake_api_key_redacted = "lina...wxyz";

const AuthRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: []const []const u8,
    json_output: bool = false,
    config_path: ?[]const u8 = null,
    /// `null` keeps the command inert: nothing spawns unless a test installs a
    /// fake, and no test ever runs a real `op` or `security`.
    credential_runner: ?git.Runner = null,
};

fn runAuth(r: *const AuthRunner) !u8 {
    const args = try r.allocator.alloc([]const u8, r.args.len);
    defer r.allocator.free(args);
    for (r.args, 0..) |arg, idx| args[idx] = arg;

    return auth_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = args,
        .json_output = r.json_output,
        .config_path = r.config_path,
        .retries = 0,
        .timeout_ms = 10_000,
        .credential_runner = r.credential_runner,
    });
}

test "auth show redacts the api key by default" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();
    try cfg.setApiKey(fake_api_key);

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{"show"} };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_api_key_redacted) != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_api_key) == null);
}

test "auth show json output is redacted by default" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();
    try cfg.setApiKey(fake_api_key);

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{"show"}, .json_output = true };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_api_key_redacted) != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_api_key) == null);
}

test "auth show refuses to reveal the api key when stdout is not a tty" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();
    try cfg.setApiKey(fake_api_key);

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{ "show", "--reveal" } };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "refusing to reveal") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, fake_api_key) == null);
}

test "auth show keeps --redacted as a no-op alias" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();
    try cfg.setApiKey(fake_api_key);

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{ "show", "--redacted" } };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_api_key_redacted) != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_api_key) == null);
}

test "auth set rejects the removed --api-key flag" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{ "--api-key", fake_api_key },
    };
    const capture = try captureOutputWithStdin(allocator, &runner, runAuth, "");
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "unknown command: --api-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, fake_api_key) == null);

    const set_capture = try captureOutputWithStdin(allocator, &AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{ "set", "--api-key", fake_api_key },
    }, runAuth, "");
    defer set_capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), set_capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, set_capture.stderr, "UnknownFlag") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_capture.stderr, "--api-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, set_capture.stderr, fake_api_key) == null);
}

test "auth set stores a piped api key" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{"set"},
        .config_path = config_path,
    };
    const capture = try captureOutputWithStdin(allocator, &runner, runAuth, fake_api_key ++ "\n");
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "api key saved") != null);

    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings(fake_api_key, reloaded.api_key.?);
}

test "auth set rejects a piped key with invalid characters" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{"set"},
        .config_path = config_path,
    };
    const capture = try captureOutputWithStdin(allocator, &runner, runAuth, "abcd\rX-Evil: 1\n");
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "invalid API key") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(test_io, "config.json", .{}));
}

test "auth set refuses to persist a key that came from the environment" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    try setEnvValue("env-only-key", allocator);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("env-only-key", cfg.api_key.?);

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{"set"},
        .config_path = config_path,
    };
    const capture = try captureOutputWithStdin(allocator, &runner, runAuth, "");
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "no API key supplied") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(test_io, "config.json", .{}));
}

test "config save writes no api_key field when the key came from the environment" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    try setEnvValue("env-only-key", allocator);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.save(allocator, config_path);

    const contents = try tmp.dir.readFileAlloc(test_io, "config.json", allocator, .limited(4096));
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("api_key") == null);
    try std.testing.expect(parsed.value.object.get("default_state_filter") != null);
}

test "config save preserves the stored api key while LINEAR_API_KEY is set" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    {
        var seed = try config.load(allocator, test_io, testEnviron(), config_path);
        defer seed.deinit();
        try seed.setApiKey("file-key");
        try seed.save(allocator, config_path);
    }

    try setEnvValue("env-key", allocator);

    {
        var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
        defer cfg.deinit();
        try std.testing.expectEqualStrings("env-key", cfg.api_key.?);
        try cfg.setDefaultOutput("json");
        try cfg.save(allocator, config_path);
    }

    const contents = try tmp.dir.readFileAlloc(test_io, "config.json", allocator, .limited(4096));
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "env-key") == null);

    clearEnv();
    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("file-key", reloaded.api_key.?);
    try std.testing.expectEqualStrings("json", reloaded.default_output);
}

test "config save creates a 0600 file inside a 0700 directory" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const nested_path = try std.fs.path.join(allocator, &.{ dir_path, "nested" });
    defer allocator.free(nested_path);
    const config_path = try std.fs.path.join(allocator, &.{ nested_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey(fake_api_key);
    try cfg.save(allocator, config_path);

    const file = try std.Io.Dir.cwd().openFile(test_io, config_path, .{});
    defer file.close(test_io);
    const file_stat = try file.stat(test_io);
    try std.testing.expect((file_stat.permissions.toMode() & 0o777) == config.config_file_mode);

    var nested_dir = try std.Io.Dir.cwd().openDir(test_io, nested_path, .{});
    defer nested_dir.close(test_io);
    const dir_stat = try nested_dir.stat(test_io);
    try std.testing.expect((dir_stat.permissions.toMode() & 0o777) == config.config_dir_mode);
}

test "config rejects an api key with header injection characters" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    const file = try tmp.dir.createFile(test_io, "config.json", .{ .read = true, .truncate = true });
    defer file.close(test_io);
    try file.writeStreamingAll(test_io, "{\"api_key\":\"abcd\\r\\nX-Evil: 1\"}");

    try std.testing.expectError(
        error.InvalidApiKey,
        config.load(allocator, test_io, testEnviron(), config_path),
    );
}

test "config rejects an environment api key with invalid characters" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    try setEnvValue("bad key with spaces", allocator);

    try std.testing.expectError(
        error.InvalidApiKey,
        config.load(allocator, test_io, testEnviron(), config_path),
    );
}

test "isValidApiKey accepts realistic keys and rejects the rest" {
    try std.testing.expect(config.isValidApiKey("lin_api_abcDEF0123456789"));
    try std.testing.expect(config.isValidApiKey("file-key"));
    try std.testing.expect(!config.isValidApiKey(""));
    try std.testing.expect(!config.isValidApiKey("abc"));
    try std.testing.expect(!config.isValidApiKey("has space"));
    try std.testing.expect(!config.isValidApiKey("has\r\nnewline"));
    try std.testing.expect(!config.isValidApiKey("has:colon"));

    var long_key: [config.max_api_key_len + 1]u8 = undefined;
    @memset(&long_key, 'a');
    try std.testing.expect(!config.isValidApiKey(&long_key));
}

test "endpoint validation requires https and the linear host" {
    try graphql.validateEndpoint(graphql.default_endpoint, false);
    try std.testing.expectError(
        error.InsecureEndpointScheme,
        graphql.validateEndpoint("http://api.linear.app/graphql", false),
    );
    try std.testing.expectError(
        error.EndpointHostNotAllowed,
        graphql.validateEndpoint("https://evil.example.com/graphql", false),
    );
    try std.testing.expectError(
        error.EndpointHostNotAllowed,
        graphql.validateEndpoint("https://api.linear.app.evil.example.com/graphql", false),
    );
    try std.testing.expectError(
        error.EndpointHostNotAllowed,
        graphql.validateEndpoint("https://api.linear.app@evil.example.com/graphql", false),
    );
    try std.testing.expectError(
        error.InvalidEndpointUrl,
        graphql.validateEndpoint("not-a-url", false),
    );
}

test "endpoint validation opt-in allows a local mock endpoint" {
    try graphql.validateEndpoint("http://127.0.0.1:4000/graphql", true);
    try graphql.validateEndpoint("https://mock.internal/graphql", true);
    try std.testing.expectError(
        error.InvalidEndpointUrl,
        graphql.validateEndpoint("nonsense", true),
    );
}

test "graphql client defaults to the strict endpoint allowlist" {
    const allocator = std.testing.allocator;
    const previous = graphql.getAllowInsecureEndpoint();
    defer graphql.setAllowInsecureEndpoint(previous);
    defer graphql.deinitSharedClient(test_io);

    graphql.setAllowInsecureEndpoint(false);
    var strict = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    try std.testing.expect(!strict.allow_insecure_endpoint);
    strict.deinit();

    graphql.setAllowInsecureEndpoint(true);
    var permissive = graphql.GraphqlClient.init(allocator, test_io, "test-key");
    defer permissive.deinit();
    try std.testing.expect(permissive.allow_insecure_endpoint);
}

test "gql detects mutation operations" {
    try std.testing.expect(gql.isMutation("mutation { issueDelete(id: \"x\") { success } }"));
    try std.testing.expect(gql.isMutation("  \n\t mutation Foo { issueDelete(id: \"x\") { success } }"));
    try std.testing.expect(gql.isMutation("# comment\n# mutation in a comment is ignored\nmutation Foo {\n  issueDelete(id: \"x\") { success }\n}"));
    try std.testing.expect(gql.isMutation("query Q { viewer { id } }\nmutation M { issueDelete(id: \"x\") { success } }"));
    try std.testing.expect(gql.isMutation("mutation{issueDelete(id:\"x\"){success}}"));

    try std.testing.expect(!gql.isMutation("query { viewer { id } }"));
    try std.testing.expect(!gql.isMutation("{ viewer { id } }"));
    try std.testing.expect(!gql.isMutation("# mutation { issueDelete }\nquery { viewer { id } }"));
    try std.testing.expect(!gql.isMutation("query Q { issue(id: \"x\") { mutation } }"));
    try std.testing.expect(!gql.isMutation("query Q($note: String = \"mutation\") { viewer { id } }"));
    try std.testing.expect(!gql.isMutation("query Q { issue(id: \"x\") { description } }\n\"\"\"\nmutation\n\"\"\""));
    try std.testing.expect(!gql.isMutation("query Q { mutationCount }"));
}

test "gql requires confirmation before running a mutation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "mutation IssueDelete { issueDelete(id: \"abc\") { success } }",
                "--operation-name",
                "IssueDelete",
            };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required; re-run with --yes to proceed") != null);
}

test "gql runs a mutation once --yes is provided" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueDelete", fixtures.issue_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "mutation IssueDelete { issueDelete(id: \"abc\") { success } }",
                "--operation-name",
                "IssueDelete",
                "--yes",
                "--data-only",
            };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "issueDelete") != null);
    try std.testing.expect(server.lastRequest() != null);
}

test "gql dry run reports the operation without sending it" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{
                "mutation IssueDelete { issueDelete(id: \"abc\") { success } }",
                "--operation-name",
                "IssueDelete",
                "--dry-run",
            };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "dry run") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "mutation") != null);
    try std.testing.expect(server.lastRequest() == null);
}

test "issue view does not download attachments unless a directory is given" {
    var no_args = [_][]const u8{};
    const defaults = try issue_view_cmd.parseOptions(no_args[0..]);
    try std.testing.expect(defaults.attachment_dir == null);

    var explicit = [_][]const u8{ "ENG-123", "--attachment-dir", "/var/tmp/linear" };
    const opts = try issue_view_cmd.parseOptions(explicit[0..]);
    try std.testing.expectEqualStrings("/var/tmp/linear", opts.attachment_dir.?);

    var disabled = [_][]const u8{ "ENG-123", "--attachment-dir", "" };
    const off = try issue_view_cmd.parseOptions(disabled[0..]);
    try std.testing.expect(off.attachment_dir == null);
}

test "redactKey hides keys that are too short to mask" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("<redacted>", common.redactKey("k", &buf));
    try std.testing.expectEqualStrings("<redacted>", common.redactKey("abcd1234", &buf));
    try std.testing.expectEqualStrings(fake_api_key_redacted, common.redactKey(fake_api_key, &buf));
}

// ---------------------------------------------------------------------------
// Content fidelity: file/stdin input, project long-form content, comments
// ---------------------------------------------------------------------------

/// Shared runner for commands that only vary by argv and the json flag.
const ArgsRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    json_output: bool = false,
};

fn runIssueCreateArgs(r: *const ArgsRunner) !u8 {
    return issue_create_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runIssueUpdateArgs(r: *const ArgsRunner) !u8 {
    return issue_update_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runIssueCommentArgs(r: *const ArgsRunner) !u8 {
    return issue_comment_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runIssueCommentsArgs(r: *const ArgsRunner) !u8 {
    return issue_comments_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runProjectCreateArgs(r: *const ArgsRunner) !u8 {
    return project_create_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

fn runProjectUpdateArgs(r: *const ArgsRunner) !u8 {
    return project_update_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

/// Writes `contents` into `tmp` and returns the absolute path; caller frees.
/// The sentinel is preserved so `allocator.free` sees the real allocation size.
fn writeTempFile(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    contents: []const u8,
) ![:0]u8 {
    const file = try tmp.dir.createFile(test_io, name, .{ .read = true, .truncate = true });
    defer file.close(test_io);
    try file.writeStreamingAll(test_io, contents);
    return tmp.dir.realPathFileAlloc(test_io, name, allocator);
}

/// Returns the `input` object of the mock server's last recorded request. The
/// caller owns the parsed document and must deinit it.
fn lastInputVariables(
    allocator: std.mem.Allocator,
    server: *mock_graphql.MockServer,
) !std.json.Parsed(std.json.Value) {
    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    return std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
}

fn expectStringField(value: std.json.Value, key: []const u8, expected: []const u8) !void {
    if (value != .object) return error.TestExpectedResult;
    const found = value.object.get(key) orelse return error.TestExpectedResult;
    if (found != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings(expected, found.string);
}

const multiline_body = "# Heading\n\nParagraph with \"quotes\" and $dollars.\n";

test "issue create reads the description from a file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "body.md", multiline_body);
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueCreate", fixtures.issue_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--team",             "123e4567-e89b-12d3-a456-426614174000",
        "--title",            "Imported",
        "--description-file", path,
        "--yes",              "--quiet",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "description", multiline_body);
}

test "issue create reads the description from stdin" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueCreate", fixtures.issue_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--team",             "123e4567-e89b-12d3-a456-426614174000",
        "--title",            "Imported",
        "--description-file", "-",
        "--yes",              "--quiet",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutputWithStdin(allocator, &runner, runIssueCreateArgs, multiline_body);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "description", multiline_body);
}

test "issue create rejects both description and description-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--team",             "123e4567-e89b-12d3-a456-426614174000",
        "--title",            "Imported",
        "--description",      "inline",
        "--description-file", "body.md",
        "--yes",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings(
        "issue create: cannot use both --description and --description-file\n",
        capture.stderr,
    );
}

test "issue create rejects an oversize description file" {
    const allocator = std.testing.allocator;

    const oversize = try allocator.alloc(u8, common.max_content_bytes + 1);
    defer allocator.free(oversize);
    @memset(oversize, 'a');

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "huge.md", oversize);
    defer allocator.free(path);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--team",             "123e4567-e89b-12d3-a456-426614174000",
        "--title",            "Imported",
        "--description-file", path,
        "--yes",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "exceeds the 1048576 byte limit") != null);
}

test "issue create accepts a description file exactly at the size limit" {
    const allocator = std.testing.allocator;

    const at_limit = try allocator.alloc(u8, common.max_content_bytes);
    defer allocator.free(at_limit);
    @memset(at_limit, 'a');

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "limit.md", at_limit);
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueCreate", fixtures.issue_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--team",             "123e4567-e89b-12d3-a456-426614174000",
        "--title",            "Imported",
        "--description-file", path,
        "--yes",              "--quiet",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
}

test "issue create reports a missing description file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--team",             "123e4567-e89b-12d3-a456-426614174000",
        "--title",            "Imported",
        "--description-file", "/nonexistent/linear-cli/body.md",
        "--yes",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "cannot read file") != null);
}

test "issue update reads the description from a file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "body.md", multiline_body);
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "LIN-123", "--description-file", path, "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueUpdateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "description", multiline_body);
}

test "issue update rejects both description and description-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "LIN-123",            "--description", "inline",
        "--description-file", "body.md",       "--yes",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueUpdateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue update: cannot use both --description and --description-file\n",
        capture.stderr,
    );
}

test "issue update accepts description-file as the only field" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "body.md", "Only field");
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueUpdate", fixtures.issue_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "LIN-123", "--description-file", path, "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueUpdateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "at least one field") == null);
}

test "issue comment reads the body from stdin" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("CommentCreate", fixtures.comment_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "ENG-123", "--body-file", "-", "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutputWithStdin(allocator, &runner, runIssueCommentArgs, multiline_body);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "body", multiline_body);
}

test "issue comment rejects an oversize body file" {
    const allocator = std.testing.allocator;

    const oversize = try allocator.alloc(u8, common.max_content_bytes + 1);
    defer allocator.free(oversize);
    @memset(oversize, 'b');

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "huge.md", oversize);
    defer allocator.free(path);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "ENG-123", "--body-file", path, "--yes" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "exceeds the 1048576 byte limit") != null);
}

test "issue comment threads a reply with --parent" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("CommentCreate", fixtures.comment_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "ENG-123", "--body", "Reply", "--parent", "comment-parent", "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "parentId", "comment-parent");
}

test "issue comment omits parentId when --parent is absent" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueLookup", fixtures.issue_lookup_response);
    try server.set("CommentCreate", fixtures.comment_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "ENG-123", "--body", "Top level", "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    if (input != .object) return error.TestExpectedResult;
    try std.testing.expect(input.object.get("parentId") == null);
}

test "project create sends content alongside the capped description" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);
    try server.set("ProjectCreate", fixtures.project_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--name",        "New Project",
        "--team",        "ENG",
        "--description", "short summary",
        "--content",     multiline_body,
        "--yes",         "--quiet",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "description", "short summary");
    try expectStringField(input, "content", multiline_body);
}

test "project create reads content from a file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "overview.md", multiline_body);
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("TeamLookup", fixtures.issue_create_team_lookup);
    try server.set("ProjectCreate", fixtures.project_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--name", "New Project", "--team", "ENG", "--content-file", path, "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "content", multiline_body);
}

test "project create rejects both content and content-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "--name",    "New Project", "--team",         "ENG",
        "--content", "inline",      "--content-file", "overview.md",
        "--yes",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectCreateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "project create: cannot use both --content and --content-file\n",
        capture.stderr,
    );
}

test "project update sends content, start date and target date" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "overview.md", multiline_body);
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectUpdate", fixtures.project_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "proj_123",     "--content-file", path,
        "--start-date", "2026-01-01",     "--target-date",
        "2026-12-31",   "--yes",          "--quiet",
    };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectUpdateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "content", multiline_body);
    try expectStringField(input, "startDate", "2026-01-01");
    try expectStringField(input, "targetDate", "2026-12-31");
}

test "project update rejects both content and content-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "proj_123", "--content", "inline", "--content-file", "overview.md", "--yes" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectUpdateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "project update: cannot use both --content and --content-file\n",
        capture.stderr,
    );
}

test "project update accepts a date as the only field" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectUpdate", fixtures.project_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "proj_123", "--target-date", "2026-12-31", "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runProjectUpdateArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "at least one field") == null);
}

test "issue comment list renders the default table" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", fixtures.issue_comments_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.issue_comments_table, capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueComments", recorded.operation);
}

test "issue comment list quiet prints comment ids" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", fixtures.issue_comments_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("comment-1\ncomment-2\ncomment-3\n", capture.stdout);
}

test "issue comment list data-only projects selected fields and folds bodies" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", fixtures.issue_comments_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123", "--fields", "id,parent,body", "--data-only" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "comment-1\t\tFirst comment\n" ++
            "comment-2\tcomment-1\tReply with two lines\n" ++
            "comment-3\t\tThird\n",
        capture.stdout,
    );
}

test "issue comment list json keeps comment bodies verbatim" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", fixtures.issue_comments_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const issue = parsed.value.object.get("issue") orelse return error.TestExpectedResult;
    const comments = issue.object.get("comments") orelse return error.TestExpectedResult;
    const nodes = comments.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nodes.array.items.len);
    try expectStringField(nodes.array.items[1], "body", "Reply with\ntwo lines");
}

test "issue comment list data-only json keeps bodies verbatim" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", fixtures.issue_comments_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123", "--fields", "id,body", "--data-only" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes") orelse return error.TestExpectedResult;
    if (nodes != .array) return error.TestExpectedResult;
    try expectStringField(nodes.array.items[1], "body", "Reply with\ntwo lines");
    const page_info = parsed.value.object.get("pageInfo") orelse return error.TestExpectedResult;
    const has_next = page_info.object.get("hasNextPage") orelse return error.TestExpectedResult;
    if (has_next != .bool) return error.TestExpectedResult;
    try std.testing.expect(!has_next.bool);
}

test "issue comment list rejects invalid fields" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123", "--fields", "id,bogus" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings("issue comment list: invalid --fields value\n", capture.stderr);
}

test "issue comment list requires an issue identifier" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{"list"};
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("issue comment list: missing issue identifier\n", capture.stderr);
}

test "issue comment list warns when more comments remain" {
    const allocator = std.testing.allocator;
    const truncated_payload =
        \\{
        \\  "data": {
        \\    "issue": {
        \\      "id": "issue-1",
        \\      "identifier": "ENG-123",
        \\      "comments": {
        \\        "nodes": [
        \\          { "id": "comment-9", "body": "Last", "createdAt": "2024-01-09T00:00:00.000Z", "updatedAt": "2024-01-09T00:00:00.000Z", "url": "", "user": { "name": "Ada" }, "parent": null }
        \\        ],
        \\        "pageInfo": { "hasNextPage": true, "endCursor": "cursor-comment-9" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", truncated_payload);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123", "--limit", "1", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("comment-9\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "issue comment list: more comments available; pagination not implemented (endCursor cursor-comment-9)\n",
        capture.stderr,
    );
}

test "issue comment list passes the identifier and limit to the query" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueComments", fixtures.issue_comments_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "ENG-123", "--limit", "7", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    try expectStringField(parsed.value, "id", "ENG-123");
    const first_value = parsed.value.object.get("first") orelse return error.TestExpectedResult;
    if (first_value != .integer) return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 7), first_value.integer);
}

test "issue comment update replaces the body" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("CommentUpdate", fixtures.comment_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "comment-1", "--body", "Corrected text", "--yes", "--quiet" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("comment-1\n", capture.stdout);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    try expectStringField(parsed.value, "id", "comment-1");
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "body", "Corrected text");
}

test "issue comment update reads the body from a file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(allocator, &tmp, "body.md", multiline_body);
    defer allocator.free(path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("CommentUpdate", fixtures.comment_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "comment-1", "--body-file", path, "--yes", "--data-only" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "comment\tcomment-1\n" ++
            "issue\tENG-123\n" ++
            "updated_at\t2024-02-01T12:00:00.000Z\n" ++
            "url\thttps://linear.app/acme/issue/ENG-123#comment-1\n",
        capture.stdout,
    );

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try expectStringField(input, "body", multiline_body);
}

test "issue comment update requires confirmation" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "comment-1", "--body", "Corrected text" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "issue comment update rejects both body and body-file" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "comment-1", "--body", "inline", "--body-file", "body.md", "--yes" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue comment update: cannot use both --body and --body-file\n",
        capture.stderr,
    );
}

test "issue comment update reports a user error" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "commentUpdate": {
        \\      "success": false,
        \\      "comment": null,
        \\      "userError": "comment is locked"
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("CommentUpdate", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "comment-1", "--body", "Corrected text", "--yes" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "comment is locked") != null);
}

test "issue comment delete removes the comment" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("CommentDelete", fixtures.comment_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "comment-1", "--yes" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("issue comment delete: deleted comment-1\n", capture.stdout);

    var parsed = try lastInputVariables(allocator, &server);
    defer parsed.deinit();
    try expectStringField(parsed.value, "id", "comment-1");

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("CommentDelete", recorded.operation);
}

test "issue comment delete data-only emits tab separated fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("CommentDelete", fixtures.comment_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "comment-1", "--yes", "--data-only" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("comment\tcomment-1\ndeleted\ttrue\n", capture.stdout);
}

test "issue comment delete requires confirmation" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "comment-1" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "confirmation required") != null);
}

test "issue comment delete reports a user error" {
    const allocator = std.testing.allocator;
    const user_error =
        \\{
        \\  "data": {
        \\    "commentDelete": {
        \\      "success": false,
        \\      "userError": { "message": "not permitted" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("CommentDelete", user_error);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "comment-1", "--yes" };
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "not permitted") != null);
}

test "issue comment subcommand dispatch only claims list, update and delete" {
    try std.testing.expect(issue_comments_cmd.isSubcommand("list"));
    try std.testing.expect(issue_comments_cmd.isSubcommand("update"));
    try std.testing.expect(issue_comments_cmd.isSubcommand("delete"));
    try std.testing.expect(!issue_comments_cmd.isSubcommand("ENG-123"));
    try std.testing.expect(!issue_comments_cmd.isSubcommand("create"));
}

test "issue comment rejects an unknown subcommand" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{"archive"};
    const runner = ArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueCommentsArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("issue comment: unknown command: archive\n", capture.stderr);
}

test "parse issue comment list options" {
    const args = [_][]const u8{
        "ENG-123", "--limit=25",    "--fields", "id,body",
        "--plain", "--no-truncate", "--quiet",  "--data-only",
    };
    const opts = try issue_comments_cmd.parseListOptions(args[0..]);
    try std.testing.expectEqualStrings("ENG-123", opts.identifier.?);
    try std.testing.expectEqual(@as(usize, 25), opts.limit);
    try std.testing.expectEqualStrings("id,body", opts.fields.?);
    try std.testing.expect(opts.plain);
    try std.testing.expect(opts.no_truncate);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.data_only);
    try std.testing.expect(!opts.help);

    const zero = [_][]const u8{ "ENG-123", "--limit", "0" };
    try std.testing.expectError(error.InvalidLimit, issue_comments_cmd.parseListOptions(zero[0..]));

    const unknown = [_][]const u8{ "ENG-123", "--nope" };
    try std.testing.expectError(error.UnknownFlag, issue_comments_cmd.parseListOptions(unknown[0..]));
}

test "parse issue comment update and delete options" {
    const update_args = [_][]const u8{ "comment-1", "--body-file", "-", "--force", "--data-only" };
    const update_opts = try issue_comments_cmd.parseUpdateOptions(update_args[0..]);
    try std.testing.expectEqualStrings("comment-1", update_opts.comment_id.?);
    try std.testing.expectEqualStrings("-", update_opts.body_file.?);
    try std.testing.expect(update_opts.body == null);
    try std.testing.expect(update_opts.yes);
    try std.testing.expect(update_opts.data_only);

    const missing = [_][]const u8{ "comment-1", "--body" };
    try std.testing.expectError(error.MissingValue, issue_comments_cmd.parseUpdateOptions(missing[0..]));

    const delete_args = [_][]const u8{ "comment-1", "--yes", "--quiet" };
    const delete_opts = try issue_comments_cmd.parseDeleteOptions(delete_args[0..]);
    try std.testing.expectEqualStrings("comment-1", delete_opts.comment_id.?);
    try std.testing.expect(delete_opts.yes);
    try std.testing.expect(delete_opts.quiet);

    const extra = [_][]const u8{ "comment-1", "comment-2" };
    try std.testing.expectError(error.UnexpectedArgument, issue_comments_cmd.parseDeleteOptions(extra[0..]));
}

test "parse issue create and update description-file flags" {
    const create_args = [_][]const u8{ "--team", "ENG", "--title", "T", "--description-file=body.md" };
    const create_opts = try issue_create_cmd.parseOptions(create_args[0..]);
    try std.testing.expectEqualStrings("body.md", create_opts.description_file.?);
    try std.testing.expect(create_opts.description == null);

    const update_args = [_][]const u8{ "ENG-123", "--description-file", "-" };
    const update_opts = try issue_update_cmd.parseOptions(update_args[0..]);
    try std.testing.expectEqualStrings("-", update_opts.description_file.?);
}

test "parse project content and date flags" {
    var create_args = [_][]const u8{ "--name", "P", "--team", "ENG", "--content-file=overview.md" };
    const create_opts = try project_create_cmd.parseOptions(create_args[0..]);
    try std.testing.expectEqualStrings("overview.md", create_opts.content_file.?);
    try std.testing.expect(create_opts.content == null);

    var update_args = [_][]const u8{
        "proj_123",      "--content=inline",
        "--start-date",  "2026-01-01",
        "--target-date", "2026-12-31",
    };
    const update_opts = try project_update_cmd.parseOptions(update_args[0..]);
    try std.testing.expectEqualStrings("inline", update_opts.content.?);
    try std.testing.expectEqualStrings("2026-01-01", update_opts.start_date.?);
    try std.testing.expectEqualStrings("2026-12-31", update_opts.target_date.?);
}

test "parse issue comment parent flag" {
    const args = [_][]const u8{ "ENG-123", "--body", "reply", "--parent=comment-1" };
    const opts = try issue_comment_cmd.parseOptions(args[0..]);
    try std.testing.expectEqualStrings("comment-1", opts.parent.?);

    const missing = [_][]const u8{ "ENG-123", "--body", "reply", "--parent" };
    try std.testing.expectError(error.MissingValue, issue_comment_cmd.parseOptions(missing[0..]));
}

test "gql dry run succeeds without a configured api key" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    // No api key: a dry run makes no request, so it must not demand one.
    var cfg = config.Config{ .allocator = allocator, .io = test_io, .environ = testEnviron() };
    cfg.team_cache = std.StringHashMap([]const u8).init(allocator);
    defer cfg.deinit();
    try std.testing.expectError(error.MissingApiKey, cfg.resolveApiKey(null));

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{ "query Viewer { viewer { id } }", "--dry-run" };
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "dry run") != null);
    try std.testing.expectEqualStrings("", capture.stderr);
    try std.testing.expect(server.lastRequest() == null);
}

test "gql still requires an api key when a request is sent" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = config.Config{ .allocator = allocator, .io = test_io, .environ = testEnviron() };
    cfg.team_cache = std.StringHashMap([]const u8).init(allocator);
    defer cfg.deinit();

    const Runner = struct {
        allocator: std.mem.Allocator,
        cfg: *config.Config,
    };
    const runGql = struct {
        pub fn call(r: *const Runner) !u8 {
            var args = [_][]const u8{"query Viewer { viewer { id } }"};
            return gql.run(.{
                .allocator = r.allocator,
                .io = test_io,
                .config = r.cfg,
                .args = args[0..],
                .json_output = false,
                .retries = 0,
                .timeout_ms = 10_000,
            });
        }
    }.call;
    const runner = Runner{ .allocator = allocator, .cfg = &cfg };

    const capture = try captureOutput(allocator, &runner, runGql);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "MissingApiKey") != null);
    try std.testing.expect(server.lastRequest() == null);
}

test "download creates the output file owner-only" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const target = try std.fs.path.join(allocator, &.{ dir_path, "attachment.bin" });
    defer allocator.free(target);

    const file = try download_cmd.createOutputFile(test_io, target);
    defer file.close(test_io);

    const file_stat = try file.stat(test_io);
    try std.testing.expectEqual(
        @as(u32, download_cmd.download_file_mode),
        @as(u32, file_stat.permissions.toMode() & 0o777),
    );
}

test "online viewer smoke (env gated)" {
    const allocator = std.testing.allocator;
    const run_online = testEnviron().getAlloc(allocator, "LINEAR_ONLINE_TESTS") catch null;
    defer if (run_online) |val| allocator.free(val);
    if (run_online == null) return;

    const api_key = testEnviron().getAlloc(allocator, "LINEAR_API_KEY") catch null;
    defer if (api_key) |val| allocator.free(val);
    if (api_key == null) return;

    defer graphql.deinitSharedClient(test_io);
    var client = graphql.GraphqlClient.init(allocator, test_io, api_key.?);
    defer client.deinit();

    const query = "query { viewer { id } }";
    var response = try client.send(allocator, .{
        .query = query,
        .variables = null,
        .operation_name = "Viewer",
    });
    defer response.deinit();

    try std.testing.expect(response.isSuccessStatus());
    try std.testing.expect(!response.hasGraphqlErrors());
}

// ---------------------------------------------------------------------------
// git integration
// ---------------------------------------------------------------------------

/// Scripted stand-in for `git`/`gh`.
///
/// Records the exact argv of every invocation so tests can assert on the
/// command line, and returns canned results instead of spawning anything. No
/// test in this file shells out to a real binary or depends on the branch this
/// repository happens to be on.
const FakeProcess = struct {
    allocator: std.mem.Allocator,
    script: []const Step,
    next: usize = 0,
    calls: std.ArrayListUnmanaged([]u8) = .empty,
    /// Whatever each `capture` call was told to write to the child's stdin,
    /// so a test can prove a secret travelled there and not through argv.
    inputs: std.ArrayListUnmanaged([]u8) = .empty,

    const Step = struct {
        exit_code: u8 = 0,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        fail: ?git.Error = null,
    };

    fn deinit(self: *FakeProcess) void {
        for (self.calls.items) |call| self.allocator.free(call);
        self.calls.deinit(self.allocator);
        for (self.inputs.items) |input| self.allocator.free(input);
        self.inputs.deinit(self.allocator);
    }

    fn runner(self: *FakeProcess) git.Runner {
        return .{ .context = self, .captureFn = captureImpl, .inheritFn = inheritImpl };
    }

    /// Running past the end of the script is a test bug, not a success.
    fn take(self: *FakeProcess) ?Step {
        if (self.next >= self.script.len) return null;
        const step = self.script[self.next];
        self.next += 1;
        return step;
    }

    fn record(self: *FakeProcess, argv: []const []const u8) !void {
        try self.calls.append(self.allocator, try joinArgv(self.allocator, argv));
    }

    fn recordInput(self: *FakeProcess, input: ?[]const u8) !void {
        const owned = try self.allocator.dupe(u8, input orelse "");
        errdefer self.allocator.free(owned);
        try self.inputs.append(self.allocator, owned);
    }

    fn captureImpl(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: git.CaptureOptions,
    ) git.Error!git.Captured {
        _ = io;
        const self: *FakeProcess = @ptrCast(@alignCast(context.?));
        self.record(argv) catch return error.OutOfMemory;
        self.recordInput(options.stdin) catch return error.OutOfMemory;
        const step = self.take() orelse return error.SpawnFailed;
        if (step.fail) |failure| return failure;
        const out = allocator.dupe(u8, step.stdout) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        const err_out = allocator.dupe(u8, step.stderr) catch return error.OutOfMemory;
        return .{ .exit = .{ .exited = step.exit_code }, .stdout = out, .stderr = err_out };
    }

    fn inheritImpl(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
    ) git.Error!git.Exit {
        _ = allocator;
        _ = io;
        const self: *FakeProcess = @ptrCast(@alignCast(context.?));
        self.record(argv) catch return error.OutOfMemory;
        const step = self.take() orelse return error.SpawnFailed;
        if (step.fail) |failure| return failure;
        return .{ .exited = step.exit_code };
    }
};

/// Joins argv with a unit separator so an assertion can never be satisfied by
/// a different split of the same characters.
fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var joined = std.ArrayListUnmanaged(u8).empty;
    errdefer joined.deinit(allocator);
    for (argv, 0..) |arg, idx| {
        if (idx > 0) try joined.append(allocator, '\x1f');
        try joined.appendSlice(allocator, arg);
    }
    return joined.toOwnedSlice(allocator);
}

fn expectCall(fake: *const FakeProcess, index: usize, expected: []const []const u8) !void {
    try std.testing.expect(index < fake.calls.items.len);
    const wanted = try joinArgv(std.testing.allocator, expected);
    defer std.testing.allocator.free(wanted);
    try std.testing.expectEqualStrings(wanted, fake.calls.items[index]);
}

test "git matches a linear identifier in a branch name" {
    try std.testing.expectEqualStrings("eng-123", git.matchIdentifier("eng-123").?);
    try std.testing.expectEqualStrings("eng-123", git.matchIdentifier("erick/eng-123-ship-it").?);
    try std.testing.expectEqualStrings("ENG-7", git.matchIdentifier("feature/ENG-7-thing").?);
    try std.testing.expectEqualStrings("ENG-321", git.matchIdentifier("ENG-321").?);
    // A digits-only team key is still a valid `[A-Za-z0-9]+` key.
    try std.testing.expectEqualStrings("123-45", git.matchIdentifier("123-45").?);
}

test "git returns null for branches without an identifier" {
    try std.testing.expect(git.matchIdentifier("") == null);
    try std.testing.expect(git.matchIdentifier("main") == null);
    try std.testing.expect(git.matchIdentifier("release/2024") == null);
    try std.testing.expect(git.matchIdentifier("eng-") == null);
    try std.testing.expect(git.matchIdentifier("-123") == null);
    // The issue number may not have a leading zero.
    try std.testing.expect(git.matchIdentifier("eng-0123") == null);
    // A word byte immediately after the number breaks the trailing boundary.
    try std.testing.expect(git.matchIdentifier("x-1y") == null);
    // `_` counts as a word byte, so it breaks the leading boundary.
    try std.testing.expect(git.matchIdentifier("feat_eng-123") == null);
}

test "git takes the leftmost identifier when a branch has several" {
    try std.testing.expectEqualStrings("eng-1", git.matchIdentifier("eng-1-and-eng-2").?);
    try std.testing.expectEqualStrings("ENG-10", git.matchIdentifier("ENG-10/ENG-11").?);
    // The first candidate key is followed by a non-number, so the match starts
    // at the next word boundary instead.
    try std.testing.expectEqualStrings("cd-12", git.matchIdentifier("ab-cd-12").?);
}

test "git treats a trailing non-word byte as a boundary" {
    try std.testing.expectEqualStrings("eng-123", git.matchIdentifier("eng-123.patch").?);
    try std.testing.expectEqualStrings("eng-123", git.matchIdentifier("eng-123/fix").?);
    try std.testing.expectEqualStrings("eng-123", git.matchIdentifier("eng-123-fix").?);
}

test "git uppercases the team key when extracting an identifier" {
    const allocator = std.testing.allocator;

    const lower = (try git.extractIdentifier(allocator, "erick/eng-123-ship-it")).?;
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("ENG-123", lower);

    const mixed = (try git.extractIdentifier(allocator, "Eng-9")).?;
    defer allocator.free(mixed);
    try std.testing.expectEqualStrings("ENG-9", mixed);

    try std.testing.expect(try git.extractIdentifier(allocator, "main") == null);
}

test "git rejects ref arguments that could be read as flags" {
    try std.testing.expectError(error.EmptyRef, git.validateRefArg(""));
    try std.testing.expectError(error.LeadingDash, git.validateRefArg("--upload-pack=evil"));
    try std.testing.expectError(error.LeadingDash, git.validateRefArg("-b"));
    try std.testing.expectError(error.IllegalCharacter, git.validateRefArg("has space"));
    try std.testing.expectError(error.IllegalCharacter, git.validateRefArg("has\nnewline"));
    try git.validateRefArg("erick/eng-123-ship-it");
    try git.validateRefArg("main");
}

test "git builds branch argv arrays" {
    try expectArgv(&.{ "git", "symbolic-ref", "--short", "HEAD" }, &git.current_branch_argv);
    try expectArgv(&.{ "git", "rev-parse", "--is-inside-work-tree" }, &git.inside_work_tree_argv);

    const verify = git.verifyRefArgv("erick/eng-123");
    try expectArgv(&.{ "git", "rev-parse", "--verify", "erick/eng-123" }, &verify);

    const checkout = git.checkoutArgv("erick/eng-123");
    try expectArgv(&.{ "git", "checkout", "erick/eng-123" }, &checkout);

    var buffer: [5][]const u8 = undefined;
    try expectArgv(
        &.{ "git", "checkout", "-b", "erick/eng-123" },
        git.checkoutNewArgv(&buffer, "erick/eng-123", null),
    );
    try expectArgv(
        &.{ "git", "checkout", "-b", "erick/eng-123", "main" },
        git.checkoutNewArgv(&buffer, "erick/eng-123", "main"),
    );
}

test "git builds gh pr create argv with the title as one element" {
    const allocator = std.testing.allocator;

    const hostile_title = "ENG-1 Fix \"quoting\"; rm -rf / && echo $(whoami)";
    const minimal = try git.pullRequestArgv(allocator, .{
        .title = hostile_title,
        .body = "https://linear.app/acme/issue/ENG-1",
    });
    defer allocator.free(minimal);
    try expectArgv(&.{
        "gh",
        "pr",
        "create",
        "--title",
        hostile_title,
        "--body",
        "https://linear.app/acme/issue/ENG-1",
    }, minimal);

    const full = try git.pullRequestArgv(allocator, .{
        .title = "ENG-2 Title",
        .body = "https://linear.app/acme/issue/ENG-2",
        .base = "main",
        .head = "erick/eng-2",
        .draft = true,
        .web = true,
    });
    defer allocator.free(full);
    try expectArgv(&.{
        "gh",
        "pr",
        "create",
        "--title",
        "ENG-2 Title",
        "--body",
        "https://linear.app/acme/issue/ENG-2",
        "--base",
        "main",
        "--head",
        "erick/eng-2",
        "--draft",
        "--web",
    }, full);
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "git reads the current branch from symbolic-ref" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = "erick/eng-123-ship-it\n" }},
    };
    defer fake.deinit();

    const status = try git.currentBranch(fake.runner(), allocator, test_io);
    defer status.deinit(allocator);

    try std.testing.expectEqualStrings("erick/eng-123-ship-it", status.branch);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try expectCall(&fake, 0, &.{ "git", "symbolic-ref", "--short", "HEAD" });
}

test "git reports a detached HEAD instead of failing" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{ .exit_code = 128, .stderr = "fatal: ref HEAD is not a symbolic ref\n" },
            .{ .stdout = "true\n" },
        },
    };
    defer fake.deinit();

    const status = try git.currentBranch(fake.runner(), allocator, test_io);
    defer status.deinit(allocator);

    try std.testing.expect(status == .detached);
    try expectCall(&fake, 1, &.{ "git", "rev-parse", "--is-inside-work-tree" });
}

test "git reports a missing repository separately from a detached HEAD" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{ .exit_code = 128, .stderr = "fatal: not a git repository\n" },
            .{ .exit_code = 128, .stderr = "fatal: not a git repository\n" },
        },
    };
    defer fake.deinit();

    const status = try git.currentBranch(fake.runner(), allocator, test_io);
    defer status.deinit(allocator);

    try std.testing.expect(status == .not_a_repository);
}

test "git infers an uppercased identifier from the branch" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = "erick/eng-321-ship-it\n" }},
    };
    defer fake.deinit();

    const inference = try git.inferIdentifier(fake.runner(), allocator, test_io);
    defer inference.deinit(allocator);

    try std.testing.expectEqualStrings("ENG-321", inference.identifier);
}

test "git keeps the branch name for the no-match diagnostic" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = "main\n" }},
    };
    defer fake.deinit();

    const inference = try git.inferIdentifier(fake.runner(), allocator, test_io);
    defer inference.deinit(allocator);

    try std.testing.expectEqualStrings("main", inference.no_match);
}

test "git inference reports a missing binary as a diagnostic" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .fail = error.BinaryNotFound }},
    };
    defer fake.deinit();

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    try std.testing.expectError(
        error.IdentifierUnavailable,
        git.requireInferredIdentifier(fake.runner(), allocator, test_io, &buffer.writer, "issue view"),
    );
    try std.testing.expectEqualStrings(
        "issue view: git was not found on PATH; pass an issue identifier explicitly\n",
        buffer.written(),
    );
}

test "git inference without a runner reports that it is unavailable" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    try std.testing.expectError(
        error.IdentifierUnavailable,
        git.requireInferredIdentifier(null, allocator, test_io, &buffer.writer, "issue url"),
    );
    try std.testing.expectEqualStrings(
        "issue url: no issue identifier given and branch inference is unavailable\n",
        buffer.written(),
    );
}

test "git inference reports a detached HEAD to the caller" {
    const allocator = std.testing.allocator;
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{ .exit_code = 128 },
            .{ .stdout = "true\n" },
        },
    };
    defer fake.deinit();

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    try std.testing.expectError(
        error.IdentifierUnavailable,
        git.requireInferredIdentifier(fake.runner(), allocator, test_io, &buffer.writer, "issue title"),
    );
    try std.testing.expectEqualStrings(
        "issue title: HEAD is detached; pass an issue identifier explicitly\n",
        buffer.written(),
    );
}

const GitCmdRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    fake: *FakeProcess,
    json_output: bool = false,
};

fn runIssueStartCmd(r: *const GitCmdRunner) !u8 {
    return issue_start_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .json_output = r.json_output,
        .retries = 0,
        .timeout_ms = 10_000,
        .git_runner = r.fake.runner(),
    });
}

fn runIssuePrCmd(r: *const GitCmdRunner) !u8 {
    return issue_pr_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .json_output = r.json_output,
        .retries = 0,
        .timeout_ms = 10_000,
        .git_runner = r.fake.runner(),
    });
}

fn runIssueInfoCmd(r: *const GitCmdRunner) !u8 {
    return issue_info_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .json_output = r.json_output,
        .retries = 0,
        .timeout_ms = 10_000,
        .git_runner = r.fake.runner(),
    });
}

fn runIssueViewWithGit(r: *const GitCmdRunner) !u8 {
    return issue_view_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .json_output = r.json_output,
        .retries = 0,
        .timeout_ms = 10_000,
        .git_runner = r.fake.runner(),
    });
}

test "issue start creates the linear branch and moves the issue to started" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStart", fixtures.issue_start_response);
    try server.set("IssueStartUpdate", fixtures.issue_start_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            // rev-parse --verify: the branch does not exist yet.
            .{ .exit_code = 1 },
            .{ .stderr = "Switched to a new branch 'erick/eng-321-ship-the-git-integration'\n" },
        },
    };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        \\Identifier: ENG-321
        \\Title     : Ship the git integration
        \\Branch    : erick/eng-321-ship-the-git-integration
        \\State     : In Progress
        \\URL       : https://linear.app/acme/issue/ENG-321/ship-the-git-integration
        \\
    , capture.stdout);
    // git's own progress message is forwarded to stderr, never stdout.
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "Switched to a new branch") != null);

    try std.testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try expectCall(&fake, 0, &.{ "git", "rev-parse", "--verify", "erick/eng-321-ship-the-git-integration" });
    try expectCall(&fake, 1, &.{ "git", "checkout", "-b", "erick/eng-321-ship-the-git-integration" });

    const request = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueStartUpdate", request.operation);
    const vars = request.variables_json orelse return error.TestExpectedResult;
    // The lowest-position started state wins, not the first one in the array.
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"stateId\":\"state-progress\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"id\":\"issue-start-1\"") != null);
}

test "issue start checks out an existing branch without creating it" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStart", fixtures.issue_start_response);
    try server.set("IssueStartUpdate", fixtures.issue_start_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{ .stdout = "0f1e2d3c\n" },
            .{ .stderr = "Switched to branch 'erick/eng-321-ship-the-git-integration'\n" },
        },
    };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--yes", "--quiet" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ENG-321\n", capture.stdout);
    try expectCall(&fake, 1, &.{ "git", "checkout", "erick/eng-321-ship-the-git-integration" });
}

test "issue start honours --branch and --from-ref" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStart", fixtures.issue_start_response);
    try server.set("IssueStartUpdate", fixtures.issue_start_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{ .{ .exit_code = 1 }, .{} },
    };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--branch", "fix/eng-321", "--from-ref", "main", "--yes", "--quiet" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try expectCall(&fake, 0, &.{ "git", "rev-parse", "--verify", "fix/eng-321" });
    try expectCall(&fake, 1, &.{ "git", "checkout", "-b", "fix/eng-321", "main" });
}

test "issue start skips the mutation when the issue is already started" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // IssueStartUpdate is deliberately not registered: reaching it would fail.
    try server.set("IssueStart", fixtures.issue_start_already_started);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{ .{ .stdout = "0f1e2d3c\n" }, .{} },
    };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--yes", "--quiet" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ENG-321\n", capture.stdout);
    const request = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("IssueStart", request.operation);
}

test "issue start fails before touching git when the team has no started state" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStart", fixtures.issue_start_no_started);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stdout);
    try std.testing.expectEqualStrings(
        "issue start: team has no workflow state of type 'started'\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "issue start requires confirmation before any request or subprocess" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStart", fixtures.issue_start_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var args = [_][]const u8{"ENG-321"};
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue start: confirmation required; re-run with --yes to proceed\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expect(server.lastRequest() == null);
}

test "issue start rejects a branch name that looks like a flag" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--branch=--upload-pack=evil", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("issue start: --branch must not start with '-'\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expect(server.lastRequest() == null);
}

test "issue start infers the issue from the current branch" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueStart", fixtures.issue_start_response);
    try server.set("IssueStartUpdate", fixtures.issue_start_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{ .stdout = "erick/eng-321-ship-the-git-integration\n" },
            .{ .stdout = "0f1e2d3c\n" },
            .{},
        },
    };
    defer fake.deinit();

    var args = [_][]const u8{ "--yes", "--quiet" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueStartCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try expectCall(&fake, 0, &.{ "git", "symbolic-ref", "--short", "HEAD" });
    try std.testing.expectEqualStrings("ENG-321\n", capture.stdout);
}

test "issue pr passes the issue title to gh as a single argument" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssuePullRequest", fixtures.issue_pr_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{.{}} };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-777", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssuePrCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try expectCall(&fake, 0, &.{
        "gh",
        "pr",
        "create",
        "--title",
        "ENG-777 Fix \"quoting\"; rm -rf / && echo $(whoami)",
        "--body",
        "https://linear.app/acme/issue/ENG-777/fix-quoting",
    });
}

test "issue pr forwards base, head, draft and web flags" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssuePullRequest", fixtures.issue_ref_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{.{}} };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--base", "main", "--head", "erick/eng-321", "--draft", "--web", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssuePrCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try expectCall(&fake, 0, &.{
        "gh",
        "pr",
        "create",
        "--title",
        "ENG-321 Ship the git integration",
        "--body",
        "https://linear.app/acme/issue/ENG-321/ship-the-git-integration",
        "--base",
        "main",
        "--head",
        "erick/eng-321",
        "--draft",
        "--web",
    });
}

test "issue pr propagates a failing gh exit status" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssuePullRequest", fixtures.issue_ref_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{.{ .exit_code = 3 }} };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssuePrCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 3), capture.exit_code);
    try std.testing.expectEqualStrings("issue pr: gh pr create exited with status 3\n", capture.stderr);
}

test "issue pr reports a missing gh binary" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssuePullRequest", fixtures.issue_ref_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{.{ .fail = error.BinaryNotFound }} };
    defer fake.deinit();

    var args = [_][]const u8{ "ENG-321", "--yes" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssuePrCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("issue pr: gh was not found on PATH\n", capture.stderr);
}

test "issue id answers from the branch without a request or an api key" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    // No api key on purpose: `issue id` must not need one.
    var cfg = config.Config{ .allocator = allocator, .io = test_io, .environ = testEnviron() };
    cfg.team_cache = std.StringHashMap([]const u8).init(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = "erick/eng-321-ship-it\n" }},
    };
    defer fake.deinit();

    var args = [_][]const u8{"id"};
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueInfoCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ENG-321\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);
    try std.testing.expect(server.lastRequest() == null);
}

test "issue url and issue title print one line each" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueRef", fixtures.issue_ref_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var url_args = [_][]const u8{ "url", "ENG-321" };
    const url_runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = url_args[0..], .fake = &fake };
    const url_capture = try captureOutput(allocator, &url_runner, runIssueInfoCmd);
    defer url_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), url_capture.exit_code);
    try std.testing.expectEqualStrings(
        "https://linear.app/acme/issue/ENG-321/ship-the-git-integration\n",
        url_capture.stdout,
    );

    var title_args = [_][]const u8{ "title", "ENG-321" };
    const title_runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = title_args[0..], .fake = &fake };
    const title_capture = try captureOutput(allocator, &title_runner, runIssueInfoCmd);
    defer title_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), title_capture.exit_code);
    try std.testing.expectEqualStrings("Ship the git integration\n", title_capture.stdout);

    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "issue describe emits a commit message with linear trailers" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueRef", fixtures.issue_ref_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var args = [_][]const u8{ "describe", "ENG-321" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueInfoCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        \\ENG-321 Ship the git integration
        \\
        \\Linear-issue: Fixes ENG-321
        \\Linear-issue-url: https://linear.app/acme/issue/ENG-321/ship-the-git-integration
        \\
    , capture.stdout);
}

test "issue describe --references swaps the trailer verb" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueRef", fixtures.issue_ref_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var args = [_][]const u8{ "describe", "ENG-321", "--references" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueInfoCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "Linear-issue: References ENG-321\n") != null);
}

test "issue describe rejects --references on the other accessors" {
    const allocator = std.testing.allocator;

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    var args = [_][]const u8{ "title", "ENG-321", "--references" };
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueInfoCmd);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stderr,
        "issue title: --references is only valid for 'issue describe'",
    ) != null);
}

test "issue view infers the identifier from the branch when none is given" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = "erick/eng-9-inferred\n" }},
    };
    defer fake.deinit();

    var args = [_][]const u8{"--quiet"};
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueViewWithGit);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try expectCall(&fake, 0, &.{ "git", "symbolic-ref", "--short", "HEAD" });

    const request = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = request.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"id\":\"ENG-9\"") != null);
}

test "issue view reports an unrecognisable branch instead of guessing" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("IssueView", fixtures.issue_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = "main\n" }},
    };
    defer fake.deinit();

    var args = [_][]const u8{};
    const runner = GitCmdRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .fake = &fake };

    const capture = try captureOutput(allocator, &runner, runIssueViewWithGit);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue view: branch 'main' has no issue identifier; pass one explicitly\n",
        capture.stderr,
    );
    try std.testing.expect(server.lastRequest() == null);
}

// ---------------------------------------------------------------------------
// milestone commands
// ---------------------------------------------------------------------------

/// Every milestone verb shares one Context shape, so one runner covers them all.
const MilestoneRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    json_output: bool = false,
};

fn runMilestone(r: *const MilestoneRunner) !u8 {
    return milestones_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

/// A project uuid short-circuits the name lookup, so tests that are not about
/// resolution only need the one milestone fixture.
const milestone_project_uuid = "11111111-2222-3333-4444-555555555555";

test "milestone list renders table with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", milestone_project_uuid };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(fixtures.milestones_table, capture.stdout);
    try std.testing.expectEqualStrings("milestone list: fetched 3 items across 1 page\n", capture.stderr);
    // A uuid needs no project lookup.
    try std.testing.expectEqual(@as(usize, 1), server.request_count);

    // Scoped and unscoped listings share the root query; --project only filters.
    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, recorded.query, "projectMilestones(first: $first") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorded.query, "project { id name }") != null);
}

test "milestone list applies the project filter to the root query" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", milestone_project_uuid, "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ProjectMilestones", recorded.operation);
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;

    // filter: { project: { id: { eq: <uuid> } } }
    const filter = vars.object.get("filter") orelse return error.TestExpectedResult;
    if (filter != .object) return error.TestExpectedResult;
    const project_filter = filter.object.get("project") orelse return error.TestExpectedResult;
    if (project_filter != .object) return error.TestExpectedResult;
    const id_filter = project_filter.object.get("id") orelse return error.TestExpectedResult;
    if (id_filter != .object) return error.TestExpectedResult;
    const eq_value = id_filter.object.get("eq") orelse return error.TestExpectedResult;
    if (eq_value != .string) return error.TestExpectedResult;
    try std.testing.expectEqualStrings(milestone_project_uuid, eq_value.string);
    // The old shape passed the project as a top-level `id` variable.
    try std.testing.expect(vars.object.get("id") == null);
}

test "milestone list without a project sends no filter" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-1\nms-2\nms-3\n", capture.stdout);
    // No project to resolve, so the listing costs exactly one request.
    try std.testing.expectEqual(@as(usize, 1), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars_json = recorded.variables_json orelse return error.TestExpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed.deinit();
    const vars = parsed.value;
    if (vars != .object) return error.TestExpectedResult;
    try std.testing.expect(vars.object.get("filter") == null);
}

test "milestone list disambiguates milestones from several projects" {
    const allocator = std.testing.allocator;

    // Without --project the query spans every project, so two milestones are
    // only distinguishable by the project column.
    const cross_project_payload =
        \\{
        \\  "data": {
        \\    "projectMilestones": {
        \\      "nodes": [
        \\        { "id": "ms-1", "name": "Alpha", "description": null, "targetDate": "2026-08-15", "sortOrder": 1,
        \\          "project": { "id": "project-1", "name": "Roadmap" } },
        \\        { "id": "ms-9", "name": "Hardening", "description": null, "targetDate": "2026-11-01", "sortOrder": 2,
        \\          "project": { "id": "project-2", "name": "Platform" } },
        \\        { "id": "ms-7", "name": "Cutover", "description": null, "targetDate": null, "sortOrder": 3,
        \\          "project": { "id": "project-3", "name": "Migration" } }
        \\      ],
        \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-ms-7" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", cross_project_payload);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{"list"};
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "ID    Name       Target      Sort  Project  \n" ++
            "ms-1  Alpha      2026-08-15  1     Roadmap  \n" ++
            "ms-9  Hardening  2026-11-01  2     Platform \n" ++
            "ms-7  Cutover                3     Migration\n",
        capture.stdout,
    );
    try std.testing.expectEqualStrings("milestone list: fetched 3 items across 1 page\n", capture.stderr);
}

test "milestone list keeps the project column when fields ask for it" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--fields", "name,project" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "Name   Project\n" ++
            "Alpha  Roadmap\n" ++
            "Beta   Roadmap\n" ++
            "GA     Roadmap\n",
        capture.stdout,
    );
}

test "milestone list drops the project column when fields exclude it" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--fields", "id,name" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "ID    Name \n" ++
            "ms-1  Alpha\n" ++
            "ms-2  Beta \n" ++
            "ms-3  GA   \n",
        capture.stdout,
    );
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "Project") == null);
}

test "milestone list resolves a project name to an id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("MilestoneProjectLookup", fixtures.milestone_project_lookup);
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", "Roadmap", "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-1\nms-2\nms-3\n", capture.stdout);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ProjectMilestones", recorded.operation);
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    // The resolved uuid lands in the filter, not in a top-level `id` variable.
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"project\":{\"id\":{\"eq\":\"project-1\"}}") != null);
}

test "milestone list rejects an ambiguous project name" {
    const allocator = std.testing.allocator;
    const ambiguous =
        \\{
        \\  "data": {
        \\    "projects": {
        \\      "nodes": [
        \\        { "id": "project-1", "name": "Roadmap" },
        \\        { "id": "project-2", "name": "Roadmap" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("MilestoneProjectLookup", ambiguous);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", "Roadmap" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "milestone list: project 'Roadmap' is ambiguous; pass the project id\n",
        capture.stderr,
    );
}

test "milestone list projects selected fields with data-only" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", milestone_project_uuid, "--fields", "name,project,sort_order", "--data-only" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "Alpha\tRoadmap\t1\nBeta\tRoadmap\t2.5\nGA\tRoadmap\t3\n",
        capture.stdout,
    );
}

test "milestone list prints json output with mock graphql" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", milestone_project_uuid };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stderr);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const milestones = parsed.value.object.get("projectMilestones") orelse return error.TestExpectedResult;
    const nodes = milestones.object.get("nodes") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nodes.array.items.len);
    const page_info = milestones.object.get("pageInfo") orelse return error.TestExpectedResult;
    const has_next = page_info.object.get("hasNextPage") orelse return error.TestExpectedResult;
    try std.testing.expect(!has_next.bool);
}

test "milestone list rejects invalid fields" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", fixtures.milestones_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", milestone_project_uuid, "--fields", "nope" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone list: invalid --fields value\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "milestone list reports the resume cursor when more milestones remain" {
    const allocator = std.testing.allocator;
    const more_pages =
        \\{
        \\  "data": {
        \\    "projectMilestones": {
        \\      "nodes": [ { "id": "ms-1", "name": "Alpha", "targetDate": "2026-08-15", "sortOrder": 1,
        \\                   "project": { "id": "project-1", "name": "Roadmap" } } ],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-ms-1" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", more_pages);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--project", milestone_project_uuid, "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-1\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "milestone list: fetched 1 items across 1 page; more available, resume with --cursor cursor-ms-1\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

/// One milestone per page so a two-entry sequence exercises a real cursor
/// hand-off; the pages come from different projects so the walk also proves the
/// project column survives page boundaries.
const milestones_page1 =
    \\{
    \\  "data": {
    \\    "projectMilestones": {
    \\      "nodes": [ { "id": "ms-1", "name": "Alpha", "description": null, "targetDate": "2026-08-15", "sortOrder": 1,
    \\                   "project": { "id": "project-1", "name": "Roadmap" } } ],
    \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-ms-1" }
    \\    }
    \\  }
    \\}
;
const milestones_page2 =
    \\{
    \\  "data": {
    \\    "projectMilestones": {
    \\      "nodes": [ { "id": "ms-9", "name": "Hardening", "description": null, "targetDate": "2026-11-01", "sortOrder": 2,
    \\                   "project": { "id": "project-2", "name": "Platform" } } ],
    \\      "pageInfo": { "hasNextPage": false, "endCursor": "cursor-ms-9" }
    \\    }
    \\  }
    \\}
;

test "milestone list walks multiple pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("ProjectMilestones", &.{ milestones_page1, milestones_page2 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--limit", "1", "--pages", "2", "--fields", "id,project", "--data-only" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // Page one's borrowed project name is still readable after page two parsed.
    try std.testing.expectEqualStrings("ms-1\tRoadmap\nms-9\tPlatform\n", capture.stdout);
    try std.testing.expectEqualStrings("milestone list: fetched 2 items across 2 pages\n", capture.stderr);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-ms-1\"") != null);
}

test "milestone list truncates at max-items" {
    const allocator = std.testing.allocator;
    const two_on_a_page =
        \\{
        \\  "data": {
        \\    "projectMilestones": {
        \\      "nodes": [
        \\        { "id": "ms-1", "name": "Alpha", "description": null, "targetDate": null, "sortOrder": 1,
        \\          "project": { "id": "project-1", "name": "Roadmap" } },
        \\        { "id": "ms-9", "name": "Hardening", "description": null, "targetDate": null, "sortOrder": 2,
        \\          "project": { "id": "project-2", "name": "Platform" } }
        \\      ],
        \\      "pageInfo": { "hasNextPage": true, "endCursor": "cursor-ms-9" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", two_on_a_page);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--limit", "2", "--max-items", "1", "--all", "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-1\n", capture.stdout);
    try std.testing.expectEqualStrings(
        "milestone list: fetched 1 items across 1 page; more available, resume with --cursor cursor-ms-9\n" ++
            "milestone list: stopped after 1 items due to --max-items\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "milestone list resumes from a cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestones", milestones_page2);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--cursor", "cursor-ms-1", "--limit", "1", "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-9\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"after\":\"cursor-ms-1\"") != null);
}

test "milestone list rejects --all with --pages" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "list", "--all", "--pages", "2" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr, "milestone list: ConflictingPageFlags\n"));
    try std.testing.expectEqual(@as(usize, 0), server.request_count);

    const conflicting = [_][]const u8{ "--all", "--pages", "2" };
    try std.testing.expectError(error.ConflictingPageFlags, milestones_cmd.parseListOptions(conflicting[0..]));
}

test "milestone view prints key values" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestone", fixtures.milestone_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "view", "ms-2" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "ID         : ms-2\n" ++
            "Name       : Beta\n" ++
            "Project    : Roadmap\n" ++
            "Target     : 2026-09-30\n" ++
            "Sort       : 2.5\n" ++
            "Created    : 2026-07-01T10:00:00.000Z\n" ++
            "Updated    : 2026-07-20T12:30:00.000Z\n" ++
            "Description: Feature complete\n",
        capture.stdout,
    );
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "milestone view data-only emits tab pairs" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestone", fixtures.milestone_view_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "view", "ms-2", "--data-only" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout, "id\tms-2\nname\tBeta\nproject\tRoadmap\n"));
}

test "milestone view requires an id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{"view"};
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone view: missing milestone id\n", capture.stderr);
}

test "milestone view reports a missing milestone" {
    const allocator = std.testing.allocator;
    const empty = "{ \"data\": { \"projectMilestone\": null } }";

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestone", empty);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "view", "ms-missing" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone view: milestone 'ms-missing' not found\n", capture.stderr);
}

test "milestone create requires confirmation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneCreate", fixtures.milestone_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "create", "--project", milestone_project_uuid, "--name", "Launch" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "milestone create: confirmation required; re-run with --yes to proceed\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "milestone create requires a name" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "create", "--project", milestone_project_uuid, "--yes" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone create: --name is required\n", capture.stderr);
}

test "milestone create sends the input and prints the new id" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneCreate", fixtures.milestone_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "create",        "--project",    milestone_project_uuid,
        "--name",        "Launch",       "--target-date",
        "2026-11-01",    "--sort-order", "2.5",
        "--description", "Ship it",      "--yes",
        "--quiet",
    };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-4\n", capture.stdout);
    try std.testing.expectEqualStrings("", capture.stderr);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("ProjectMilestoneCreate", recorded.operation);
    const vars = recorded.variables_json orelse return error.TestExpectedResult;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("input") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings(milestone_project_uuid, input.object.get("projectId").?.string);
    try std.testing.expectEqualStrings("Launch", input.object.get("name").?.string);
    try std.testing.expectEqualStrings("Ship it", input.object.get("description").?.string);
    try std.testing.expectEqualStrings("2026-11-01", input.object.get("targetDate").?.string);
    // `sortOrder` is a GraphQL Float, so it has to leave as a JSON number
    // rather than the string the flag arrived as.
    try std.testing.expectEqual(@as(f64, 2.5), input.object.get("sortOrder").?.float);
}

test "milestone create reads the description from stdin" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneCreate", fixtures.milestone_create_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "create",             "--project", milestone_project_uuid, "--name",  "Launch",
        "--description-file", "-",         "--yes",                "--quiet",
    };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutputWithStdin(allocator, &runner, runMilestone, "piped description\n");
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("ms-4\n", capture.stdout);

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vars, "\"description\":\"piped description\\n\"") != null);
}

test "milestone create rejects both description flags" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "create",        "--project", milestone_project_uuid, "--name",   "Launch",
        "--description", "inline",    "--description-file",   "notes.md", "--yes",
    };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "milestone create: cannot use both --description and --description-file\n",
        capture.stderr,
    );
}

test "milestone create reports a user error" {
    const allocator = std.testing.allocator;
    const failure =
        \\{
        \\  "data": {
        \\    "projectMilestoneCreate": {
        \\      "success": false,
        \\      "userError": { "message": "Milestone name already used" }
        \\    }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneCreate", failure);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "create", "--project", milestone_project_uuid, "--name", "Launch", "--yes" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone create: Milestone name already used\n", capture.stderr);
}

test "milestone update requires at least one field" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "ms-2", "--yes" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "provide at least one of") != null);
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "milestone update requires confirmation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "ms-2", "--target-date", "2026-10-15" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "milestone update: confirmation required; re-run with --yes to proceed\n",
        capture.stderr,
    );
}

test "milestone update sends only the fields that were passed" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneUpdate", fixtures.milestone_update_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "update", "ms-2", "--target-date", "2026-10-15", "--yes" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "ID     : ms-2\n" ++
            "Name   : Beta\n" ++
            "Project: Roadmap\n" ++
            "Target : 2026-10-15\n" ++
            "Sort   : 2.5\n",
        capture.stdout,
    );

    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("{\"id\":\"ms-2\",\"input\":{\"targetDate\":\"2026-10-15\"}}", vars);
}

test "milestone delete requires confirmation" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneDelete", fixtures.milestone_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "ms-2" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "milestone delete: confirmation required; re-run with --yes to proceed\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "milestone delete removes one milestone" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneDelete", fixtures.milestone_delete_response);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "ms-2", "--yes" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("milestone delete: deleted ms-2\n", capture.stdout);
    // A single-target run stays quiet: the batch summary is a bulk-only line.
    try std.testing.expectEqualStrings("", capture.stderr);
}

test "milestone delete dry run validates without mutating" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // No ProjectMilestoneDelete fixture: a mutation would fail the run outright.
    try server.set("ProjectMilestoneDeleteLookup", fixtures.milestone_delete_lookup);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "ms-2", "--dry-run" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "milestone delete: dry run; would delete \"Beta\" (id ms-2)\n",
        capture.stdout,
    );
    try std.testing.expectEqual(@as(usize, 1), server.request_count);
}

test "milestone delete reports a failed payload" {
    const allocator = std.testing.allocator;
    const failure =
        \\{
        \\  "data": {
        \\    "projectMilestoneDelete": { "success": false }
        \\  }
        \\}
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("ProjectMilestoneDelete", failure);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "ms-2", "--yes" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone delete: request failed\n", capture.stderr);
}

test "milestone rejects an unknown subcommand" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{"archive"};
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("milestone: unknown command: archive\n", capture.stderr);
}

test "parse milestone list options" {
    const args = [_][]const u8{
        "--project=Roadmap", "--limit",    "10",      "--max-items", "40",
        "--cursor",          "cursor-abc", "--pages", "3",           "--fields",
        "id,name",           "--quiet",    "--plain",
    };
    const opts = try milestones_cmd.parseListOptions(args[0..]);
    try std.testing.expectEqualStrings("Roadmap", opts.project.?);
    try std.testing.expectEqual(@as(usize, 10), opts.limit);
    try std.testing.expectEqual(@as(usize, 40), opts.max_items.?);
    try std.testing.expectEqualStrings("cursor-abc", opts.cursor.?);
    try std.testing.expectEqual(@as(usize, 3), opts.pages.?);
    try std.testing.expect(!opts.all);
    try std.testing.expectEqualStrings("id,name", opts.fields.?);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.plain);

    // --project is optional now: an argument-free list is a workspace-wide one.
    const bare = [_][]const u8{};
    const bare_opts = try milestones_cmd.parseListOptions(bare[0..]);
    try std.testing.expect(bare_opts.project == null);
    try std.testing.expectEqual(@as(usize, 50), bare_opts.limit);
    try std.testing.expectEqual(@as(?usize, null), bare_opts.pages);

    const bad_limit = [_][]const u8{ "--limit", "0" };
    try std.testing.expectError(error.InvalidLimit, milestones_cmd.parseListOptions(bad_limit[0..]));

    const bad_pages = [_][]const u8{ "--pages", "0" };
    try std.testing.expectError(error.InvalidPageCount, milestones_cmd.parseListOptions(bad_pages[0..]));

    const unknown = [_][]const u8{"--nope"};
    try std.testing.expectError(error.UnknownFlag, milestones_cmd.parseListOptions(unknown[0..]));
}

test "parse milestone create options" {
    const args = [_][]const u8{
        "--project",     "p1",         "--name=Beta",      "--description-file", "notes.md",
        "--target-date", "2026-09-30", "--sort-order=2.5", "--force",
    };
    const opts = try milestones_cmd.parseCreateOptions(args[0..]);
    try std.testing.expectEqualStrings("p1", opts.project.?);
    try std.testing.expectEqualStrings("Beta", opts.name.?);
    try std.testing.expectEqualStrings("notes.md", opts.description_file.?);
    try std.testing.expectEqualStrings("2026-09-30", opts.target_date.?);
    try std.testing.expectEqualStrings("2.5", opts.sort_order.?);
    try std.testing.expect(opts.yes);
}

test "parse milestone delete options accept bulk flags" {
    const args = [_][]const u8{ "--bulk", "a,b", "--yes", "--dry-run" };
    const opts = try milestones_cmd.parseDeleteOptions(args[0..]);
    try std.testing.expectEqualStrings("a,b", opts.bulk.ids.?);
    try std.testing.expect(opts.bulk.requested());
    try std.testing.expect(opts.yes);
    try std.testing.expect(opts.dry_run);
    try std.testing.expect(opts.milestone_id == null);

    const positional = [_][]const u8{ "ms-2", "--bulk-stdin" };
    const mixed = try milestones_cmd.parseDeleteOptions(positional[0..]);
    try std.testing.expectEqualStrings("ms-2", mixed.milestone_id.?);
    try std.testing.expect(mixed.bulk.stdin);
}

// ---------------------------------------------------------------------------
// bulk executor
// ---------------------------------------------------------------------------

const IssueDeleteRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    json_output: bool = false,
};

fn runIssueDelete(r: *const IssueDeleteRunner) !u8 {
    return issue_delete_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .retries = 0,
        .timeout_ms = 10_000,
        .json_output = r.json_output,
    });
}

const delete_lin300 =
    \\{ "data": { "issueDelete": { "success": true, "entity": { "id": "issue-1", "identifier": "LIN-300" }, "lastSyncId": 1 } } }
;
const delete_lin301 =
    \\{ "data": { "issueDelete": { "success": true, "entity": { "id": "issue-2", "identifier": "LIN-301" }, "lastSyncId": 2 } } }
;
const delete_lin302 =
    \\{ "data": { "issueDelete": { "success": true, "entity": { "id": "issue-3", "identifier": "LIN-302" }, "lastSyncId": 3 } } }
;
const delete_lin301_failed =
    \\{ "data": { "issueDelete": { "success": false, "entity": { "id": "issue-2", "identifier": "LIN-301" }, "lastSyncId": 2 } } }
;
const lookup_lin300 =
    \\{ "data": { "issue": { "id": "issue-1", "identifier": "LIN-300", "title": "First" } } }
;
const lookup_lin301 =
    \\{ "data": { "issue": { "id": "issue-2", "identifier": "LIN-301", "title": "Second" } } }
;

test "issue delete bulk deduplicates ids before mutating" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueDelete", &.{ delete_lin300, delete_lin301, delete_lin302 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk", "LIN-300, LIN-301, LIN-300", "--yes", "--quiet" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // The repeated id is dropped, so the third fixture is never reached.
    try std.testing.expectEqualStrings("LIN-300\nLIN-301\n", capture.stdout);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
    try std.testing.expectEqualStrings(
        "issue delete: bulk complete; 2 succeeded, 0 failed\n",
        capture.stderr,
    );
}

test "issue delete bulk keeps going after a failed item and exits non-zero" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueDelete", &.{ delete_lin300, delete_lin301_failed, delete_lin302 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk", "LIN-300,LIN-301,LIN-302", "--yes", "--quiet" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    // The failure is in the middle, so the third item still ran.
    try std.testing.expectEqualStrings("LIN-300\nLIN-302\n", capture.stdout);
    try std.testing.expectEqual(@as(usize, 3), server.request_count);
    try std.testing.expectEqualStrings(
        "issue delete: delete failed for LIN-301\n" ++
            "issue delete: bulk complete; 2 succeeded, 1 failed\n",
        capture.stderr,
    );
}

test "issue delete bulk dry run resolves every item without mutating" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // No IssueDelete fixture: any mutation would fail with MissingFixture.
    try server.setSequence("IssueDeleteLookup", &.{ lookup_lin300, lookup_lin301 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk", "LIN-300,LIN-301", "--dry-run" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue delete: dry run; would delete LIN-300 (id issue-1) title \"First\"\n" ++
            "issue delete: dry run; would delete LIN-301 (id issue-2) title \"Second\"\n",
        capture.stdout,
    );
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
    try std.testing.expectEqualStrings(
        "issue delete: bulk complete; 2 succeeded, 0 failed\n",
        capture.stderr,
    );
}

test "issue delete bulk reads ids from stdin" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueDelete", &.{ delete_lin300, delete_lin301 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk-stdin", "--yes", "--quiet" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutputWithStdin(
        allocator,
        &runner,
        runIssueDelete,
        "LIN-300\nLIN-301\n\n",
    );
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("LIN-300\nLIN-301\n", capture.stdout);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
}

test "issue delete bulk reads ids from a file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ids_file = try tmp.dir.createFile(test_io, "ids.txt", .{ .read = true, .truncate = true });
    defer ids_file.close(test_io);
    try ids_file.writeStreamingAll(test_io, "LIN-300\nLIN-301\n");
    const ids_path = try tmp.dir.realPathFileAlloc(test_io, "ids.txt", allocator);
    defer allocator.free(ids_path);

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueDelete", &.{ delete_lin300, delete_lin301 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk-file", ids_path, "--yes", "--quiet" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("LIN-300\nLIN-301\n", capture.stdout);
}

test "issue delete bulk emits one json array and suppresses the summary" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("IssueDelete", &.{ delete_lin300, delete_lin301 });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk", "LIN-300,LIN-301", "--yes" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..], .json_output = true };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stderr);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    const first = parsed.value.array.items[0].object.get("issueDelete") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("LIN-300", first.object.get("entity").?.object.get("identifier").?.string);
}

test "issue delete rejects an identifier combined with bulk" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "LIN-300", "--bulk", "LIN-301", "--yes" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue delete: pass an identifier or --bulk, not both\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "issue delete rejects two bulk sources at once" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "--bulk", "LIN-300", "--bulk-stdin", "--yes" };
    const runner = IssueDeleteRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runIssueDelete);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "issue delete: use only one of --bulk, --bulk-file, or --bulk-stdin\n",
        capture.stderr,
    );
}

test "milestone delete bulk dedupes and summarises" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("ProjectMilestoneDelete", &.{
        fixtures.milestone_delete_response,
        fixtures.milestone_delete_response,
        "{ \"data\": { \"projectMilestoneDelete\": { \"success\": false } } }",
    });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ "delete", "--bulk", "ms-1\nms-2\nms-1\nms-3", "--yes", "--quiet" };
    const runner = MilestoneRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runMilestone);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings("ms-1\nms-2\n", capture.stdout);
    try std.testing.expectEqual(@as(usize, 3), server.request_count);
    try std.testing.expectEqualStrings(
        "milestone delete: request failed\n" ++
            "milestone delete: bulk complete; 2 succeeded, 1 failed\n",
        capture.stderr,
    );
}

test "bulk parseFlag consumes each spelling" {
    var opts = bulk.Options{};
    const inline_args = [_][]const u8{"--bulk=a,b"};
    try std.testing.expectEqual(@as(usize, 1), try bulk.parseFlag(&opts, inline_args[0..]));
    try std.testing.expectEqualStrings("a,b", opts.ids.?);

    var file_opts = bulk.Options{};
    const file_args = [_][]const u8{ "--bulk-file", "ids.txt" };
    try std.testing.expectEqual(@as(usize, 2), try bulk.parseFlag(&file_opts, file_args[0..]));
    try std.testing.expectEqualStrings("ids.txt", file_opts.file.?);

    var stdin_opts = bulk.Options{};
    const stdin_args = [_][]const u8{"--bulk-stdin"};
    try std.testing.expectEqual(@as(usize, 1), try bulk.parseFlag(&stdin_opts, stdin_args[0..]));
    try std.testing.expect(stdin_opts.stdin);

    var other = bulk.Options{};
    const other_args = [_][]const u8{"--yes"};
    try std.testing.expectEqual(@as(usize, 0), try bulk.parseFlag(&other, other_args[0..]));
    try std.testing.expect(!other.requested());

    var missing = bulk.Options{};
    const missing_args = [_][]const u8{"--bulk"};
    try std.testing.expectError(error.MissingValue, bulk.parseFlag(&missing, missing_args[0..]));
}

test "bulk collect dedupes and preserves first-seen order" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    var targets = (try bulk.collect(
        allocator,
        test_io,
        .{ .ids = "b, a,b\nc" },
        &buffer.writer,
        "test",
    )).?;
    defer targets.deinit();

    try std.testing.expectEqual(@as(usize, 3), targets.items.len);
    try std.testing.expectEqualStrings("b", targets.items[0]);
    try std.testing.expectEqualStrings("a", targets.items[1]);
    try std.testing.expectEqualStrings("c", targets.items[2]);
    try std.testing.expectEqualStrings("", buffer.written());

    try std.testing.expect(try bulk.collect(allocator, test_io, .{}, &buffer.writer, "test") == null);
}

test "bulk collect rejects combined sources and empty input" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    try std.testing.expectError(common.CommandError.CommandFailed, bulk.collect(
        allocator,
        test_io,
        .{ .ids = "a", .stdin = true },
        &buffer.writer,
        "test",
    ));
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "use only one of") != null);

    buffer.clearRetainingCapacity();
    try std.testing.expectError(common.CommandError.CommandFailed, bulk.collect(
        allocator,
        test_io,
        .{ .ids = " , \n" },
        &buffer.writer,
        "test",
    ));
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "contained no ids") != null);
}

test "bulk execute records every outcome and keeps running" {
    const allocator = std.testing.allocator;

    const Recorder = struct {
        seen: *std.ArrayListUnmanaged([]const u8),
        allocator: std.mem.Allocator,

        fn call(self: @This(), index: usize, target: []const u8) !bulk.Outcome {
            _ = index;
            try self.seen.append(self.allocator, target);
            return if (std.mem.eql(u8, target, "bad")) .failed else .succeeded;
        }
    };

    var seen = std.ArrayListUnmanaged([]const u8).empty;
    defer seen.deinit(allocator);

    const targets = [_][]const u8{ "one", "bad", "two" };
    const summary = try bulk.execute(
        Recorder,
        .{ .seen = &seen, .allocator = allocator },
        targets[0..],
        Recorder.call,
    );

    try std.testing.expectEqual(@as(usize, 2), summary.succeeded);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 3), summary.total());
    try std.testing.expectEqual(@as(u8, 1), summary.exitCode());
    try std.testing.expectEqual(@as(usize, 3), seen.items.len);
    try std.testing.expectEqualStrings("two", seen.items[2]);

    const clean = bulk.Summary{ .succeeded = 2 };
    try std.testing.expectEqual(@as(u8, 0), clean.exitCode());
}

test "bulk printSummary renders both counters" {
    const allocator = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    try bulk.printSummary(&buffer.writer, "issue delete", .{ .succeeded = 2, .failed = 1 });
    try std.testing.expectEqualStrings(
        "issue delete: bulk complete; 2 succeeded, 1 failed\n",
        buffer.written(),
    );
}

// ---------------------------------------------------------------------------
// gql --paginate
// ---------------------------------------------------------------------------

const GqlArgsRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: [][]const u8,
    json_output: bool = false,
};

fn runGqlArgs(r: *const GqlArgsRunner) !u8 {
    return gql.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = r.args,
        .json_output = r.json_output,
        .retries = 0,
        .timeout_ms = 10_000,
    });
}

const paginated_query =
    "query Issues($after: String) { issues(first: 2, after: $after) " ++
    "{ nodes { id } pageInfo { hasNextPage endCursor } } }";

const issues_page_one =
    \\{ "data": { "issues": { "nodes": [ { "id": "i1" }, { "id": "i2" } ], "pageInfo": { "hasNextPage": true, "endCursor": "c1" } } } }
;
const issues_page_two =
    \\{ "data": { "issues": { "nodes": [ { "id": "i3" } ], "pageInfo": { "hasNextPage": false, "endCursor": "c2" } } } }
;
const issues_page_endless_a =
    \\{ "data": { "issues": { "nodes": [ { "id": "a1" }, { "id": "a2" } ], "pageInfo": { "hasNextPage": true, "endCursor": "ca" } } } }
;
const issues_page_endless_b =
    \\{ "data": { "issues": { "nodes": [ { "id": "b1" }, { "id": "b2" } ], "pageInfo": { "hasNextPage": true, "endCursor": "cb" } } } }
;
const issues_page_endless_c =
    \\{ "data": { "issues": { "nodes": [ { "id": "c1" }, { "id": "c2" } ], "pageInfo": { "hasNextPage": true, "endCursor": "cc" } } } }
;

test "gql paginate merges every page into one document" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Issues", &.{ issues_page_one, issues_page_two });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ paginated_query, "--paginate", "--data-only", "--operation-name", "Issues" };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqualStrings("", capture.stderr);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const issues = parsed.value.object.get("issues") orelse return error.TestExpectedResult;
    const nodes = issues.object.get("nodes") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), nodes.array.items.len);
    try std.testing.expectEqualStrings("i1", nodes.array.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("i3", nodes.array.items[2].object.get("id").?.string);

    // The merged pageInfo is the last page's, so a consumer sees the walk ended.
    const page_info = issues.object.get("pageInfo") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(false, page_info.object.get("hasNextPage").?.bool);
    try std.testing.expectEqualStrings("c2", page_info.object.get("endCursor").?.string);

    // Page two must have carried page one's cursor.
    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("{\"after\":\"c1\"}", vars);
}

test "gql paginate keeps the caller's variables when adding the cursor" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Issues", &.{ issues_page_one, issues_page_two });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        paginated_query,           "--paginate", "--data-only",
        "--operation-name",        "Issues",     "--vars",
        "{\"teamId\":\"team-1\"}",
    };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    const recorded = server.lastRequest() orelse return error.TestExpectedResult;
    const vars = recorded.variables_json orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("{\"teamId\":\"team-1\",\"after\":\"c1\"}", vars);
}

test "gql paginate stops at the max-pages bound and says so" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    // Every page claims another page follows; only the bound ends the walk.
    try server.setSequence("Issues", &.{ issues_page_endless_a, issues_page_endless_b, issues_page_endless_c });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        paginated_query, "--paginate",       "--max-pages", "2",
        "--data-only",   "--operation-name", "Issues",
    };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
    try std.testing.expectEqualStrings(
        "gql: --paginate stopped after 2 pages (--max-pages 2); more results remain\n",
        capture.stderr,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const issues = parsed.value.object.get("issues") orelse return error.TestExpectedResult;
    const nodes = issues.object.get("nodes") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 4), nodes.array.items.len);
    // hasNextPage stays true, which is how a caller knows the result is partial.
    try std.testing.expectEqual(true, issues.object.get("pageInfo").?.object.get("hasNextPage").?.bool);
}

test "gql paginate walks a nested connection" {
    const allocator = std.testing.allocator;
    const nested_query =
        "query Milestones($after: String) { project(id: \"p1\") { id projectMilestones(first: 1, after: $after) " ++
        "{ nodes { id } pageInfo { hasNextPage endCursor } } } }";
    const nested_page_one =
        \\{ "data": { "project": { "id": "p1", "projectMilestones": { "nodes": [ { "id": "ms-1" } ], "pageInfo": { "hasNextPage": true, "endCursor": "n1" } } } } }
    ;
    const nested_page_two =
        \\{ "data": { "project": { "id": "p1", "projectMilestones": { "nodes": [ { "id": "ms-2" } ], "pageInfo": { "hasNextPage": false, "endCursor": "n2" } } } } }
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Milestones", &.{ nested_page_one, nested_page_two });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ nested_query, "--paginate", "--data-only", "--operation-name", "Milestones" };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const project = parsed.value.object.get("project") orelse return error.TestExpectedResult;
    // Sibling fields on the rebuilt path survive the merge.
    try std.testing.expectEqualStrings("p1", project.object.get("id").?.string);
    const nodes = project.object.get("projectMilestones").?.object.get("nodes") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 2), nodes.array.items.len);
    try std.testing.expectEqualStrings("ms-2", nodes.array.items[1].object.get("id").?.string);
}

test "gql paginate requires an after variable" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", issues_page_one);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "query Issues { issues(first: 2) { nodes { id } pageInfo { hasNextPage endCursor } } }",
        "--paginate",
        "--operation-name",
        "Issues",
    };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "gql: --paginate requires the query to declare an $after variable\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "gql paginate requires a page info selection" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", issues_page_one);

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "query Issues($after: String) { issues(first: 2, after: $after) { nodes { id } } }",
        "--paginate",
        "--operation-name",
        "Issues",
    };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "gql: --paginate requires the query to select pageInfo { hasNextPage endCursor }\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "gql paginate refuses a mutation document" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{
        "mutation Bulk($after: String) { thing(after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } }",
        "--paginate",
        "--yes",
        "--operation-name",
        "Bulk",
    };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "gql: --paginate cannot be used with a mutation document\n",
        capture.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), server.request_count);
}

test "gql paginate errors when the response has no connection" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.set("Issues", "{ \"data\": { \"viewer\": { \"id\": \"u1\" } } }");

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ paginated_query, "--paginate", "--operation-name", "Issues" };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqualStrings(
        "gql: --paginate found no connection selecting both 'nodes' and 'pageInfo' in the response\n",
        capture.stderr,
    );
    try std.testing.expectEqualStrings("", capture.stdout);
}

test "gql paginate surfaces a failed page instead of merging" {
    const allocator = std.testing.allocator;
    const failing_page =
        \\{ "errors": [ { "message": "rate limited" } ] }
    ;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Issues", &.{ issues_page_one, failing_page });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ paginated_query, "--paginate", "--operation-name", "Issues" };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
    try std.testing.expectEqualStrings("gql: rate limited\n", capture.stderr);
}

test "gql without paginate still returns a single page" {
    const allocator = std.testing.allocator;

    var server = mock_graphql.MockServer.init(allocator);
    defer server.deinit();
    var scope = mock_graphql.useServer(&server);
    defer scope.restore();
    try server.setSequence("Issues", &.{ issues_page_one, issues_page_two });

    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var args = [_][]const u8{ paginated_query, "--data-only", "--operation-name", "Issues" };
    const runner = GqlArgsRunner{ .allocator = allocator, .cfg = &cfg, .args = args[0..] };

    const capture = try captureOutput(allocator, &runner, runGqlArgs);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expectEqual(@as(usize, 1), server.request_count);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("issues").?.object.get("nodes") orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 2), nodes.array.items.len);
}

test "parse gql paginate options" {
    const defaults = try gql.parseOptions(&.{});
    try std.testing.expect(!defaults.paginate);
    try std.testing.expectEqual(gql.default_max_pages, defaults.max_pages);

    const args = [_][]const u8{ "--paginate", "--max-pages", "5" };
    const opts = try gql.parseOptions(args[0..]);
    try std.testing.expect(opts.paginate);
    try std.testing.expectEqual(@as(usize, 5), opts.max_pages);

    const inline_args = [_][]const u8{"--max-pages=3"};
    const inline_opts = try gql.parseOptions(inline_args[0..]);
    try std.testing.expectEqual(@as(usize, 3), inline_opts.max_pages);

    const zero = [_][]const u8{ "--max-pages", "0" };
    try std.testing.expectError(error.InvalidMaxPages, gql.parseOptions(zero[0..]));
}

test "gql tells an after declaration apart from an after usage" {
    try std.testing.expect(gql.declaresAfterVariable("query Q($after: String) { x(after: $after) { y } }"));
    try std.testing.expect(gql.declaresAfterVariable("query Q($after:String){x}"));
    // Referenced but never declared: the server would reject it, so we do first.
    try std.testing.expect(!gql.declaresAfterVariable("query Q { x(after: $after) { y } }"));
    // A longer name that merely starts with `after` is not a match.
    try std.testing.expect(!gql.declaresAfterVariable("query Q($afterCursor: String) { x }"));

    try std.testing.expect(gql.selectsPageInfo("{ pageInfo { hasNextPage endCursor } }"));
    try std.testing.expect(!gql.selectsPageInfo("{ pageInfo { hasNextPage } }"));
}

// ---------------------------------------------------------------------------
// Credential provider chain
// ---------------------------------------------------------------------------

// Distinct per backend so any test that adopts the wrong one fails loudly
// instead of comparing a key against itself.
const fake_env_key = "envKEY0123456789abc";
const fake_helper_key = "helperKEY0123456789";
const fake_keychain_key = "keychainKEY01234567";
const fake_file_key = "fileKEY0123456789ab";

/// A `Config` with no key at all, or with one that came from the config file.
/// `config.load` is bypassed on purpose: these tests exercise the chain, not
/// the file parser.
fn makeChainConfig(allocator: std.mem.Allocator, file_key: ?[]const u8) !config.Config {
    var cfg = config.Config{ .allocator = allocator, .io = test_io, .environ = testEnviron() };
    cfg.team_cache = std.StringHashMap([]const u8).init(allocator);
    errdefer cfg.deinit();
    if (file_key) |key| try cfg.setApiKey(key);
    return cfg;
}

const ChainResult = struct {
    cfg: config.Config,
    diagnostics: std.Io.Writer.Allocating,

    fn deinit(self: *ChainResult) void {
        self.cfg.deinit();
        self.diagnostics.deinit();
    }

    fn stderrText(self: *ChainResult) []const u8 {
        return self.diagnostics.written();
    }
};

test "credentials: the environment outranks every other backend" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();
    try cfg.setApiKeyFromEnv(fake_env_key);
    try cfg.setCredentialHelper(&.{ "op", "read", "op://Private/Linear/api-key" });

    // Scripted but never consumed: an environment key must short-circuit the
    // chain before anything is spawned.
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);

    try std.testing.expectEqual(config.KeySource.environment, cfg.key_source);
    try std.testing.expectEqualStrings(fake_env_key, cfg.api_key.?);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expectEqualStrings("", diagnostics.written());
}

test "credentials: a configured helper outranks the keychain" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();
    try cfg.setCredentialHelper(&.{ "op", "read", "op://Private/Linear/api-key" });

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);

    try std.testing.expectEqual(config.KeySource.helper, cfg.key_source);
    try std.testing.expectEqualStrings(fake_helper_key, cfg.api_key.?);
    // Exactly one spawn: the keychain is never probed once a helper answers,
    // which is what keeps the secret's location from fragmenting.
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try expectCall(&fake, 0, &.{ "op", "read", "op://Private/Linear/api-key" });
    try std.testing.expectEqualStrings("", diagnostics.written());
}

test "credentials: the keychain outranks the config file" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_keychain_key ++ "\n" }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);

    if (credentials.keychain_supported) {
        try std.testing.expectEqual(config.KeySource.keychain, cfg.key_source);
        try std.testing.expectEqualStrings(fake_keychain_key, cfg.api_key.?);
        try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
        // No deprecation warning: the file key was not what got used.
        try std.testing.expectEqualStrings("", diagnostics.written());
    } else {
        // The backend does not exist off macOS; there is no silent downgrade
        // to some weaker local store, the file simply wins.
        try std.testing.expectEqual(config.KeySource.file, cfg.key_source);
        try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
    // Either way the persisted key is untouched.
    try std.testing.expectEqualStrings(fake_file_key, cfg.file_api_key.?);
}

test "credentials: the config file is the last resort and says so" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();

    // `security` exits non-zero when the item does not exist.
    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .exit_code = 44, .stderr = "The specified item could not be found in the keychain.\n" }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);

    try std.testing.expectEqual(config.KeySource.file, cfg.key_source);
    try std.testing.expectEqualStrings(fake_file_key, cfg.api_key.?);
    const expected_calls: usize = if (credentials.keychain_supported) 1 else 0;
    try std.testing.expectEqual(expected_calls, fake.calls.items.len);

    // A missing keychain item is not a diagnostic, but using the plaintext
    // file is.
    const text = diagnostics.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "plaintext") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auth migrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, fake_file_key) == null);
}

test "credentials: no backend leaves the chain empty" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, null);
    defer cfg.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .exit_code = 44 }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);

    try std.testing.expectEqual(config.KeySource.none, cfg.key_source);
    try std.testing.expect(cfg.api_key == null);
    try std.testing.expectEqualStrings("", diagnostics.written());
}

test "credentials: a null runner leaves the chain exactly as loaded" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();
    try cfg.setCredentialHelper(&.{"op"});

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    try credentials.resolve(&cfg, null, test_io, &diagnostics.writer);

    try std.testing.expectEqual(config.KeySource.file, cfg.key_source);
    try std.testing.expectEqualStrings(fake_file_key, cfg.api_key.?);
}

/// Runs the chain with a helper configured and a single scripted step.
fn resolveWithHelper(
    allocator: std.mem.Allocator,
    step: FakeProcess.Step,
    file_key: ?[]const u8,
    out_calls: *usize,
) !ChainResult {
    var cfg = try makeChainConfig(allocator, file_key);
    errdefer cfg.deinit();
    try cfg.setCredentialHelper(&.{ "op", "read", "op://Private/Linear/api-key" });

    const script = [_]FakeProcess.Step{step};
    var fake = FakeProcess{ .allocator = allocator, .script = script[0..] };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    errdefer diagnostics.deinit();

    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);
    out_calls.* = fake.calls.items.len;

    return .{ .cfg = cfg, .diagnostics = diagnostics };
}

test "credentials: a failing helper never falls back to the plaintext file key" {
    const allocator = std.testing.allocator;

    var calls: usize = 0;
    var result = try resolveWithHelper(
        allocator,
        .{ .exit_code = 3, .stderr = "op: could not read item\n" },
        fake_file_key,
        &calls,
    );
    defer result.deinit();

    // Explicit configuration that fails must fail loudly. Quietly using the
    // plaintext key the helper was configured to replace would be the exact
    // silent degradation this chain exists to prevent.
    try std.testing.expectEqual(config.KeySource.helper_failed, result.cfg.key_source);
    try std.testing.expect(result.cfg.api_key == null);
    // The key on disk survives, so `auth migrate` can still find it.
    try std.testing.expectEqualStrings(fake_file_key, result.cfg.file_api_key.?);
    // The keychain is not tried either; the chain stops at the failure.
    try std.testing.expectEqual(@as(usize, 1), calls);

    const text = result.stderrText();
    try std.testing.expect(std.mem.indexOf(u8, text, "exited 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "op: could not read item") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, fake_file_key) == null);
}

test "credentials: a missing helper binary is reported by name" {
    const allocator = std.testing.allocator;

    var calls: usize = 0;
    var result = try resolveWithHelper(allocator, .{ .fail = git.Error.BinaryNotFound }, null, &calls);
    defer result.deinit();

    try std.testing.expectEqual(config.KeySource.helper_failed, result.cfg.key_source);
    const text = result.stderrText();
    try std.testing.expect(std.mem.indexOf(u8, text, "was not found on PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "op read op://Private/Linear/api-key") != null);
}

test "credentials: a helper that times out is reported, not retried" {
    const allocator = std.testing.allocator;

    var calls: usize = 0;
    var result = try resolveWithHelper(allocator, .{ .fail = git.Error.TimedOut }, null, &calls);
    defer result.deinit();

    try std.testing.expectEqual(config.KeySource.helper_failed, result.cfg.key_source);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(std.mem.indexOf(u8, result.stderrText(), "did not finish in time") != null);
}

test "credentials: a helper that prints nothing is a failure, not an empty store" {
    const allocator = std.testing.allocator;

    var calls: usize = 0;
    var result = try resolveWithHelper(allocator, .{ .stdout = "  \n" }, fake_file_key, &calls);
    defer result.deinit();

    try std.testing.expectEqual(config.KeySource.helper_failed, result.cfg.key_source);
    try std.testing.expect(result.cfg.api_key == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderrText(), "produced no output") != null);
}

test "credentials: a helper that prints a malformed key is rejected before use" {
    const allocator = std.testing.allocator;

    var calls: usize = 0;
    // A CR would let a tampered secret store inject an extra request header.
    var result = try resolveWithHelper(allocator, .{ .stdout = "abcd\rX-Evil: 1\n" }, null, &calls);
    defer result.deinit();

    try std.testing.expectEqual(config.KeySource.helper_failed, result.cfg.key_source);
    try std.testing.expect(result.cfg.api_key == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderrText(), "not a valid API key") != null);
}

test "credentials: a helper that floods stdout is bounded" {
    const allocator = std.testing.allocator;

    const oversized = "a" ** (config.max_api_key_len + 1);
    var calls: usize = 0;
    var result = try resolveWithHelper(allocator, .{ .stdout = oversized }, null, &calls);
    defer result.deinit();

    try std.testing.expectEqual(config.KeySource.helper_failed, result.cfg.key_source);
    const text = result.stderrText();
    try std.testing.expect(std.mem.indexOf(u8, text, "produced more than") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, oversized) == null);
}

test "credentials: a helper diagnostic never quotes the helper's stdout" {
    const allocator = std.testing.allocator;

    // The secret is where it always is on a failure: still on stdout.
    var calls: usize = 0;
    var result = try resolveWithHelper(
        allocator,
        .{ .exit_code = 1, .stdout = fake_helper_key, .stderr = "op: session expired\n" },
        null,
        &calls,
    );
    defer result.deinit();

    const text = result.stderrText();
    try std.testing.expect(std.mem.indexOf(u8, text, "op: session expired") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, fake_helper_key) == null);
}

test "credentials: a helper's stderr cannot smuggle control bytes into the terminal" {
    const allocator = std.testing.allocator;

    var calls: usize = 0;
    var result = try resolveWithHelper(
        allocator,
        .{ .exit_code = 1, .stderr = "boom\x1b[31mred\n second line\n" },
        null,
        &calls,
    );
    defer result.deinit();

    const text = result.stderrText();
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b") == null);
    // Only the first line is quoted.
    try std.testing.expect(std.mem.indexOf(u8, text, "second line") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "boom") != null);
}

test "credentials: a helper-sourced key is never written to disk" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setCredentialHelper(&.{"op"});

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();
    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);
    try std.testing.expectEqual(config.KeySource.helper, cfg.key_source);

    try cfg.save(allocator, config_path);

    const written = try tmp.dir.readFileAlloc(test_io, "config.json", allocator, .limited(64 * 1024));
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_helper_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"api_key\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") != null);
}

test "credentials: a keychain-sourced key never deletes the key already on disk" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setApiKey(fake_file_key);
    try cfg.save(allocator, config_path);

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_keychain_key ++ "\n" }},
    };
    defer fake.deinit();

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();
    try credentials.resolve(&cfg, fake.runner(), test_io, &diagnostics.writer);

    // Same invariant `LINEAR_API_KEY` has: a provider-sourced key neither gets
    // persisted nor drops the key already on disk.
    try cfg.save(allocator, config_path);
    const written = try tmp.dir.readFileAlloc(test_io, "config.json", allocator, .limited(64 * 1024));
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_keychain_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) != null);
}

// ---------------------------------------------------------------------------
// Keychain argv
// ---------------------------------------------------------------------------

test "credentials: the keychain read keeps everything sensitive off argv" {
    const allocator = std.testing.allocator;

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_keychain_key ++ "\n" }},
    };
    defer fake.deinit();

    const outcome = try credentials.readKeychain(fake.runner(), allocator, test_io);
    defer outcome.deinit(allocator);

    try std.testing.expectEqualStrings(fake_keychain_key, outcome.key);
    try expectCall(&fake, 0, &.{
        "/usr/bin/security",
        "find-generic-password",
        "-w",
        "-s",
        "linear-cli",
        "-a",
        "api-key",
    });
    // The read has no secret to hide: it comes back on stdout.
    try std.testing.expectEqualStrings("", fake.inputs.items[0]);
}

test "credentials: a missing keychain item reads as absent, not as a failure" {
    const allocator = std.testing.allocator;

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .exit_code = 44, .stderr = "The specified item could not be found in the keychain.\n" }},
    };
    defer fake.deinit();

    const outcome = try credentials.readKeychain(fake.runner(), allocator, test_io);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome == .absent);
}

test "credentials: the keychain write puts the key on stdin, never on argv" {
    const allocator = std.testing.allocator;

    var fake = FakeProcess{ .allocator = allocator, .script = &.{.{}} };
    defer fake.deinit();

    const outcome = try credentials.writeKeychain(fake.runner(), allocator, test_io, fake_keychain_key);
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .absent);

    // `security add-generic-password -w <secret>` would publish the key in the
    // process table; the interactive form keeps it in a pipe instead.
    try expectCall(&fake, 0, &.{ "/usr/bin/security", "-i" });
    try std.testing.expect(std.mem.indexOf(u8, fake.calls.items[0], fake_keychain_key) == null);

    const input = fake.inputs.items[0];
    try std.testing.expectEqualStrings(
        "add-generic-password -a api-key -s linear-cli -U -w " ++ fake_keychain_key ++ "\n",
        input,
    );
}

test "credentials: the keychain write refuses a key that security would read as a flag" {
    const allocator = std.testing.allocator;

    var fake = FakeProcess{ .allocator = allocator, .script = &.{.{}} };
    defer fake.deinit();

    // Valid per `isValidApiKey`, but `security`'s tokenizer would take it for
    // an option. Refused outright rather than papered over with argv.
    try std.testing.expectError(
        credentials.KeychainWriteError.LeadingDash,
        credentials.writeKeychain(fake.runner(), allocator, test_io, "-notAKey12345"),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "credentials: a keychain write that fails is reported by exit status" {
    const allocator = std.testing.allocator;

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .exit_code = 45, .stderr = "User interaction is not allowed.\n" }},
    };
    defer fake.deinit();

    const outcome = try credentials.writeKeychain(fake.runner(), allocator, test_io, fake_keychain_key);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome == .failure);
    try std.testing.expectEqual(@as(u8, 45), outcome.failure.exit_code);

    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();
    try credentials.printFailure(outcome.failure, "/usr/bin/security", &diagnostics.writer, "auth migrate");
    const text = diagnostics.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "exited 45") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, fake_keychain_key) == null);
}

// ---------------------------------------------------------------------------
// credential_helper config schema
// ---------------------------------------------------------------------------

test "config stores credential_helper as an argv array" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    defer cfg.deinit();
    try cfg.setCredentialHelper(&.{ "op", "read", "op://Private/Linear/api-key" });
    try cfg.save(allocator, config_path);

    var reloaded = try config.load(allocator, test_io, testEnviron(), config_path);
    defer reloaded.deinit();

    const argv = reloaded.credential_helper.?;
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("op", argv[0]);
    try std.testing.expectEqualStrings("read", argv[1]);
    try std.testing.expectEqualStrings("op://Private/Linear/api-key", argv[2]);
}

test "config splits a bare credential_helper string with no shell semantics" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, null);
    defer cfg.deinit();

    const body =
        \\{"credential_helper": "sh -c 'echo hi' > /tmp/x"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try cfg.setCredentialHelperValue(parsed.value.object.get("credential_helper").?);

    // Whitespace splitting only: quotes and redirections are ordinary bytes
    // inside argv elements, not syntax. Nothing here is ever handed to a shell.
    const argv = cfg.credential_helper.?;
    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("'echo", argv[2]);
    try std.testing.expectEqualStrings("hi'", argv[3]);
    try std.testing.expectEqualStrings(">", argv[4]);
    try std.testing.expectEqualStrings("/tmp/x", argv[5]);
}

test "config rejects a malformed credential_helper" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, null);
    defer cfg.deinit();

    const cases = [_][]const u8{
        \\{"credential_helper": []}
        ,
        \\{"credential_helper": ""}
        ,
        \\{"credential_helper": "   "}
        ,
        \\{"credential_helper": [1, 2]}
        ,
        \\{"credential_helper": {"cmd": "op"}}
        ,
        \\{"credential_helper": ["op", ""]}
        ,
    };

    for (cases) |body| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const value = parsed.value.object.get("credential_helper").?;
        try std.testing.expectError(
            error.InvalidCredentialHelper,
            normalizeHelperError(cfg.setCredentialHelperValue(value)),
        );
        try std.testing.expect(cfg.credential_helper == null);
    }
}

/// Collapses the credential-helper error set so one table can cover every
/// rejection without asserting on which specific variant fired.
fn normalizeHelperError(result: anytype) error{InvalidCredentialHelper}!void {
    result catch return error.InvalidCredentialHelper;
    return;
}

test "config load rejects a config file with a malformed credential_helper" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    defer allocator.free(config_path);

    try tmp.dir.writeFile(test_io, .{ .sub_path = "config.json", .data =
        \\{"credential_helper": 42}
    });

    try std.testing.expectError(
        config.CredentialHelperError.InvalidCredentialHelper,
        config.load(allocator, test_io, testEnviron(), config_path),
    );
}

test "credentialHelperErrorText covers every credential_helper rejection" {
    // `main.zig` prints this for a malformed helper in the config file, so a
    // variant with no sentence here would surface as a bare Zig error name.
    const cases = [_]config.CredentialHelperError{
        config.CredentialHelperError.EmptyCredentialHelper,
        config.CredentialHelperError.TooManyCredentialHelperArgs,
        config.CredentialHelperError.InvalidCredentialHelperArg,
        config.CredentialHelperError.InvalidCredentialHelper,
    };

    for (cases, 0..) |err, idx| {
        const text = config.credentialHelperErrorText(err);
        try std.testing.expect(text.len > 0);
        // The message must not just restate the error name.
        try std.testing.expect(std.mem.indexOf(u8, text, "credential_helper") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, @errorName(err)) == null);
        for (cases[idx + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, text, config.credentialHelperErrorText(other)));
        }
    }
}

// ---------------------------------------------------------------------------
// config set credential_helper
//
// Bootstrapping a helper must not require the key to be written to disk first.
// The old route was `auth set` (plaintext on disk) -> `auth migrate` -> rotate,
// which defeats the backend's whole premise. What made `config set` unsafe was
// the missing verification, so the helper is run here before it is stored: a
// stored-but-broken helper *clears* the effective key instead of falling
// through, and would lock the operator out of their own credential.
// ---------------------------------------------------------------------------

const ConfigRunner = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    args: []const []const u8,
    config_path: ?[]const u8 = null,
    json_output: bool = false,
    /// `null` keeps the command inert: nothing spawns unless a test installs a
    /// fake, and no test here ever runs a real `op`.
    credential_runner: ?git.Runner = null,
};

fn runConfigCommand(r: *const ConfigRunner) !u8 {
    const args = try r.allocator.alloc([]const u8, r.args.len);
    defer r.allocator.free(args);
    for (r.args, 0..) |arg, idx| args[idx] = arg;

    return config_cmd.run(.{
        .allocator = r.allocator,
        .io = test_io,
        .config = r.cfg,
        .args = args,
        .json_output = r.json_output,
        .config_path = r.config_path,
        .retries = 0,
        .timeout_ms = 10_000,
        .credential_runner = r.credential_runner,
    });
}

/// A config file holding nothing but defaults — no key anywhere, which is the
/// state an operator who never wants the key on disk starts from.
const HelperConfigFixture = struct {
    tmp: std.testing.TmpDir,
    /// `realPathFileAlloc` returns a sentinel-terminated slice; keeping the
    /// sentinel in the type is what makes the matching `free` the right size.
    dir_path: [:0]u8,
    config_path: []u8,
    cfg: config.Config,
    saved_key_env: ?[]u8,
    saved_config_env: ?[]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *HelperConfigFixture) void {
        self.cfg.deinit();
        self.allocator.free(self.config_path);
        self.allocator.free(self.dir_path);
        self.tmp.cleanup();
        restoreEnv(env_name_z, self.saved_key_env, self.allocator);
        restoreEnv(config_env_name_z, self.saved_config_env, self.allocator);
    }

    fn readConfig(self: *HelperConfigFixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(test_io, "config.json", self.allocator, .limited(64 * 1024));
    }
};

fn makeHelperConfigFixture(allocator: std.mem.Allocator) !HelperConfigFixture {
    const saved_key_env = testEnviron().getAlloc(allocator, env_name) catch null;
    const saved_config_env = testEnviron().getAlloc(allocator, config_env_name) catch null;
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    errdefer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    errdefer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    errdefer cfg.deinit();
    try cfg.save(allocator, config_path);

    return .{
        .tmp = tmp,
        .dir_path = dir_path,
        .config_path = config_path,
        .cfg = cfg,
        .saved_key_env = saved_key_env,
        .saved_config_env = saved_config_env,
        .allocator = allocator,
    };
}

test "config set credential_helper stores a helper that returns a usable key" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    const runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", "op read op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "credential_helper saved") != null);

    // The helper was actually run, with the whitespace split as argv.
    try expectCall(&fake, 0, &.{ "op", "read", "op://Private/Linear/api-key" });

    // The key it produced decided whether to save and went nowhere else.
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_helper_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, fake_helper_key) == null);

    const argv = fixture.cfg.credential_helper.?;
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("op", argv[0]);
    try std.testing.expectEqualStrings("op://Private/Linear/api-key", argv[2]);

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") != null);
    // The point of the backend: the key itself never reaches the file.
    try std.testing.expect(std.mem.indexOf(u8, written, fake_helper_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"api_key\"") == null);

    var reloaded = try config.load(allocator, test_io, testEnviron(), fixture.config_path);
    defer reloaded.deinit();
    const persisted = reloaded.credential_helper.?;
    try std.testing.expectEqual(@as(usize, 3), persisted.len);
    try std.testing.expectEqualStrings("read", persisted[1]);
}

test "config set credential_helper splits with no shell semantics" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    const runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", "sh -c 'echo hi' > /tmp/x" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    // Identical to what the config file's bare-string form produces: quotes and
    // the redirection are ordinary bytes in argv elements, not syntax. No shell
    // is spawned, so nothing here redirects, expands, or pipes.
    try expectCall(&fake, 0, &.{ "sh", "-c", "'echo", "hi'", ">", "/tmp/x" });
    try std.testing.expectEqual(@as(usize, 6), fixture.cfg.credential_helper.?.len);
}

test "config set credential_helper refuses a helper that fails" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .exit_code = 1, .stderr = "vault is locked\n" }},
    };
    defer fake.deinit();

    const runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", "op read op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "exited 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "vault is locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "was not saved") != null);
    try std.testing.expectEqualStrings("", capture.stdout);

    // Nothing stored: a saved-but-broken helper clears the effective key rather
    // than falling through, so it would lock the operator out.
    try std.testing.expect(fixture.cfg.credential_helper == null);
    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") == null);
}

test "config set credential_helper refuses a helper that produces nothing usable" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        step: FakeProcess.Step,
        expected: []const u8,
    }{
        // Exit 0 with empty stdout is a failure, not an empty store.
        .{ .step = .{ .stdout = "" }, .expected = "produced no output" },
        // Output that could never be sent as an Authorization header.
        .{ .step = .{ .stdout = "not a key!\n" }, .expected = "not a valid API key" },
        // The binary is not there at all.
        .{ .step = .{ .fail = git.Error.BinaryNotFound }, .expected = "was not found on PATH" },
    };

    for (cases) |case| {
        var fixture = try makeHelperConfigFixture(allocator);
        defer fixture.deinit();

        var script = [_]FakeProcess.Step{case.step};
        var fake = FakeProcess{ .allocator = allocator, .script = script[0..] };
        defer fake.deinit();

        const runner = ConfigRunner{
            .allocator = allocator,
            .cfg = &fixture.cfg,
            .args = &.{ "set", "credential_helper", "op read op://Private/Linear/api-key" },
            .config_path = fixture.config_path,
            .credential_runner = fake.runner(),
        };
        const capture = try captureOutput(allocator, &runner, runConfigCommand);
        defer capture.deinit(allocator);

        try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, capture.stderr, case.expected) != null);
        try std.testing.expect(fixture.cfg.credential_helper == null);

        const written = try fixture.readConfig();
        defer allocator.free(written);
        try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") == null);
    }
}

test "config set credential_helper enforces the argv bounds before spawning" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    // One past `max_credential_helper_args`.
    const too_many = "a b c d e f g h i j k l m n o p q";
    const runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", too_many },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "too many arguments") != null);
    // An argv that could never be stored is never handed to a process.
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expect(fixture.cfg.credential_helper == null);
}

test "config set credential_helper refuses an over-long argument before spawning" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    const long_arg = try allocator.alloc(u8, config.max_credential_helper_arg_len + 1);
    defer allocator.free(long_arg);
    @memset(long_arg, 'x');
    const value = try std.fmt.allocPrint(allocator, "op {s}", .{long_arg});
    defer allocator.free(value);

    const runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", value },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "1024 bytes") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expect(fixture.cfg.credential_helper == null);
}

test "config set credential_helper refuses when process execution is unavailable" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    // No runner: the helper cannot be verified, so it must not be stored on the
    // strength of looking plausible.
    const runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", "op read op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
    };
    const capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "process execution is unavailable") != null);
    try std.testing.expect(fixture.cfg.credential_helper == null);
}

test "config unset credential_helper remains the escape hatch" {
    const allocator = std.testing.allocator;

    var fixture = try makeHelperConfigFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    var runner = ConfigRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "set", "credential_helper", "op read op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const set_capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer set_capture.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), set_capture.exit_code);

    runner.args = &.{ "unset", "credential_helper" };
    const unset_capture = try captureOutput(allocator, &runner, runConfigCommand);
    defer unset_capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), unset_capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, unset_capture.stdout, "credential_helper reset") != null);
    try std.testing.expect(fixture.cfg.credential_helper == null);
    // Unsetting spawns nothing: it is the way out of a broken helper.
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") == null);
}

test "config set usage documents credential_helper as settable" {
    const allocator = std.testing.allocator;

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try config_cmd.setUsage(&buffer.writer);

    const text = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "credential_helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Read-only here") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NO shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unset credential_helper") != null);
}

// ---------------------------------------------------------------------------
// Scrubbing the plaintext key off disk
// ---------------------------------------------------------------------------

test "config scrubFile overwrites the bytes it is pointed at" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "secret.json" });
    defer allocator.free(path);

    try tmp.dir.writeFile(test_io, .{ .sub_path = "secret.json", .data = "{\"api_key\":\"" ++ fake_file_key ++ "\"}" });
    try config.scrubFile(test_io, path);

    const after = try tmp.dir.readFileAlloc(test_io, "secret.json", allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, fake_file_key) == null);
    for (after) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "config scrubFile tolerates a missing file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "absent.json" });
    defer allocator.free(path);

    try config.scrubFile(test_io, path);
}

// ---------------------------------------------------------------------------
// auth status
// ---------------------------------------------------------------------------

test "auth status names the backend without ever printing the key" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, null);
    defer cfg.deinit();
    try cfg.setApiKeyFromProvider(fake_helper_key, .helper);
    try cfg.setCredentialHelper(&.{ "op", "read", "op://Private/Linear/api-key" });

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{"status"} };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "credential_helper") != null);
    // The label may not claim more than the offline charset/length check it is:
    // a bare "valid" reads as "round-tripped against the API", which never
    // happened here and never happens in this command.
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "present (format-valid, unverified)") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "present (valid)") == null);
    // And it points at the command that does verify.
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "linear auth test") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "op read op://Private/Linear/api-key") != null);
    // The whole point of `auth status` is that it answers the question `auth
    // show` gets used for, without the key reaching any stream.
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_helper_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, fake_helper_key) == null);
    // Not even a redacted fingerprint.
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "help...6789") == null);
}

test "auth status json reports the source and omits the key" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{"status"},
        .json_output = true,
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_file_key) == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, capture.stdout, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("file", obj.get("source").?.string);
    try std.testing.expectEqual(true, obj.get("key_present").?.bool);
    try std.testing.expectEqual(true, obj.get("key_format_valid").?.bool);
    // Renamed rather than redefined, so a consumer still reading `key_valid`
    // breaks instead of quietly believing the key was checked against the API.
    try std.testing.expect(obj.get("key_valid") == null);
    // `auth status` never verifies, so this is null — not `false`, which would
    // read as "checked and rejected".
    try std.testing.expect(obj.get("key_verified").? == .null);
    try std.testing.expectEqual(true, obj.get("file_key_present").?.bool);
    try std.testing.expect(obj.get("credential_helper").? == .null);
    try std.testing.expect(obj.get("api_key") == null);
}

test "auth status exits non-zero when no backend supplied a key" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, null);
    defer cfg.deinit();

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{"status"} };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "absent") != null);
}

test "auth status reports a failed helper as its own state" {
    const allocator = std.testing.allocator;

    var cfg = try makeChainConfig(allocator, fake_file_key);
    defer cfg.deinit();
    try cfg.setCredentialHelper(&.{"op"});
    cfg.clearEffectiveApiKey(.helper_failed);

    const runner = AuthRunner{ .allocator = allocator, .cfg = &cfg, .args = &.{"status"} };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "credential_helper (failed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_file_key) == null);
}

// ---------------------------------------------------------------------------
// auth migrate
// ---------------------------------------------------------------------------

const MigrateFixture = struct {
    tmp: std.testing.TmpDir,
    /// `realPathFileAlloc` returns a sentinel-terminated slice; keeping the
    /// sentinel in the type is what makes the matching `free` the right size.
    dir_path: [:0]u8,
    config_path: []u8,
    cfg: config.Config,
    saved_key_env: ?[]u8,
    saved_config_env: ?[]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *MigrateFixture) void {
        self.cfg.deinit();
        self.allocator.free(self.config_path);
        self.allocator.free(self.dir_path);
        self.tmp.cleanup();
        restoreEnv(env_name_z, self.saved_key_env, self.allocator);
        restoreEnv(config_env_name_z, self.saved_config_env, self.allocator);
    }

    fn readConfig(self: *MigrateFixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(test_io, "config.json", self.allocator, .limited(64 * 1024));
    }
};

/// A config file on disk holding a plaintext `api_key`, which is the state
/// `auth migrate` exists to get out of.
fn makeMigrateFixture(allocator: std.mem.Allocator) !MigrateFixture {
    const saved_key_env = testEnviron().getAlloc(allocator, env_name) catch null;
    const saved_config_env = testEnviron().getAlloc(allocator, config_env_name) catch null;
    clearEnv();

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    errdefer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.json" });
    errdefer allocator.free(config_path);

    var cfg = try config.load(allocator, test_io, testEnviron(), config_path);
    errdefer cfg.deinit();
    try cfg.setApiKey(fake_file_key);
    try cfg.setDefaultTeamId("ENG");
    try cfg.save(allocator, config_path);

    return .{
        .tmp = tmp,
        .dir_path = dir_path,
        .config_path = config_path,
        .cfg = cfg,
        .saved_key_env = saved_key_env,
        .saved_config_env = saved_config_env,
        .allocator = allocator,
    };
}

test "auth migrate to a helper verifies the read-back before dropping the plaintext key" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_file_key ++ "\n" }},
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "helper", "op", "read", "op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "migrated to credential_helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_file_key) == null);
    try expectCall(&fake, 0, &.{ "op", "read", "op://Private/Linear/api-key" });

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"api_key\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") != null);
    // Unrelated settings survive the rewrite.
    try std.testing.expect(std.mem.indexOf(u8, written, "ENG") != null);
}

test "auth migrate keeps the plaintext key when the helper hands back a different one" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_helper_key ++ "\n" }},
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "helper", "op", "read", "op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "different key") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, fake_file_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, fake_helper_key) == null);

    // Nothing was written: the key on disk is still the only copy there is.
    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "credential_helper") == null);
    try std.testing.expect(fixture.cfg.credential_helper == null);
}

test "auth migrate keeps the plaintext key when the helper fails outright" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .fail = git.Error.BinaryNotFound }},
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "helper", "op", "read", "op://Private/Linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "was not found on PATH") != null);

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) != null);
}

test "auth migrate to the keychain writes, reads back, then removes the plaintext key" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{}, // security -i
            .{ .stdout = fake_file_key ++ "\n" }, // find-generic-password -w
        },
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "keychain" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    if (!credentials.keychain_supported) {
        try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "only available on macOS") != null);
        try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
        return;
    }

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, "migrated to keychain") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout, fake_file_key) == null);

    try expectCall(&fake, 0, &.{ "/usr/bin/security", "-i" });
    try expectCall(&fake, 1, &.{
        "/usr/bin/security",
        "find-generic-password",
        "-w",
        "-s",
        "linear-cli",
        "-a",
        "api-key",
    });
    // The secret reached `security` on stdin and appears in no argv.
    try std.testing.expect(std.mem.indexOf(u8, fake.inputs.items[0], fake_file_key) != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.calls.items[0], fake_file_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, fake.calls.items[1], fake_file_key) == null);

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"api_key\"") == null);
}

test "auth migrate to the keychain aborts when the read-back disagrees" {
    const allocator = std.testing.allocator;
    if (!credentials.keychain_supported) return error.SkipZigTest;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{}, // the write claims success
            .{ .stdout = fake_keychain_key ++ "\n" }, // but a different item comes back
        },
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "keychain" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "read back a different key") != null);

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) != null);
}

test "auth migrate to the keychain aborts when the item cannot be read back" {
    const allocator = std.testing.allocator;
    if (!credentials.keychain_supported) return error.SkipZigTest;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{
            .{},
            .{ .exit_code = 44 },
        },
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "keychain" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "could not be read back") != null);

    const written = try fixture.readConfig();
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, fake_file_key) != null);
}

test "auth migrate refuses to pick a backend on its own" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{"migrate"},
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "missing --to") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "auth migrate needs a command for the helper backend" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "helper" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "needs the command") != null);
}

test "auth migrate has nothing to do when the file holds no key" {
    const allocator = std.testing.allocator;
    const previous = testEnviron().getAlloc(allocator, env_name) catch null;
    const previous_config = testEnviron().getAlloc(allocator, config_env_name) catch null;
    defer {
        restoreEnv(env_name_z, previous, allocator);
        restoreEnv(config_env_name_z, previous_config, allocator);
    }
    clearEnv();
    try setEnvValue(fake_env_key, allocator);

    var cfg = try makeChainConfig(allocator, null);
    defer cfg.deinit();
    try cfg.applyEnvOverrides();
    try std.testing.expectEqual(config.KeySource.environment, cfg.key_source);

    var fake = FakeProcess{ .allocator = allocator, .script = &.{} };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &cfg,
        .args = &.{ "migrate", "--to", "keychain" },
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    // An environment key is not ours to move, and it never reached the file.
    try std.testing.expectEqual(@as(u8, 1), capture.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr, "no API key in the config file") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "auth migrate splits a single quoted helper command on whitespace" {
    const allocator = std.testing.allocator;

    var fixture = try makeMigrateFixture(allocator);
    defer fixture.deinit();

    var fake = FakeProcess{
        .allocator = allocator,
        .script = &.{.{ .stdout = fake_file_key ++ "\n" }},
    };
    defer fake.deinit();

    const runner = AuthRunner{
        .allocator = allocator,
        .cfg = &fixture.cfg,
        .args = &.{ "migrate", "--to", "helper", "pass show linear/api-key" },
        .config_path = fixture.config_path,
        .credential_runner = fake.runner(),
    };
    const capture = try captureOutput(allocator, &runner, runAuth);
    defer capture.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), capture.exit_code);
    try expectCall(&fake, 0, &.{ "pass", "show", "linear/api-key" });
}

test "auth migrate flag parsing rejects unknown backends and flags" {
    const empty: [][]const u8 = &.{};
    const parsed_empty = try auth_cmd.parseMigrateOptions(empty);
    try std.testing.expect(parsed_empty.target == null);

    var bad_backend = [_][]const u8{ "--to", "vault" };
    try std.testing.expectError(error.UnknownBackend, auth_cmd.parseMigrateOptions(bad_backend[0..]));

    var missing = [_][]const u8{"--to"};
    try std.testing.expectError(error.MissingValue, auth_cmd.parseMigrateOptions(missing[0..]));

    var unknown = [_][]const u8{"--force"};
    try std.testing.expectError(error.UnknownFlag, auth_cmd.parseMigrateOptions(unknown[0..]));

    // Everything after `--to helper` is argv, including things that look like
    // flags: a helper may legitimately need `--field password`.
    var helper = [_][]const u8{ "--to", "helper", "op", "item", "get", "--fields", "password" };
    const parsed = try auth_cmd.parseMigrateOptions(helper[0..]);
    try std.testing.expectEqual(auth_cmd.MigrateTarget.helper, parsed.target.?);
    try std.testing.expectEqual(@as(usize, 5), parsed.helper_argv.len);
    try std.testing.expectEqualStrings("--fields", parsed.helper_argv[3]);
}
