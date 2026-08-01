const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config = @import("config");
const cli = @import("cli");
const graphql = @import("graphql");
const git = @import("git");
const process = @import("process");
const credentials = @import("credentials");
const gql_command = @import("commands/gql.zig");
const auth_command = @import("commands/auth.zig");
const config_command = @import("commands/config.zig");
const me_command = @import("commands/me.zig");
const teams_command = @import("commands/teams.zig");
const issues_command = @import("commands/issues.zig");
const issue_view_command = @import("commands/issue_view.zig");
const issue_create_command = @import("commands/issue_create.zig");
const issue_delete_command = @import("commands/issue_delete.zig");
const issue_update_command = @import("commands/issue_update.zig");
const issue_link_command = @import("commands/issue_link.zig");
const issue_comment_command = @import("commands/issue_comment.zig");
const issue_comments_command = @import("commands/issue_comments.zig");
const issue_start_command = @import("commands/issue_start.zig");
const issue_pr_command = @import("commands/issue_pr.zig");
const issue_info_command = @import("commands/issue_info.zig");
const download_command = @import("download");
const search_command = @import("commands/search.zig");
const projects_command = @import("commands/projects.zig");
const labels_command = @import("commands/labels.zig");
const users_command = @import("commands/users.zig");
const states_command = @import("commands/states.zig");
const project_view_command = @import("commands/project_view.zig");
const project_create_command = @import("commands/project_create.zig");
const project_update_command = @import("commands/project_update.zig");
const project_delete_command = @import("commands/project_delete.zig");
const project_issues_command = @import("commands/project_issues.zig");
const milestones_command = @import("commands/milestones.zig");

const version_string = build_options.version;
const GlobalOptions = cli.GlobalOptions;
const Parsed = cli.Parsed;
const parse_global = cli.parseGlobal;

pub fn main(init: std.process.Init) !void {
    const exit_code = run(init) catch |err| {
        var stderr_buf: [0]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
        var stderr = &stderr_writer.interface;
        stderr.print("linear: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

fn run(init: std.process.Init) !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    defer graphql.deinitSharedClient(io);

    const args_raw = try init.minimal.args.toSlice(init.arena.allocator());

    const args = try allocator.alloc([]const u8, args_raw.len);
    defer allocator.free(args);
    for (args_raw, 0..) |arg, idx| {
        args[idx] = arg[0..arg.len];
    }

    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    var stderr = &stderr_writer.interface;

    const parsed = parse_global(args) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        var out_buf: [0]u8 = undefined;
        var usage_writer = std.Io.File.stderr().writer(io, &out_buf);
        try printUsage(&usage_writer.interface);
        return 1;
    };
    var opts = parsed.opts;

    const cleaned_rest = cli.stripTrailingGlobals(allocator, parsed.rest, &opts) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        var out_buf: [0]u8 = undefined;
        var usage_writer = std.Io.File.stderr().writer(io, &out_buf);
        try printUsage(&usage_writer.interface);
        return 1;
    };
    defer allocator.free(cleaned_rest);

    // Check help/version flags before requiring a subcommand
    if (opts.version) {
        try printVersion(io);
        return 0;
    }

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var usage_writer = std.Io.File.stdout().writer(io, &out_buf);
        try printUsage(&usage_writer.interface);
        return 0;
    }

    if (cleaned_rest.len == 0) {
        var out_buf: [0]u8 = undefined;
        var usage_writer = std.Io.File.stderr().writer(io, &out_buf);
        try printUsage(&usage_writer.interface);
        return 1;
    }

    const subcommand = cleaned_rest[0];
    const sub_args_raw = cleaned_rest[1..];
    const sub_args = cli.stripTrailingGlobals(allocator, sub_args_raw, &opts) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        var out_buf: [0]u8 = undefined;
        var usage_writer = std.Io.File.stderr().writer(io, &out_buf);
        try printUsage(&usage_writer.interface);
        return 1;
    };
    defer allocator.free(sub_args);

    graphql.setDefaultKeepAlive(opts.keep_alive);

    if (std.mem.eql(u8, subcommand, "help")) {
        return routeHelp(io, sub_args, stderr);
    }

    // The endpoint decides where the Authorization header is sent, so it is
    // validated before any command can build a client.
    const allow_insecure_endpoint = resolveAllowInsecureEndpoint(allocator, init.minimal.environ);
    graphql.setAllowInsecureEndpoint(allow_insecure_endpoint);
    if (opts.endpoint) |endpoint| {
        graphql.validateEndpoint(endpoint, allow_insecure_endpoint) catch |err| {
            try stderr.print("linear: --endpoint rejected: {s}\n", .{graphql.endpointErrorMessage(err)});
            return 1;
        };
    }

    var cfg = config.load(allocator, io, init.minimal.environ, opts.config_path) catch |err| switch (err) {
        config.ApiKeyError.InvalidApiKey => {
            try stderr.print(
                "failed to load config: api key must be {d}-{d} characters from [A-Za-z0-9_-]\n",
                .{ config.min_api_key_len, config.max_api_key_len },
            );
            return 1;
        },
        // A malformed `credential_helper` in the config file reaches the
        // operator here, so it gets the same sentence `config set
        // credential_helper` prints rather than a bare Zig error name like
        // `TooManyCredentialHelperArgs`.
        config.CredentialHelperError.EmptyCredentialHelper,
        config.CredentialHelperError.TooManyCredentialHelperArgs,
        config.CredentialHelperError.InvalidCredentialHelperArg,
        config.CredentialHelperError.InvalidCredentialHelper,
        => |helper_err| {
            try stderr.print("failed to load config: {s}\n", .{config.credentialHelperErrorText(helper_err)});
            return 1;
        },
        else => {
            try stderr.print("failed to load config: {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    defer cfg.deinit();
    if (cfg.permissions_warning) {
        const path = cfg.config_path orelse "(unknown)";
        try stderr.print("warning: config file {s} permissions should be 0600\n", .{path});
    }

    // `config.load` applied the two ends of the credential chain (file key,
    // then the LINEAR_API_KEY override); this fills in the two backends in
    // between and warns when the deprecated file backend is what won.
    credentials.resolve(&cfg, process.system_runner, io, stderr) catch |err| switch (err) {
        config.ApiKeyError.InvalidApiKey => {
            try stderr.print(
                "failed to resolve credentials: api key must be {d}-{d} characters from [A-Za-z0-9_-]\n",
                .{ config.min_api_key_len, config.max_api_key_len },
            );
            return 1;
        },
        else => {
            try stderr.print("failed to resolve credentials: {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    const json_output = opts.json or std.ascii.eqlIgnoreCase(cfg.default_output, "json");

    if (std.mem.eql(u8, subcommand, "gql")) {
        return gql_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "auth")) {
        return auth_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .config_path = opts.config_path,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
            .credential_runner = process.system_runner,
        });
    }

    if (std.mem.eql(u8, subcommand, "config")) {
        return config_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .config_path = opts.config_path,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
            .credential_runner = process.system_runner,
        });
    }

    if (std.mem.eql(u8, subcommand, "me")) {
        return me_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "search")) {
        return search_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "download")) {
        return download_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "teams")) {
        if (sub_args.len == 0 or !std.mem.eql(u8, sub_args[0], "list")) {
            try stderr.print("teams: expected 'list'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        return teams_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args[1..],
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "projects")) {
        if (sub_args.len == 0 or !std.mem.eql(u8, sub_args[0], "list")) {
            try stderr.print("projects: expected 'list'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        return projects_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args[1..],
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "labels")) {
        if (sub_args.len == 0 or !std.mem.eql(u8, sub_args[0], "list")) {
            try stderr.print("labels: expected 'list'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        return labels_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args[1..],
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "users")) {
        if (sub_args.len == 0 or !std.mem.eql(u8, sub_args[0], "list")) {
            try stderr.print("users: expected 'list'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        return users_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args[1..],
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "states")) {
        if (sub_args.len == 0 or !std.mem.eql(u8, sub_args[0], "list")) {
            try stderr.print("states: expected 'list'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        return states_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args[1..],
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "issues")) {
        if (sub_args.len == 0 or !std.mem.eql(u8, sub_args[0], "list")) {
            try stderr.print("issues: expected 'list'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        return issues_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args[1..],
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "issue")) {
        if (sub_args.len == 0) {
            // 'comment' additionally accepts 'list', 'update', and 'delete'.
            try stderr.print("issue: expected 'view', 'create', 'update', 'delete', 'link', 'comment', 'start', 'pr', 'id', 'url', 'title', or 'describe'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        const issue_sub = sub_args[0];
        const issue_args = sub_args[1..];
        if (std.mem.eql(u8, issue_sub, "view")) {
            return issue_view_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }
        if (std.mem.eql(u8, issue_sub, "start")) {
            return issue_start_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }
        if (std.mem.eql(u8, issue_sub, "pr")) {
            return issue_pr_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }
        if (issue_info_command.modeFromName(issue_sub) != null) {
            return issue_info_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = sub_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }
        if (std.mem.eql(u8, issue_sub, "create")) {
            return issue_create_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }
        if (std.mem.eql(u8, issue_sub, "delete")) {
            return issue_delete_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }
        if (std.mem.eql(u8, issue_sub, "update")) {
            return issue_update_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }
        if (std.mem.eql(u8, issue_sub, "link")) {
            return issue_link_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }
        if (std.mem.eql(u8, issue_sub, "comment")) {
            // `list`/`update`/`delete` are read/modify subcommands; anything
            // else in that slot is the issue identifier for comment creation.
            if (issue_args.len > 0 and issue_comments_command.isSubcommand(issue_args[0])) {
                return issue_comments_command.run(.{
                    .allocator = allocator,
                    .io = io,
                    .config = &cfg,
                    .args = issue_args,
                    .json_output = json_output,
                    .retries = opts.retries,
                    .timeout_ms = opts.timeout_ms,
                    .endpoint = opts.endpoint,
                    .git_runner = git.system_runner,
                });
            }
            return issue_comment_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = issue_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
                .git_runner = git.system_runner,
            });
        }

        try stderr.print("issue: unknown command: {s}\n", .{issue_sub});
        try printUsage(stderr);
        return 1;
    }

    if (std.mem.eql(u8, subcommand, "milestone")) {
        return milestones_command.run(.{
            .allocator = allocator,
            .io = io,
            .config = &cfg,
            .args = sub_args,
            .json_output = json_output,
            .retries = opts.retries,
            .timeout_ms = opts.timeout_ms,
            .endpoint = opts.endpoint,
        });
    }

    if (std.mem.eql(u8, subcommand, "project")) {
        if (sub_args.len == 0) {
            try stderr.print("project: expected 'view', 'create', 'update', 'delete', 'add-issue', or 'remove-issue'\n", .{});
            try printUsage(stderr);
            return 1;
        }
        const project_sub = sub_args[0];
        const project_args = sub_args[1..];
        if (std.mem.eql(u8, project_sub, "view")) {
            return project_view_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = project_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }
        if (std.mem.eql(u8, project_sub, "create")) {
            return project_create_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = project_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }
        if (std.mem.eql(u8, project_sub, "update")) {
            return project_update_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = project_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }
        if (std.mem.eql(u8, project_sub, "delete")) {
            return project_delete_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = project_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }
        if (std.mem.eql(u8, project_sub, "add-issue") or std.mem.eql(u8, project_sub, "remove-issue")) {
            return project_issues_command.run(.{
                .allocator = allocator,
                .io = io,
                .config = &cfg,
                .args = sub_args,
                .json_output = json_output,
                .retries = opts.retries,
                .timeout_ms = opts.timeout_ms,
                .endpoint = opts.endpoint,
            });
        }

        try stderr.print("project: unknown command: {s}\n", .{project_sub});
        try printUsage(stderr);
        return 1;
    }

    try stderr.print("unknown command: {s}\n", .{subcommand});
    try printUsage(stderr);
    return 1;
}

/// Only an explicit `1` opts out of the endpoint allowlist; anything else (or a
/// missing variable) keeps the safe default.
fn resolveAllowInsecureEndpoint(allocator: std.mem.Allocator, environ: std.process.Environ) bool {
    const value = environ.getAlloc(allocator, graphql.allow_insecure_endpoint_env) catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn routeHelp(io: std.Io, args: [][]const u8, stderr: anytype) !u8 {
    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;

    if (args.len == 0) {
        try printUsage(out);
        return 0;
    }

    const target = args[0];
    const tail = args[1..];

    if (std.mem.eql(u8, target, "auth")) {
        if (tail.len > 0) {
            if (std.mem.eql(u8, tail[0], "set")) {
                try auth_command.setUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "test")) {
                try auth_command.testUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "show")) {
                try auth_command.showUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "status")) {
                try auth_command.statusUsage(out);
                return 0;
            }
        }
        try auth_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "me")) {
        try me_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "config")) {
        if (tail.len > 0) {
            if (std.mem.eql(u8, tail[0], "set")) {
                try config_command.setUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "unset")) {
                try config_command.unsetUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "show")) {
                try config_command.showUsage(out);
                return 0;
            }
        }
        try config_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "teams")) {
        try teams_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "projects")) {
        try projects_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "labels")) {
        try labels_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "users")) {
        try users_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "states")) {
        try states_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "milestone")) {
        if (tail.len > 0) {
            if (std.mem.eql(u8, tail[0], "list")) {
                try milestones_command.listUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "view")) {
                try milestones_command.viewUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "create")) {
                try milestones_command.createUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "update")) {
                try milestones_command.updateUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "delete")) {
                try milestones_command.deleteUsage(out);
                return 0;
            }
        }
        try milestones_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "project")) {
        if (tail.len > 0) {
            if (std.mem.eql(u8, tail[0], "view")) {
                try project_view_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "create")) {
                try project_create_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "update")) {
                try project_update_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "delete")) {
                try project_delete_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "add-issue")) {
                try project_issues_command.addUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "remove-issue")) {
                try project_issues_command.removeUsage(out);
                return 0;
            }
        }
        try project_view_command.usage(out);
        try out.writeByte('\n');
        try project_create_command.usage(out);
        try out.writeByte('\n');
        try project_update_command.usage(out);
        try out.writeByte('\n');
        try project_delete_command.usage(out);
        try out.writeByte('\n');
        try project_issues_command.addUsage(out);
        try out.writeByte('\n');
        try project_issues_command.removeUsage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "issues")) {
        try issues_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "download")) {
        try download_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "search")) {
        try search_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "issue")) {
        if (tail.len > 0) {
            if (std.mem.eql(u8, tail[0], "view")) {
                try issue_view_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "create")) {
                try issue_create_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "delete")) {
                try issue_delete_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "update")) {
                try issue_update_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "link")) {
                try issue_link_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "start")) {
                try issue_start_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "pr")) {
                try issue_pr_command.usage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "id")) {
                try issue_info_command.idUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "url")) {
                try issue_info_command.urlUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "title")) {
                try issue_info_command.titleUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "describe")) {
                try issue_info_command.describeUsage(out);
                return 0;
            }
            if (std.mem.eql(u8, tail[0], "comment")) {
                if (tail.len > 1) {
                    if (std.mem.eql(u8, tail[1], "list")) {
                        try issue_comments_command.listUsage(out);
                        return 0;
                    }
                    if (std.mem.eql(u8, tail[1], "update")) {
                        try issue_comments_command.updateUsage(out);
                        return 0;
                    }
                    if (std.mem.eql(u8, tail[1], "delete")) {
                        try issue_comments_command.deleteUsage(out);
                        return 0;
                    }
                }
                try issue_comment_command.usage(out);
                try out.writeByte('\n');
                try issue_comments_command.listUsage(out);
                try out.writeByte('\n');
                try issue_comments_command.updateUsage(out);
                try out.writeByte('\n');
                try issue_comments_command.deleteUsage(out);
                return 0;
            }
        }
        try issue_view_command.usage(out);
        try out.writeByte('\n');
        try issue_create_command.usage(out);
        try out.writeByte('\n');
        try issue_update_command.usage(out);
        try out.writeByte('\n');
        try issue_delete_command.usage(out);
        try out.writeByte('\n');
        try issue_link_command.usage(out);
        try out.writeByte('\n');
        try issue_comment_command.usage(out);
        try out.writeByte('\n');
        try issue_comments_command.listUsage(out);
        try out.writeByte('\n');
        try issue_comments_command.updateUsage(out);
        try out.writeByte('\n');
        try issue_comments_command.deleteUsage(out);
        try out.writeByte('\n');
        try issue_start_command.usage(out);
        try out.writeByte('\n');
        try issue_pr_command.usage(out);
        try out.writeByte('\n');
        try issue_info_command.usage(out);
        return 0;
    }

    if (std.mem.eql(u8, target, "gql")) {
        try gql_command.usage(out);
        return 0;
    }

    try stderr.print("help: unknown command: {s}\n", .{target});
    try printUsage(stderr);
    return 1;
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\linear [--json] [--config PATH] [--endpoint URL] [--no-keepalive] [--retries N] [--timeout-ms MS] [--help] [--version] <command> [args]
        \\Commands:
        \\  auth set|test|show|status  Manage or validate authentication
        \\  config show|set|unset Manage CLI defaults (team/output/state filter)
        \\  me                   Show current user
        \\  teams list           List teams
        \\  search               Search issues by keyword
        \\  download             Download uploads.linear.app attachments
        \\  projects list        List projects
        \\  labels list          List issue labels (ids for 'issues list --label')
        \\  users list           List users (ids for 'issues list --assignee')
        \\  states list          List workflow states (ids for 'issues list --state-id')
        \\  issues list          List issues
        \\  issue view|create|update|delete|link  Manage issues
        \\  issue comment [list|update|delete]   Create, read, edit, or remove comments
        \\  issue start          Check out the issue's git branch and start the issue
        \\  issue pr             Open a pull request for the issue with 'gh pr create'
        \\  issue id|url|title   Print one field of the issue on a single line
        \\  issue describe       Print a commit message body with Linear trailers
        \\  project view|create|update|delete|add-issue|remove-issue  Manage projects
        \\  milestone list|view|create|update|delete  Manage project milestones
        \\  gql                  Run an arbitrary GraphQL query against Linear
        \\
        \\Issue commands infer the issue from the current git branch when no identifier is given.
        \\Use 'linear help <command>' for command-specific help and examples.
        \\Examples:
        \\  linear help issues
        \\  linear issues list --pages 2 --limit 50
        \\  linear issue view ENG-123 --json
        \\  linear issue start ENG-123 --yes
        \\
    , .{});
}

fn printVersion(io: std.Io) !void {
    var buf: [0]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const mode_label = @tagName(builtin.mode);
    const git_hash = build_options.git_hash;
    try stdout_writer.interface.print("linear {s} (git {s}, {s})\n", .{ version_string, git_hash, mode_label });
}
