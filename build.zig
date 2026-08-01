const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    const git_hash = detectGitHash(b.allocator, b.graph.io);
    const git_version = detectGitVersion(b.allocator, b.graph.io);
    build_options.addOption([]const u8, "git_hash", git_hash);
    build_options.addOption([]const u8, "version", git_version);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "linear",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("cli", cli_mod);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", build_options);

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graphql_mod = b.createModule(.{
        .root_source_file = b.path("src/graphql_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graphql_mock_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/mock_graphql.zig"),
        .target = target,
        .optimize = optimize,
    });
    const printer_mod = b.createModule(.{
        .root_source_file = b.path("src/print.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The single subprocess layer. `git` and `credentials` both build on it;
    // nothing else in the tree spawns a process.
    const process_mod = b.createModule(.{
        .root_source_file = b.path("src/process.zig"),
        .target = target,
        .optimize = optimize,
    });
    // `git` only depends on std and `process`, so a single instance serves the
    // real and the mocked command modules alike; there is no `git_test_mod`.
    const git_mod = b.createModule(.{
        .root_source_file = b.path("src/git.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_mod.addImport("process", process_mod);
    // Likewise `credentials`: it only reaches `config` and `process`, neither
    // of which has a mocked variant, so one module serves every consumer.
    const credentials_mod = b.createModule(.{
        .root_source_file = b.path("src/credentials.zig"),
        .target = target,
        .optimize = optimize,
    });
    credentials_mod.addImport("config", config_mod);
    credentials_mod.addImport("process", process_mod);
    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_mod.addImport("config", config_mod);
    common_mod.addImport("graphql", graphql_mod);
    const bulk_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/bulk.zig"),
        .target = target,
        .optimize = optimize,
    });
    bulk_mod.addImport("common", common_mod);
    const download_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/download.zig"),
        .target = target,
        .optimize = optimize,
    });
    download_mod.addImport("config", config_mod);
    download_mod.addImport("common", common_mod);
    const common_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_test_mod.addImport("config", config_mod);
    common_test_mod.addImport("graphql", graphql_mock_mod);
    const bulk_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/bulk.zig"),
        .target = target,
        .optimize = optimize,
    });
    bulk_test_mod.addImport("common", common_test_mod);
    const download_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/download.zig"),
        .target = target,
        .optimize = optimize,
    });
    download_test_mod.addImport("config", config_mod);
    download_test_mod.addImport("common", common_test_mod);
    const app_main_stub = b.createModule(.{
        .root_source_file = b.path("src/tests/app_main_stub.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("graphql", graphql_mod);
    exe.root_module.addImport("printer", printer_mod);
    exe.root_module.addImport("common", common_mod);
    exe.root_module.addImport("bulk", bulk_mod);
    exe.root_module.addImport("download", download_mod);
    exe.root_module.addImport("git", git_mod);
    exe.root_module.addImport("process", process_mod);
    exe.root_module.addImport("credentials", credentials_mod);

    const tests_mod = tests.root_module;
    tests_mod.addImport("config", config_mod);
    tests_mod.addImport("graphql", graphql_mod);
    tests_mod.addImport("graphql_mock", graphql_mock_mod);
    tests_mod.addImport("printer", printer_mod);
    tests_mod.addImport("common", common_test_mod);
    tests_mod.addImport("bulk", bulk_test_mod);
    tests_mod.addImport("cli", cli_mod);
    tests_mod.addImport("app_main", app_main_stub);
    tests_mod.addImport("download_test", download_test_mod);
    tests_mod.addImport("git", git_mod);
    tests_mod.addImport("process", process_mod);
    tests_mod.addImport("credentials", credentials_mod);

    const gql_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/gql.zig"),
        .target = target,
        .optimize = optimize,
    });
    gql_mod.addImport("config", config_mod);
    gql_mod.addImport("graphql", graphql_mod);
    gql_mod.addImport("printer", printer_mod);
    gql_mod.addImport("common", common_mod);
    const gql_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/gql.zig"),
        .target = target,
        .optimize = optimize,
    });
    gql_test_mod.addImport("config", config_mod);
    gql_test_mod.addImport("graphql", graphql_mock_mod);
    gql_test_mod.addImport("printer", printer_mod);
    gql_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("gql", gql_test_mod);

    const issues_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issues.zig"),
        .target = target,
        .optimize = optimize,
    });
    issues_mod.addImport("config", config_mod);
    issues_mod.addImport("graphql", graphql_mod);
    issues_mod.addImport("printer", printer_mod);
    issues_mod.addImport("common", common_mod);
    const issues_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issues.zig"),
        .target = target,
        .optimize = optimize,
    });
    issues_test_mod.addImport("config", config_mod);
    issues_test_mod.addImport("graphql", graphql_mock_mod);
    issues_test_mod.addImport("printer", printer_mod);
    issues_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("issues_test", issues_test_mod);

    const search_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    search_mod.addImport("config", config_mod);
    search_mod.addImport("graphql", graphql_mod);
    search_mod.addImport("printer", printer_mod);
    search_mod.addImport("common", common_mod);
    const search_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    search_test_mod.addImport("config", config_mod);
    search_test_mod.addImport("graphql", graphql_mock_mod);
    search_test_mod.addImport("printer", printer_mod);
    search_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("search_test", search_test_mod);

    const issue_create_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_create.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_create_mod.addImport("config", config_mod);
    issue_create_mod.addImport("graphql", graphql_mod);
    issue_create_mod.addImport("printer", printer_mod);
    issue_create_mod.addImport("common", common_mod);
    const issue_create_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_create.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_create_test_mod.addImport("config", config_mod);
    issue_create_test_mod.addImport("graphql", graphql_mock_mod);
    issue_create_test_mod.addImport("printer", printer_mod);
    issue_create_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("issue_create_test", issue_create_test_mod);

    const issue_delete_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_delete.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_delete_mod.addImport("config", config_mod);
    issue_delete_mod.addImport("graphql", graphql_mod);
    issue_delete_mod.addImport("printer", printer_mod);
    issue_delete_mod.addImport("common", common_mod);
    issue_delete_mod.addImport("bulk", bulk_mod);
    const issue_delete_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_delete.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_delete_test_mod.addImport("config", config_mod);
    issue_delete_test_mod.addImport("graphql", graphql_mock_mod);
    issue_delete_test_mod.addImport("printer", printer_mod);
    issue_delete_test_mod.addImport("common", common_test_mod);
    issue_delete_test_mod.addImport("bulk", bulk_test_mod);
    tests_mod.addImport("issue_delete_test", issue_delete_test_mod);

    const issue_update_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_update.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_update_mod.addImport("config", config_mod);
    issue_update_mod.addImport("graphql", graphql_mod);
    issue_update_mod.addImport("printer", printer_mod);
    issue_update_mod.addImport("common", common_mod);
    issue_update_mod.addImport("git", git_mod);
    const issue_update_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_update.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_update_test_mod.addImport("config", config_mod);
    issue_update_test_mod.addImport("graphql", graphql_mock_mod);
    issue_update_test_mod.addImport("printer", printer_mod);
    issue_update_test_mod.addImport("common", common_test_mod);
    issue_update_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_update_test", issue_update_test_mod);

    const issue_link_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_link.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_link_mod.addImport("config", config_mod);
    issue_link_mod.addImport("graphql", graphql_mod);
    issue_link_mod.addImport("printer", printer_mod);
    issue_link_mod.addImport("common", common_mod);
    issue_link_mod.addImport("git", git_mod);
    const issue_link_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_link.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_link_test_mod.addImport("config", config_mod);
    issue_link_test_mod.addImport("graphql", graphql_mock_mod);
    issue_link_test_mod.addImport("printer", printer_mod);
    issue_link_test_mod.addImport("common", common_test_mod);
    issue_link_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_link_test", issue_link_test_mod);

    const issue_comment_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_comment.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_comment_mod.addImport("config", config_mod);
    issue_comment_mod.addImport("graphql", graphql_mod);
    issue_comment_mod.addImport("printer", printer_mod);
    issue_comment_mod.addImport("common", common_mod);
    issue_comment_mod.addImport("git", git_mod);
    const issue_comment_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_comment.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_comment_test_mod.addImport("config", config_mod);
    issue_comment_test_mod.addImport("graphql", graphql_mock_mod);
    issue_comment_test_mod.addImport("printer", printer_mod);
    issue_comment_test_mod.addImport("common", common_test_mod);
    issue_comment_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_comment_test", issue_comment_test_mod);

    const issue_comments_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_comments.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_comments_mod.addImport("config", config_mod);
    issue_comments_mod.addImport("graphql", graphql_mod);
    issue_comments_mod.addImport("printer", printer_mod);
    issue_comments_mod.addImport("common", common_mod);
    issue_comments_mod.addImport("git", git_mod);
    const issue_comments_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_comments.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_comments_test_mod.addImport("config", config_mod);
    issue_comments_test_mod.addImport("graphql", graphql_mock_mod);
    issue_comments_test_mod.addImport("printer", printer_mod);
    issue_comments_test_mod.addImport("common", common_test_mod);
    issue_comments_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_comments_test", issue_comments_test_mod);

    const issue_start_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_start.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_start_mod.addImport("config", config_mod);
    issue_start_mod.addImport("graphql", graphql_mod);
    issue_start_mod.addImport("printer", printer_mod);
    issue_start_mod.addImport("common", common_mod);
    issue_start_mod.addImport("git", git_mod);
    const issue_start_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_start.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_start_test_mod.addImport("config", config_mod);
    issue_start_test_mod.addImport("graphql", graphql_mock_mod);
    issue_start_test_mod.addImport("printer", printer_mod);
    issue_start_test_mod.addImport("common", common_test_mod);
    issue_start_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_start_test", issue_start_test_mod);

    const issue_pr_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_pr.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_pr_mod.addImport("config", config_mod);
    issue_pr_mod.addImport("graphql", graphql_mod);
    issue_pr_mod.addImport("common", common_mod);
    issue_pr_mod.addImport("git", git_mod);
    const issue_pr_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_pr.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_pr_test_mod.addImport("config", config_mod);
    issue_pr_test_mod.addImport("graphql", graphql_mock_mod);
    issue_pr_test_mod.addImport("common", common_test_mod);
    issue_pr_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_pr_test", issue_pr_test_mod);

    const issue_info_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_info.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_info_mod.addImport("config", config_mod);
    issue_info_mod.addImport("graphql", graphql_mod);
    issue_info_mod.addImport("common", common_mod);
    issue_info_mod.addImport("git", git_mod);
    const issue_info_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_info.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_info_test_mod.addImport("config", config_mod);
    issue_info_test_mod.addImport("graphql", graphql_mock_mod);
    issue_info_test_mod.addImport("common", common_test_mod);
    issue_info_test_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_info_test", issue_info_test_mod);

    const issue_view_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_view.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_view_mod.addImport("config", config_mod);
    issue_view_mod.addImport("graphql", graphql_mock_mod);
    issue_view_mod.addImport("printer", printer_mod);
    issue_view_mod.addImport("common", common_test_mod);
    issue_view_mod.addImport("download", download_test_mod);
    issue_view_mod.addImport("git", git_mod);
    tests_mod.addImport("issue_view_test", issue_view_mod);

    const issue_view_online_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/issue_view.zig"),
        .target = target,
        .optimize = optimize,
    });
    issue_view_online_mod.addImport("config", config_mod);
    issue_view_online_mod.addImport("graphql", graphql_mod);
    issue_view_online_mod.addImport("printer", printer_mod);
    issue_view_online_mod.addImport("common", common_mod);
    issue_view_online_mod.addImport("download", download_mod);
    issue_view_online_mod.addImport("git", git_mod);

    const me_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/me.zig"),
        .target = target,
        .optimize = optimize,
    });
    me_mod.addImport("config", config_mod);
    me_mod.addImport("graphql", graphql_mock_mod);
    me_mod.addImport("printer", printer_mod);
    me_mod.addImport("common", common_test_mod);
    tests_mod.addImport("me_test", me_mod);

    const me_online_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/me.zig"),
        .target = target,
        .optimize = optimize,
    });
    me_online_mod.addImport("config", config_mod);
    me_online_mod.addImport("graphql", graphql_mod);
    me_online_mod.addImport("printer", printer_mod);
    me_online_mod.addImport("common", common_mod);

    const teams_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/teams.zig"),
        .target = target,
        .optimize = optimize,
    });
    teams_mod.addImport("config", config_mod);
    teams_mod.addImport("graphql", graphql_mock_mod);
    teams_mod.addImport("printer", printer_mod);
    teams_mod.addImport("common", common_test_mod);
    tests_mod.addImport("teams_test", teams_mod);

    const teams_online_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/teams.zig"),
        .target = target,
        .optimize = optimize,
    });
    teams_online_mod.addImport("config", config_mod);
    teams_online_mod.addImport("graphql", graphql_mod);
    teams_online_mod.addImport("printer", printer_mod);
    teams_online_mod.addImport("common", common_mod);

    const projects_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/projects.zig"),
        .target = target,
        .optimize = optimize,
    });
    projects_mod.addImport("config", config_mod);
    projects_mod.addImport("graphql", graphql_mock_mod);
    projects_mod.addImport("printer", printer_mod);
    projects_mod.addImport("common", common_test_mod);
    tests_mod.addImport("projects_test", projects_mod);

    const projects_online_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/projects.zig"),
        .target = target,
        .optimize = optimize,
    });
    projects_online_mod.addImport("config", config_mod);
    projects_online_mod.addImport("graphql", graphql_mod);
    projects_online_mod.addImport("printer", printer_mod);
    projects_online_mod.addImport("common", common_mod);

    const labels_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/labels.zig"),
        .target = target,
        .optimize = optimize,
    });
    labels_mod.addImport("config", config_mod);
    labels_mod.addImport("graphql", graphql_mod);
    labels_mod.addImport("printer", printer_mod);
    labels_mod.addImport("common", common_mod);
    const labels_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/labels.zig"),
        .target = target,
        .optimize = optimize,
    });
    labels_test_mod.addImport("config", config_mod);
    labels_test_mod.addImport("graphql", graphql_mock_mod);
    labels_test_mod.addImport("printer", printer_mod);
    labels_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("labels_test", labels_test_mod);

    const users_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/users.zig"),
        .target = target,
        .optimize = optimize,
    });
    users_mod.addImport("config", config_mod);
    users_mod.addImport("graphql", graphql_mod);
    users_mod.addImport("printer", printer_mod);
    users_mod.addImport("common", common_mod);
    const users_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/users.zig"),
        .target = target,
        .optimize = optimize,
    });
    users_test_mod.addImport("config", config_mod);
    users_test_mod.addImport("graphql", graphql_mock_mod);
    users_test_mod.addImport("printer", printer_mod);
    users_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("users_test", users_test_mod);

    const states_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/states.zig"),
        .target = target,
        .optimize = optimize,
    });
    states_mod.addImport("config", config_mod);
    states_mod.addImport("graphql", graphql_mod);
    states_mod.addImport("printer", printer_mod);
    states_mod.addImport("common", common_mod);
    const states_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/states.zig"),
        .target = target,
        .optimize = optimize,
    });
    states_test_mod.addImport("config", config_mod);
    states_test_mod.addImport("graphql", graphql_mock_mod);
    states_test_mod.addImport("printer", printer_mod);
    states_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("states_test", states_test_mod);

    const milestones_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/milestones.zig"),
        .target = target,
        .optimize = optimize,
    });
    milestones_mod.addImport("config", config_mod);
    milestones_mod.addImport("graphql", graphql_mod);
    milestones_mod.addImport("printer", printer_mod);
    milestones_mod.addImport("common", common_mod);
    milestones_mod.addImport("bulk", bulk_mod);
    const milestones_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/milestones.zig"),
        .target = target,
        .optimize = optimize,
    });
    milestones_test_mod.addImport("config", config_mod);
    milestones_test_mod.addImport("graphql", graphql_mock_mod);
    milestones_test_mod.addImport("printer", printer_mod);
    milestones_test_mod.addImport("common", common_test_mod);
    milestones_test_mod.addImport("bulk", bulk_test_mod);
    tests_mod.addImport("milestones_test", milestones_test_mod);

    const project_view_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_view.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_view_mod.addImport("config", config_mod);
    project_view_mod.addImport("graphql", graphql_mock_mod);
    project_view_mod.addImport("printer", printer_mod);
    project_view_mod.addImport("common", common_test_mod);
    tests_mod.addImport("project_view_test", project_view_mod);

    const project_view_online_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_view.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_view_online_mod.addImport("config", config_mod);
    project_view_online_mod.addImport("graphql", graphql_mod);
    project_view_online_mod.addImport("printer", printer_mod);
    project_view_online_mod.addImport("common", common_mod);

    const project_create_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_create.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_create_mod.addImport("config", config_mod);
    project_create_mod.addImport("graphql", graphql_mod);
    project_create_mod.addImport("printer", printer_mod);
    project_create_mod.addImport("common", common_mod);
    const project_create_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_create.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_create_test_mod.addImport("config", config_mod);
    project_create_test_mod.addImport("graphql", graphql_mock_mod);
    project_create_test_mod.addImport("printer", printer_mod);
    project_create_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("project_create_test", project_create_test_mod);

    const project_update_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_update.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_update_mod.addImport("config", config_mod);
    project_update_mod.addImport("graphql", graphql_mod);
    project_update_mod.addImport("printer", printer_mod);
    project_update_mod.addImport("common", common_mod);
    const project_update_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_update.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_update_test_mod.addImport("config", config_mod);
    project_update_test_mod.addImport("graphql", graphql_mock_mod);
    project_update_test_mod.addImport("printer", printer_mod);
    project_update_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("project_update_test", project_update_test_mod);

    const project_delete_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_delete.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_delete_mod.addImport("config", config_mod);
    project_delete_mod.addImport("graphql", graphql_mod);
    project_delete_mod.addImport("printer", printer_mod);
    project_delete_mod.addImport("common", common_mod);
    const project_delete_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_delete.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_delete_test_mod.addImport("config", config_mod);
    project_delete_test_mod.addImport("graphql", graphql_mock_mod);
    project_delete_test_mod.addImport("printer", printer_mod);
    project_delete_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("project_delete_test", project_delete_test_mod);

    const project_issues_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_issues.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_issues_mod.addImport("config", config_mod);
    project_issues_mod.addImport("graphql", graphql_mod);
    project_issues_mod.addImport("printer", printer_mod);
    project_issues_mod.addImport("common", common_mod);
    const project_issues_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/project_issues.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_issues_test_mod.addImport("config", config_mod);
    project_issues_test_mod.addImport("graphql", graphql_mock_mod);
    project_issues_test_mod.addImport("printer", printer_mod);
    project_issues_test_mod.addImport("common", common_test_mod);
    tests_mod.addImport("project_issues_test", project_issues_test_mod);

    const config_cmd_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_cmd_mod.addImport("config", config_mod);
    config_cmd_mod.addImport("graphql", graphql_mod);
    config_cmd_mod.addImport("printer", printer_mod);
    config_cmd_mod.addImport("common", common_mod);
    // `config set credential_helper` runs the helper before storing it, through
    // the same audited subprocess layer every other backend uses.
    config_cmd_mod.addImport("credentials", credentials_mod);
    config_cmd_mod.addImport("process", process_mod);
    const config_cmd_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_cmd_test_mod.addImport("config", config_mod);
    config_cmd_test_mod.addImport("graphql", graphql_mock_mod);
    config_cmd_test_mod.addImport("printer", printer_mod);
    config_cmd_test_mod.addImport("common", common_test_mod);
    config_cmd_test_mod.addImport("credentials", credentials_mod);
    config_cmd_test_mod.addImport("process", process_mod);
    tests_mod.addImport("config_cmd", config_cmd_test_mod);

    const auth_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_mod.addImport("config", config_mod);
    auth_mod.addImport("graphql", graphql_mod);
    auth_mod.addImport("printer", printer_mod);
    auth_mod.addImport("common", common_mod);
    auth_mod.addImport("credentials", credentials_mod);
    auth_mod.addImport("process", process_mod);

    const auth_test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_test_mod.addImport("config", config_mod);
    auth_test_mod.addImport("graphql", graphql_mock_mod);
    auth_test_mod.addImport("printer", printer_mod);
    auth_test_mod.addImport("common", common_test_mod);
    auth_test_mod.addImport("credentials", credentials_mod);
    auth_test_mod.addImport("process", process_mod);
    tests_mod.addImport("auth_test", auth_test_mod);

    const test_step = b.step("test", "Run unit tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const online_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/online.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    online_tests.root_module.addOptions("build_options", build_options);
    online_tests.root_module.addImport("config", config_mod);
    online_tests.root_module.addImport("graphql", graphql_mod);
    online_tests.root_module.addImport("printer", printer_mod);
    online_tests.root_module.addImport("common", common_mod);
    online_tests.root_module.addImport("cli", cli_mod);
    online_tests.root_module.addImport("auth", auth_mod);
    online_tests.root_module.addImport("teams_cmd", teams_online_mod);
    online_tests.root_module.addImport("issues_cmd", issues_mod);
    online_tests.root_module.addImport("search_cmd", search_mod);
    online_tests.root_module.addImport("issue_view_cmd", issue_view_online_mod);
    online_tests.root_module.addImport("issue_create_cmd", issue_create_mod);
    online_tests.root_module.addImport("issue_delete_cmd", issue_delete_mod);
    online_tests.root_module.addImport("issue_comment_cmd", issue_comment_mod);
    online_tests.root_module.addImport("issue_comments_cmd", issue_comments_mod);
    online_tests.root_module.addImport("me_cmd", me_online_mod);
    online_tests.root_module.addImport("gql_cmd", gql_mod);
    online_tests.root_module.addImport("projects_cmd", projects_online_mod);
    online_tests.root_module.addImport("labels_cmd", labels_mod);
    online_tests.root_module.addImport("users_cmd", users_mod);
    online_tests.root_module.addImport("states_cmd", states_mod);
    online_tests.root_module.addImport("project_view_cmd", project_view_online_mod);
    online_tests.root_module.addImport("project_create_cmd", project_create_mod);
    online_tests.root_module.addImport("project_update_cmd", project_update_mod);
    online_tests.root_module.addImport("project_delete_cmd", project_delete_mod);
    online_tests.root_module.addImport("project_issues_cmd", project_issues_mod);
    online_tests.root_module.addImport("milestones_cmd", milestones_mod);

    const online_step = b.step("online", "Run online tests (requires LINEAR_ONLINE_TESTS=1 and LINEAR_API_KEY)");
    const run_online = b.addRunArtifact(online_tests);
    online_step.dependOn(&run_online.step);

    // Setup step: install git hooks via lefthook
    const setup_step = b.step("setup", "Install git hooks (requires lefthook)");
    const lefthook_install = b.addSystemCommand(&.{ "lefthook", "install" });
    setup_step.dependOn(&lefthook_install.step);

    // Lint step: run ziglint
    const lint_step = b.step("lint", "Run ziglint static analysis");
    const ziglint = b.addSystemCommand(&.{"ziglint"});
    lint_step.dependOn(&ziglint.step);

    // npm distribution: cross-compile for all platforms
    // Note: Windows build requires platform-specific fixes for tcsetattr and file permissions
    const npm_targets = [_]struct { name: []const u8, cpu: std.Target.Cpu.Arch, os: std.Target.Os.Tag }{
        .{ .name = "darwin-arm64", .cpu = .aarch64, .os = .macos },
        .{ .name = "darwin-x64", .cpu = .x86_64, .os = .macos },
        .{ .name = "linux-x64", .cpu = .x86_64, .os = .linux },
        .{ .name = "linux-arm64", .cpu = .aarch64, .os = .linux },
        // .{ .name = "win32-x64", .cpu = .x86_64, .os = .windows }, // TODO: fix tcsetattr and file permissions
    };

    const npm_step = b.step("npm", "Build for all npm platforms");

    for (npm_targets) |t| {
        const npm_target = b.resolveTargetQuery(.{ .cpu_arch = t.cpu, .os_tag = t.os });
        const npm_optimize = std.builtin.OptimizeMode.ReleaseSafe;

        const npm_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });

        const npm_config_mod = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        const npm_graphql_mod = b.createModule(.{
            .root_source_file = b.path("src/graphql_client.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        const npm_printer_mod = b.createModule(.{
            .root_source_file = b.path("src/print.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        const npm_process_mod = b.createModule(.{
            .root_source_file = b.path("src/process.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        const npm_git_mod = b.createModule(.{
            .root_source_file = b.path("src/git.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        npm_git_mod.addImport("process", npm_process_mod);
        const npm_credentials_mod = b.createModule(.{
            .root_source_file = b.path("src/credentials.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        npm_credentials_mod.addImport("config", npm_config_mod);
        npm_credentials_mod.addImport("process", npm_process_mod);
        const npm_common_mod = b.createModule(.{
            .root_source_file = b.path("src/commands/common.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        npm_common_mod.addImport("config", npm_config_mod);
        npm_common_mod.addImport("graphql", npm_graphql_mod);
        const npm_bulk_mod = b.createModule(.{
            .root_source_file = b.path("src/commands/bulk.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        npm_bulk_mod.addImport("common", npm_common_mod);
        const npm_download_mod = b.createModule(.{
            .root_source_file = b.path("src/commands/download.zig"),
            .target = npm_target,
            .optimize = npm_optimize,
        });
        npm_download_mod.addImport("config", npm_config_mod);
        npm_download_mod.addImport("common", npm_common_mod);

        const npm_exe = b.addExecutable(.{
            .name = "linear",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = npm_target,
                .optimize = npm_optimize,
            }),
        });
        npm_exe.root_module.addOptions("build_options", build_options);
        npm_exe.root_module.addImport("cli", npm_cli_mod);
        npm_exe.root_module.addImport("config", npm_config_mod);
        npm_exe.root_module.addImport("graphql", npm_graphql_mod);
        npm_exe.root_module.addImport("printer", npm_printer_mod);
        npm_exe.root_module.addImport("common", npm_common_mod);
        npm_exe.root_module.addImport("bulk", npm_bulk_mod);
        npm_exe.root_module.addImport("download", npm_download_mod);
        npm_exe.root_module.addImport("git", npm_git_mod);
        npm_exe.root_module.addImport("process", npm_process_mod);
        npm_exe.root_module.addImport("credentials", npm_credentials_mod);

        const dest_dir = b.fmt("npm/linear-cli-{s}", .{t.name});
        const install = b.addInstallArtifact(npm_exe, .{
            .dest_dir = .{ .override = .{ .custom = dest_dir } },
        });
        npm_step.dependOn(&install.step);
    }
}

fn detectGitHash(allocator: std.mem.Allocator, io: std.Io) []const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
    }) catch return "unknown";
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return "unknown";

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return "unknown";

    return allocator.dupe(u8, trimmed) catch "unknown";
}

fn detectGitVersion(allocator: std.mem.Allocator, io: std.Io) []const u8 {
    // Try to get version from git tags: "v0.1.1" or "v0.1.1-3-g1234567" if ahead of tag
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "describe", "--tags", "--always" },
    }) catch return "0.0.0-dev";
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return "0.0.0-dev";

    var trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return "0.0.0-dev";

    // Strip leading 'v' if present (v0.1.1 -> 0.1.1)
    if (trimmed.len > 0 and trimmed[0] == 'v') {
        trimmed = trimmed[1..];
    }

    return allocator.dupe(u8, trimmed) catch "0.0.0-dev";
}
