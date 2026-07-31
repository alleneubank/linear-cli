//! `linear milestone list|view|create|update|delete` over Linear's
//! `ProjectMilestone` type.
//!
//! All five verbs live together the way `issue_comments.zig` keeps its verbs
//! together: they share one entity, one field projection, one project resolver,
//! and one sort-order renderer, so splitting them would duplicate more than it
//! separates.
//!
//! `issues list --milestone <UUID>` could already filter by milestone but there
//! was no way to enumerate or create one; these commands close that loop.
const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");
const bulk = @import("bulk");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    config: *config.Config,
    args: [][]const u8,
    json_output: bool,
    retries: u8,
    timeout_ms: u32,
    endpoint: ?[]const u8 = null,
};

const Mode = enum { list, view, create, update, delete };

pub const ListOptions = struct {
    project: ?[]const u8 = null,
    limit: usize = 50,
    fields: ?[]const u8 = null,
    plain: bool = false,
    no_truncate: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

pub const ViewOptions = struct {
    milestone_id: ?[]const u8 = null,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

pub const CreateOptions = struct {
    project: ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    description_file: ?[]const u8 = null,
    target_date: ?[]const u8 = null,
    sort_order: ?[]const u8 = null,
    yes: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

pub const UpdateOptions = struct {
    milestone_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    description_file: ?[]const u8 = null,
    target_date: ?[]const u8 = null,
    sort_order: ?[]const u8 = null,
    yes: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

pub const DeleteOptions = struct {
    milestone_id: ?[]const u8 = null,
    yes: bool = false,
    dry_run: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    bulk: bulk.Options = .{},
    help: bool = false,
};

const MilestoneData = struct {
    id: []const u8,
    name: []const u8,
    target_date: []const u8,
    sort_order: []const u8,
    description: []const u8,
    project: []const u8,
};

/// Reports whether `name` selects one of the milestone verbs.
pub fn isSubcommand(name: []const u8) bool {
    return parseMode(name) != null;
}

fn parseMode(name: []const u8) ?Mode {
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "view")) return .view;
    if (std.mem.eql(u8, name, "create")) return .create;
    if (std.mem.eql(u8, name, "update")) return .update;
    if (std.mem.eql(u8, name, "delete")) return .delete;
    return null;
}

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;

    if (ctx.args.len == 0) {
        try stderr.print("milestone: expected 'list', 'view', 'create', 'update', or 'delete'\n", .{});
        return 1;
    }

    if (std.mem.eql(u8, ctx.args[0], "--help") or std.mem.eql(u8, ctx.args[0], "-h")) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const mode = parseMode(ctx.args[0]) orelse {
        try stderr.print("milestone: unknown command: {s}\n", .{ctx.args[0]});
        return 1;
    };
    const rest = ctx.args[1..];

    return switch (mode) {
        .list => runList(ctx, rest),
        .view => runView(ctx, rest),
        .create => runCreate(ctx, rest),
        .update => runUpdate(ctx, rest),
        .delete => runDelete(ctx, rest),
    };
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

fn runList(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseListOptions(args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --limit value",
            else => @errorName(err),
        };
        try stderr.print("milestone list: {s}\n", .{message});
        try listUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try listUsage(&out_writer.interface);
        return 0;
    }

    const project_ref = opts.project orelse {
        try stderr.print("milestone list: --project is required\n", .{});
        return 1;
    };

    var field_buf = std.ArrayListUnmanaged(printer.MilestoneField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseMilestoneFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("milestone list: {s}\n", .{message});
        return 1;
    };

    if (opts.limit == 0) {
        try stderr.print("milestone list: --limit must be greater than zero\n", .{});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "milestone list") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const project = resolveProject(ctx.allocator, &client, project_ref, stderr, "milestone list") catch {
        return 1;
    };
    defer if (project.owned) ctx.allocator.free(project.value);

    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    const limit_i64 = std.math.cast(i64, opts.limit) orelse return error.InvalidLimit;
    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = project.value });
    try variables.object.put(var_alloc, "first", .{ .integer = limit_i64 });

    const query =
        \\query ProjectMilestones($id: String!, $first: Int!) {
        \\  project(id: $id) {
        \\    id
        \\    name
        \\    projectMilestones(first: $first) {
        \\      nodes { id name description targetDate sortOrder }
        \\      pageInfo { hasNextPage endCursor }
        \\    }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "milestone list", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "ProjectMilestones",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "milestone list", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("milestone list: response missing data\n", .{});
        return 1;
    };
    const project_obj = common.getObjectField(data_value, "project") orelse {
        try stderr.print("milestone list: project not found in response\n", .{});
        return 1;
    };
    const project_name = common.getStringField(project_obj, "name") orelse "";

    const want_table = !ctx.json_output and !opts.data_only and !opts.quiet;
    const want_data_rows = opts.data_only or opts.quiet;
    const want_raw_nodes = ctx.json_output and !opts.data_only and !opts.quiet;

    if (want_raw_nodes) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const milestones_obj = common.getObjectField(project_obj, "projectMilestones") orelse {
        try stderr.print("milestone list: projectMilestones not found in response\n", .{});
        return 1;
    };
    const nodes_array = common.getArrayField(milestones_obj, "nodes") orelse {
        try stderr.print("milestone list: nodes missing in response\n", .{});
        return 1;
    };
    const page_info = common.getObjectField(milestones_obj, "pageInfo");
    const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
    const end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;

    var rows = std.ArrayListUnmanaged(printer.MilestoneRow).empty;
    defer rows.deinit(ctx.allocator);
    var data_rows = std.ArrayListUnmanaged(MilestoneData).empty;
    defer data_rows.deinit(ctx.allocator);

    for (nodes_array.items) |node| {
        if (node != .object) continue;
        const id = common.getStringField(node, "id") orelse continue;
        const row = MilestoneData{
            .id = id,
            .name = common.getStringField(node, "name") orelse "",
            .target_date = common.getStringField(node, "targetDate") orelse "",
            .sort_order = try formatNumber(var_alloc, node, "sortOrder"),
            .description = common.getStringField(node, "description") orelse "",
            .project = project_name,
        };

        if (want_table) {
            try rows.append(ctx.allocator, .{
                .id = row.id,
                .name = row.name,
                .target_date = row.target_date,
                .sort_order = row.sort_order,
                .description = row.description,
                .project = row.project,
            });
        }
        if (want_data_rows) try data_rows.append(ctx.allocator, row);
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        for (data_rows.items) |row| {
            try stdout_iface.writeAll(row.id);
            try stdout_iface.writeByte('\n');
        }
    } else if (opts.data_only) {
        if (ctx.json_output) {
            var out_array = std.json.Array.init(var_alloc);
            for (data_rows.items) |row| {
                var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
                for (selected_fields) |field| {
                    try obj.object.put(var_alloc, fieldKey(field), .{ .string = cellValue(row, field) });
                }
                try out_array.append(obj);
            }
            var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try root_obj.object.put(var_alloc, "nodes", .{ .array = out_array });

            var page_info_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try page_info_obj.object.put(var_alloc, "hasNextPage", .{ .bool = has_next });
            if (end_cursor) |cursor_value| {
                try page_info_obj.object.put(var_alloc, "endCursor", .{ .string = cursor_value });
            }
            try root_obj.object.put(var_alloc, "pageInfo", page_info_obj);
            try root_obj.object.put(var_alloc, "limit", .{ .integer = limit_i64 });
            try printer.printJson(root_obj, stdout_iface, true);
        } else {
            for (data_rows.items) |row| {
                var first = true;
                for (selected_fields) |field| {
                    if (!first) try stdout_iface.writeByte('\t') else first = false;
                    try stdout_iface.writeAll(cellValue(row, field));
                }
                try stdout_iface.writeByte('\n');
            }
        }
    } else {
        try printer.printMilestoneTable(ctx.allocator, stdout_iface, rows.items, selected_fields, table_opts);
    }

    if (has_next and !ctx.json_output) {
        const cursor_value = end_cursor orelse "(unknown)";
        try stderr.print("milestone list: more milestones available; pagination not implemented (endCursor {s})\n", .{cursor_value});
    }

    return 0;
}

// ---------------------------------------------------------------------------
// view
// ---------------------------------------------------------------------------

fn runView(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseViewOptions(args) catch |err| {
        try stderr.print("milestone view: {s}\n", .{@errorName(err)});
        try viewUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try viewUsage(&out_writer.interface);
        return 0;
    }

    const milestone_id = opts.milestone_id orelse {
        try stderr.print("milestone view: missing milestone id\n", .{});
        return 1;
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "milestone view") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = milestone_id });

    const query =
        \\query ProjectMilestone($id: String!) {
        \\  projectMilestone(id: $id) {
        \\    id
        \\    name
        \\    description
        \\    targetDate
        \\    sortOrder
        \\    createdAt
        \\    updatedAt
        \\    project { id name }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "milestone view", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "ProjectMilestone",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "milestone view", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("milestone view: response missing data\n", .{});
        return 1;
    };
    const milestone = common.getObjectField(data_value, "projectMilestone") orelse {
        try stderr.print("milestone view: milestone '{s}' not found\n", .{milestone_id});
        return 1;
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        try printer.printJson(data_value, stdout_iface, true);
        return 0;
    }

    const id = common.getStringField(milestone, "id") orelse milestone_id;
    if (opts.quiet) {
        try stdout_iface.writeAll(id);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    const project_obj = common.getObjectField(milestone, "project");
    const project_name = if (project_obj) |p| common.getStringField(p, "name") orelse "" else "";
    const name = common.getStringField(milestone, "name") orelse "";
    const target_date = common.getStringField(milestone, "targetDate") orelse "";
    const sort_order = try formatNumber(var_alloc, milestone, "sortOrder");
    const created_at = common.getStringField(milestone, "createdAt") orelse "";
    const updated_at = common.getStringField(milestone, "updatedAt") orelse "";
    const description = common.getStringField(milestone, "description") orelse "";

    const display_pairs = [_]printer.KeyValue{
        .{ .key = "ID", .value = id },
        .{ .key = "Name", .value = name },
        .{ .key = "Project", .value = project_name },
        .{ .key = "Target", .value = target_date },
        .{ .key = "Sort", .value = sort_order },
        .{ .key = "Created", .value = created_at },
        .{ .key = "Updated", .value = updated_at },
        .{ .key = "Description", .value = description },
    };
    const data_pairs = [_]printer.KeyValue{
        .{ .key = "id", .value = id },
        .{ .key = "name", .value = name },
        .{ .key = "project", .value = project_name },
        .{ .key = "target_date", .value = target_date },
        .{ .key = "sort_order", .value = sort_order },
        .{ .key = "created_at", .value = created_at },
        .{ .key = "updated_at", .value = updated_at },
        .{ .key = "description", .value = description },
    };

    if (opts.data_only) {
        if (ctx.json_output) {
            var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            for (data_pairs) |pair| {
                try data_obj.object.put(var_alloc, pair.key, .{ .string = pair.value });
            }
            try printer.printJson(data_obj, stdout_iface, true);
            return 0;
        }
        try printer.printKeyValuesPlain(stdout_iface, data_pairs[0..]);
        return 0;
    }

    try printer.printKeyValues(stdout_iface, display_pairs[0..]);
    return 0;
}

// ---------------------------------------------------------------------------
// create
// ---------------------------------------------------------------------------

fn runCreate(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseCreateOptions(args) catch |err| {
        try stderr.print("milestone create: {s}\n", .{@errorName(err)});
        try createUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try createUsage(&out_writer.interface);
        return 0;
    }

    const project_ref = opts.project orelse {
        try stderr.print("milestone create: --project is required\n", .{});
        return 1;
    };
    const name = opts.name orelse {
        try stderr.print("milestone create: --name is required\n", .{});
        return 1;
    };

    // Resolved before any network work so a bad path never costs a request.
    const description = common.resolveContent(
        ctx.allocator,
        ctx.io,
        opts.description,
        opts.description_file,
        stderr,
        "milestone create",
        "--description",
    ) catch {
        return 1;
    };
    defer description.deinit(ctx.allocator);

    const sort_order = parseSortOrder(opts.sort_order) catch {
        try stderr.print("milestone create: invalid --sort-order value\n", .{});
        return 1;
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "milestone create") catch {
        return 1;
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const project = resolveProject(ctx.allocator, &client, project_ref, stderr, "milestone create") catch {
        return 1;
    };
    defer if (project.owned) ctx.allocator.free(project.value);

    if (!opts.yes) {
        try stderr.print("milestone create: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    try input.object.put(var_alloc, "projectId", .{ .string = project.value });
    try input.object.put(var_alloc, "name", .{ .string = name });
    if (description.value) |value| try input.object.put(var_alloc, "description", .{ .string = value });
    if (opts.target_date) |value| try input.object.put(var_alloc, "targetDate", .{ .string = value });
    if (sort_order) |value| try input.object.put(var_alloc, "sortOrder", .{ .float = value });

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "input", input);

    const mutation =
        \\mutation ProjectMilestoneCreate($input: ProjectMilestoneCreateInput!) {
        \\  projectMilestoneCreate(input: $input) {
        \\    success
        \\    projectMilestone { id name targetDate sortOrder project { id name } }
        \\    lastSyncId
        \\  }
        \\}
    ;

    return runMutation(ctx, &client, api_key, stderr, .{
        .prefix = "milestone create",
        .mutation = mutation,
        .operation_name = "ProjectMilestoneCreate",
        .payload_field = "projectMilestoneCreate",
        .variables = variables,
        .quiet = opts.quiet,
        .data_only = opts.data_only,
        .var_alloc = var_alloc,
    });
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

fn runUpdate(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseUpdateOptions(args) catch |err| {
        try stderr.print("milestone update: {s}\n", .{@errorName(err)});
        try updateUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try updateUsage(&out_writer.interface);
        return 0;
    }

    const milestone_id = opts.milestone_id orelse {
        try stderr.print("milestone update: missing milestone id\n", .{});
        return 1;
    };

    const description = common.resolveContent(
        ctx.allocator,
        ctx.io,
        opts.description,
        opts.description_file,
        stderr,
        "milestone update",
        "--description",
    ) catch {
        return 1;
    };
    defer description.deinit(ctx.allocator);

    const sort_order = parseSortOrder(opts.sort_order) catch {
        try stderr.print("milestone update: invalid --sort-order value\n", .{});
        return 1;
    };

    if (opts.name == null and description.value == null and opts.target_date == null and sort_order == null) {
        try stderr.print("milestone update: provide at least one of --name, --description, --description-file, --target-date, or --sort-order\n", .{});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "milestone update") catch {
        return 1;
    };

    if (!opts.yes) {
        try stderr.print("milestone update: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    if (opts.name) |value| try input.object.put(var_alloc, "name", .{ .string = value });
    if (description.value) |value| try input.object.put(var_alloc, "description", .{ .string = value });
    if (opts.target_date) |value| try input.object.put(var_alloc, "targetDate", .{ .string = value });
    if (sort_order) |value| try input.object.put(var_alloc, "sortOrder", .{ .float = value });

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = milestone_id });
    try variables.object.put(var_alloc, "input", input);

    const mutation =
        \\mutation ProjectMilestoneUpdate($id: String!, $input: ProjectMilestoneUpdateInput!) {
        \\  projectMilestoneUpdate(id: $id, input: $input) {
        \\    success
        \\    projectMilestone { id name targetDate sortOrder project { id name } }
        \\    lastSyncId
        \\  }
        \\}
    ;

    return runMutation(ctx, &client, api_key, stderr, .{
        .prefix = "milestone update",
        .mutation = mutation,
        .operation_name = "ProjectMilestoneUpdate",
        .payload_field = "projectMilestoneUpdate",
        .variables = variables,
        .quiet = opts.quiet,
        .data_only = opts.data_only,
        .var_alloc = var_alloc,
    });
}

const MutationRequest = struct {
    prefix: []const u8,
    mutation: []const u8,
    operation_name: []const u8,
    payload_field: []const u8,
    variables: std.json.Value,
    quiet: bool,
    data_only: bool,
    var_alloc: Allocator,
};

/// Shared tail for `create` and `update`: both return the same
/// `ProjectMilestonePayload`, so the success check and the four output modes
/// only need to exist once.
fn runMutation(
    ctx: Context,
    client: *graphql.GraphqlClient,
    api_key: []const u8,
    stderr: *std.Io.Writer,
    req: MutationRequest,
) !u8 {
    var response = common.send(ctx.allocator, req.prefix, client, .{
        .query = req.mutation,
        .variables = req.variables,
        .operation_name = req.operation_name,
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, req.prefix, &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{req.prefix});
        return 1;
    };
    const payload = common.getObjectField(data_value, req.payload_field) orelse {
        try stderr.print("{s}: {s} missing in response\n", .{ req.prefix, req.payload_field });
        return 1;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    if (!success) {
        try reportUserError(payload, stderr, req.prefix);
        return 1;
    }

    const milestone = common.getObjectField(payload, "projectMilestone") orelse {
        try stderr.print("{s}: projectMilestone missing in response\n", .{req.prefix});
        return 1;
    };

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (ctx.json_output and !req.quiet and !req.data_only) {
        try printer.printJson(data_value, stdout_iface, true);
        return 0;
    }

    const id = common.getStringField(milestone, "id") orelse "(unknown)";
    if (req.quiet) {
        try stdout_iface.writeAll(id);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    const name = common.getStringField(milestone, "name") orelse "";
    const target_date = common.getStringField(milestone, "targetDate") orelse "";
    const sort_order = try formatNumber(req.var_alloc, milestone, "sortOrder");
    const project_obj = common.getObjectField(milestone, "project");
    const project_name = if (project_obj) |p| common.getStringField(p, "name") orelse "" else "";

    const display_pairs = [_]printer.KeyValue{
        .{ .key = "ID", .value = id },
        .{ .key = "Name", .value = name },
        .{ .key = "Project", .value = project_name },
        .{ .key = "Target", .value = target_date },
        .{ .key = "Sort", .value = sort_order },
    };
    const data_pairs = [_]printer.KeyValue{
        .{ .key = "id", .value = id },
        .{ .key = "name", .value = name },
        .{ .key = "project", .value = project_name },
        .{ .key = "target_date", .value = target_date },
        .{ .key = "sort_order", .value = sort_order },
    };

    if (req.data_only) {
        if (ctx.json_output) {
            var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            for (data_pairs) |pair| {
                try data_obj.object.put(req.var_alloc, pair.key, .{ .string = pair.value });
            }
            try printer.printJson(data_obj, stdout_iface, true);
            return 0;
        }
        try printer.printKeyValuesPlain(stdout_iface, data_pairs[0..]);
        return 0;
    }

    try printer.printKeyValues(stdout_iface, display_pairs[0..]);
    return 0;
}

// ---------------------------------------------------------------------------
// delete
// ---------------------------------------------------------------------------

/// Per-item state for a `milestone delete` run; the writers and the `emitted`
/// counter are shared so a bulk JSON run emits one array.
const DeleteState = struct {
    ctx: Context,
    opts: DeleteOptions,
    client: *graphql.GraphqlClient,
    api_key: []const u8,
    stderr: *std.Io.Writer,
    stdout: *std.Io.Writer,
    json_stream: bool,
    emitted: *usize,

    fn emitJson(self: DeleteState, value: std.json.Value) !void {
        if (self.json_stream and self.emitted.* > 0) try self.stdout.writeAll(",");
        try printer.printJson(value, self.stdout, true);
        self.emitted.* += 1;
    }
};

fn runDelete(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseDeleteOptions(args) catch |err| {
        try stderr.print("milestone delete: {s}\n", .{@errorName(err)});
        try deleteUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try deleteUsage(&out_writer.interface);
        return 0;
    }

    var bulk_targets = bulk.collect(ctx.allocator, ctx.io, opts.bulk, stderr, "milestone delete") catch {
        return 1;
    };
    defer if (bulk_targets) |*targets| targets.deinit();

    if (bulk_targets != null and opts.milestone_id != null) {
        try stderr.print("milestone delete: pass a milestone id or --bulk, not both\n", .{});
        return 1;
    }

    var single_target: [1][]const u8 = undefined;
    const targets: []const []const u8 = if (bulk_targets) |resolved| resolved.items else blk: {
        single_target[0] = opts.milestone_id orelse {
            try stderr.print("milestone delete: missing milestone id\n", .{});
            return 1;
        };
        break :blk single_target[0..];
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "milestone delete") catch {
        return 1;
    };

    if (!opts.dry_run and !opts.yes) {
        try stderr.print("milestone delete: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    const bulk_mode = bulk_targets != null;
    const emits_json = ctx.json_output and !opts.quiet;
    const json_stream = bulk_mode and emits_json;

    var emitted: usize = 0;
    const state = DeleteState{
        .ctx = ctx,
        .opts = opts,
        .client = &client,
        .api_key = api_key,
        .stderr = stderr,
        .stdout = stdout_iface,
        .json_stream = json_stream,
        .emitted = &emitted,
    };

    if (json_stream) try stdout_iface.writeAll("[\n");
    const summary = try bulk.execute(DeleteState, state, targets, deleteOne);
    if (json_stream) try stdout_iface.writeAll("]\n");

    if (bulk_mode and !ctx.json_output) {
        try bulk.printSummary(stderr, "milestone delete", summary);
    }

    return summary.exitCode();
}

fn deleteOne(state: DeleteState, index: usize, target: []const u8) !bulk.Outcome {
    _ = index;
    const ctx = state.ctx;
    const opts = state.opts;
    const stderr = state.stderr;
    const stdout_iface = state.stdout;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = target });

    if (opts.dry_run) {
        const lookup_query =
            \\query ProjectMilestoneDeleteLookup($id: String!) {
            \\  projectMilestone(id: $id) {
            \\    id
            \\    name
            \\    project { id name }
            \\  }
            \\}
        ;

        var lookup_response = common.send(ctx.allocator, "milestone delete", state.client, .{
            .query = lookup_query,
            .variables = variables,
            .operation_name = "ProjectMilestoneDeleteLookup",
        }, stderr) catch {
            return .failed;
        };
        defer lookup_response.deinit();

        common.checkResponse(ctx.io, "milestone delete", &lookup_response, stderr, state.api_key) catch {
            return .failed;
        };

        const data_value = lookup_response.data() orelse {
            try stderr.print("milestone delete: response missing data\n", .{});
            return .failed;
        };
        const milestone = common.getObjectField(data_value, "projectMilestone") orelse {
            try stderr.print("milestone delete: milestone '{s}' not found\n", .{target});
            return .failed;
        };

        const resolved_id = common.getStringField(milestone, "id") orelse target;
        const resolved_name = common.getStringField(milestone, "name") orelse "";

        if (ctx.json_output) {
            var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try obj.object.put(var_alloc, "id", .{ .string = resolved_id });
            try obj.object.put(var_alloc, "name", .{ .string = resolved_name });
            try obj.object.put(var_alloc, "dry_run", .{ .bool = true });
            try state.emitJson(obj);
            return .succeeded;
        }

        if (opts.data_only) {
            const pairs = [_]printer.KeyValue{
                .{ .key = "id", .value = resolved_id },
                .{ .key = "name", .value = resolved_name },
                .{ .key = "dry_run", .value = "true" },
            };
            try printer.printKeyValuesPlain(stdout_iface, pairs[0..]);
            return .succeeded;
        }

        if (opts.quiet) {
            try stdout_iface.writeAll(resolved_id);
            try stdout_iface.writeByte('\n');
            return .succeeded;
        }

        try stdout_iface.print(
            "milestone delete: dry run; would delete \"{s}\" (id {s})\n",
            .{ resolved_name, resolved_id },
        );
        return .succeeded;
    }

    const mutation =
        \\mutation ProjectMilestoneDelete($id: String!) {
        \\  projectMilestoneDelete(id: $id) {
        \\    success
        \\    lastSyncId
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "milestone delete", state.client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "ProjectMilestoneDelete",
    }, stderr) catch {
        return .failed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "milestone delete", &response, stderr, state.api_key) catch {
        return .failed;
    };

    const data_value = response.data() orelse {
        try stderr.print("milestone delete: response missing data\n", .{});
        return .failed;
    };
    const payload = common.getObjectField(data_value, "projectMilestoneDelete") orelse {
        try stderr.print("milestone delete: projectMilestoneDelete missing in response\n", .{});
        return .failed;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    if (!success) {
        try reportUserError(payload, stderr, "milestone delete");
        return .failed;
    }

    if (ctx.json_output and !opts.quiet) {
        try state.emitJson(data_value);
        return .succeeded;
    }

    if (opts.quiet) {
        try stdout_iface.writeAll(target);
        try stdout_iface.writeByte('\n');
        return .succeeded;
    }

    if (opts.data_only) {
        const pairs = [_]printer.KeyValue{.{ .key = "id", .value = target }};
        try printer.printKeyValuesPlain(stdout_iface, pairs[0..]);
        return .succeeded;
    }

    try stdout_iface.print("milestone delete: deleted {s}\n", .{target});
    return .succeeded;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// Surfaces a payload `userError`, falling back to a generic diagnostic so a
/// failed mutation never exits quietly.
fn reportUserError(payload: std.json.Value, stderr: anytype, prefix: []const u8) !void {
    if (payload.object.get("userError")) |user_error| {
        if (user_error == .string) {
            try stderr.print("{s}: {s}\n", .{ prefix, user_error.string });
            return;
        }
        if (user_error == .object) {
            if (user_error.object.get("message")) |msg| {
                if (msg == .string) {
                    try stderr.print("{s}: {s}\n", .{ prefix, msg.string });
                    return;
                }
            }
        }
    }
    try stderr.print("{s}: request failed\n", .{prefix});
}

/// Resolves `--project` to a project id. A uuid is taken as-is; anything else
/// is looked up by slug **or** name in one request, and an ambiguous name is an
/// error rather than a silent pick.
fn resolveProject(
    allocator: Allocator,
    client: *graphql.GraphqlClient,
    identifier: []const u8,
    stderr: anytype,
    prefix: []const u8,
) !common.ResolvedId {
    const trimmed = std.mem.trim(u8, identifier, " \t");
    if (trimmed.len == 0) {
        try stderr.print("{s}: invalid --project value\n", .{prefix});
        return common.CommandError.CommandFailed;
    }
    if (isUuid(trimmed)) return .{ .value = trimmed };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var slug_cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
    try slug_cmp.object.put(var_alloc, "eq", .{ .string = trimmed });
    var slug_filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    try slug_filter.object.put(var_alloc, "slugId", slug_cmp);

    var name_cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
    try name_cmp.object.put(var_alloc, "eq", .{ .string = trimmed });
    var name_filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    try name_filter.object.put(var_alloc, "name", name_cmp);

    var alternatives = std.json.Array.init(var_alloc);
    try alternatives.append(slug_filter);
    try alternatives.append(name_filter);

    var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    try filter.object.put(var_alloc, "or", .{ .array = alternatives });

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "filter", filter);
    // Two rows is enough to tell "found" from "ambiguous".
    try variables.object.put(var_alloc, "first", .{ .integer = 2 });

    const query =
        \\query MilestoneProjectLookup($filter: ProjectFilter!, $first: Int!) {
        \\  projects(filter: $filter, first: $first) {
        \\    nodes { id name }
        \\  }
        \\}
    ;

    var response = common.send(allocator, prefix, client, .{
        .query = query,
        .variables = variables,
        .operation_name = "MilestoneProjectLookup",
    }, stderr) catch {
        return common.CommandError.CommandFailed;
    };
    defer response.deinit();

    common.checkResponse(client.io, prefix, &response, stderr, client.api_key) catch {
        return common.CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("{s}: response missing data\n", .{prefix});
        return common.CommandError.CommandFailed;
    };
    const projects_obj = common.getObjectField(data_value, "projects") orelse {
        try stderr.print("{s}: projects missing in response\n", .{prefix});
        return common.CommandError.CommandFailed;
    };
    const nodes_array = common.getArrayField(projects_obj, "nodes") orelse {
        try stderr.print("{s}: nodes missing in response\n", .{prefix});
        return common.CommandError.CommandFailed;
    };
    if (nodes_array.items.len == 0) {
        try stderr.print("{s}: project '{s}' not found\n", .{ prefix, trimmed });
        return common.CommandError.CommandFailed;
    }
    if (nodes_array.items.len > 1) {
        try stderr.print("{s}: project '{s}' is ambiguous; pass the project id\n", .{ prefix, trimmed });
        return common.CommandError.CommandFailed;
    }

    const node = nodes_array.items[0];
    if (node != .object) {
        try stderr.print("{s}: invalid project payload\n", .{prefix});
        return common.CommandError.CommandFailed;
    }
    const id_value = common.getStringField(node, "id") orelse {
        try stderr.print("{s}: project id missing in response\n", .{prefix});
        return common.CommandError.CommandFailed;
    };

    const duped = allocator.dupe(u8, id_value) catch {
        try stderr.print("{s}: failed to allocate project id\n", .{prefix});
        return common.CommandError.CommandFailed;
    };
    return .{ .value = duped, .owned = true };
}

/// `ProjectMilestone.sortOrder` is a GraphQL Float, so it arrives as a JSON
/// number and has to be rendered before it can fill a cell. The result is
/// arena-owned and lives until the caller returns.
fn formatNumber(allocator: Allocator, node: std.json.Value, key: []const u8) ![]const u8 {
    if (node != .object) return "";
    const value = node.object.get(key) orelse return "";
    return switch (value) {
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .number_string => |s| s,
        .string => |s| s,
        else => "",
    };
}

fn parseSortOrder(raw: ?[]const u8) !?f64 {
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return error.InvalidSortOrder;
    return std.fmt.parseFloat(f64, trimmed) catch error.InvalidSortOrder;
}

fn fieldKey(field: printer.MilestoneField) []const u8 {
    return switch (field) {
        .id => "id",
        .name => "name",
        .target_date => "target_date",
        .sort_order => "sort_order",
        .description => "description",
        .project => "project",
    };
}

fn cellValue(row: MilestoneData, field: printer.MilestoneField) []const u8 {
    return switch (field) {
        .id => row.id,
        .name => row.name,
        .target_date => row.target_date,
        .sort_order => row.sort_order,
        .description => row.description,
        .project => row.project,
    };
}

fn parseMilestoneFields(
    raw: ?[]const u8,
    buffer: *std.ArrayListUnmanaged(printer.MilestoneField),
    allocator: Allocator,
) ![]const printer.MilestoneField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseMilestoneFieldName(trimmed) orelse return error.InvalidField;
            if (!containsMilestoneField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.milestone_default_fields[0..];
}

fn parseMilestoneFieldName(name: []const u8) ?printer.MilestoneField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    if (std.ascii.eqlIgnoreCase(name, "target_date")) return .target_date;
    if (std.ascii.eqlIgnoreCase(name, "sort_order")) return .sort_order;
    if (std.ascii.eqlIgnoreCase(name, "description")) return .description;
    if (std.ascii.eqlIgnoreCase(name, "project")) return .project;
    return null;
}

fn containsMilestoneField(haystack: []const printer.MilestoneField, needle: printer.MilestoneField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (value[idx] != '-') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// option parsing
// ---------------------------------------------------------------------------

fn parseLimit(raw: []const u8) !usize {
    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidLimit;
    if (value <= 0) return error.InvalidLimit;
    return std.math.cast(usize, value) orelse error.InvalidLimit;
}

pub fn parseListOptions(args: []const []const u8) !ListOptions {
    var opts = ListOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.project = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project=")) {
            opts.project = arg["--project=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.limit = parseLimit(args[idx + 1]) catch return error.InvalidLimit;
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--limit=")) {
            opts.limit = parseLimit(arg["--limit=".len..]) catch return error.InvalidLimit;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fields")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.fields = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--fields=")) {
            opts.fields = arg["--fields=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            opts.plain = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-truncate")) {
            opts.no_truncate = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn parseViewOptions(args: []const []const u8) !ViewOptions {
    var opts = ViewOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (opts.milestone_id == null) {
            opts.milestone_id = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn parseCreateOptions(args: []const []const u8) !CreateOptions {
    var opts = CreateOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.project = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project=")) {
            opts.project = arg["--project=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.name = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            opts.name = arg["--name=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--description")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.description = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--description=")) {
            opts.description = arg["--description=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--description-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.description_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--description-file=")) {
            opts.description_file = arg["--description-file=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target-date")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.target_date = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target-date=")) {
            opts.target_date = arg["--target-date=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sort-order")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.sort_order = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sort-order=")) {
            opts.sort_order = arg["--sort-order=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--force")) {
            opts.yes = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn parseUpdateOptions(args: []const []const u8) !UpdateOptions {
    var opts = UpdateOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.name = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            opts.name = arg["--name=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--description")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.description = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--description=")) {
            opts.description = arg["--description=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--description-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.description_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--description-file=")) {
            opts.description_file = arg["--description-file=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target-date")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.target_date = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target-date=")) {
            opts.target_date = arg["--target-date=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sort-order")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.sort_order = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sort-order=")) {
            opts.sort_order = arg["--sort-order=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--force")) {
            opts.yes = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (opts.milestone_id == null) {
            opts.milestone_id = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn parseDeleteOptions(args: []const []const u8) !DeleteOptions {
    var opts = DeleteOptions{};
    var idx: usize = 0;
    while (idx < args.len) {
        const consumed = try bulk.parseFlag(&opts.bulk, args[idx..]);
        if (consumed > 0) {
            idx += consumed;
            continue;
        }

        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--force")) {
            opts.yes = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (opts.milestone_id == null) {
            opts.milestone_id = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

// ---------------------------------------------------------------------------
// usage
// ---------------------------------------------------------------------------

pub fn usage(writer: anytype) !void {
    try listUsage(writer);
    try writer.writeByte('\n');
    try viewUsage(writer);
    try writer.writeByte('\n');
    try createUsage(writer);
    try writer.writeByte('\n');
    try updateUsage(writer);
    try writer.writeByte('\n');
    try deleteUsage(writer);
}

pub fn listUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear milestone list --project ID|NAME [--limit N] [--fields LIST] [--plain] [--no-truncate] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --project ID|NAME  Project id, slug, or exact name (required)
        \\  --limit N          Number of milestones to fetch (default: 50)
        \\  --fields LIST      Comma-separated columns (id,name,target_date,sort_order,description,project)
        \\  --plain            Do not pad or truncate table cells
        \\  --no-truncate      Disable ellipsis and padding in table cells
        \\  --quiet            Print only milestone ids (one per line)
        \\  --data-only        Emit tab-separated rows (or JSON array with --json)
        \\  --help             Show this help message
        \\Examples:
        \\  linear milestone list --project "Roadmap"
        \\  linear issues list --team ENG --milestone "$(linear milestone list --project Roadmap --quiet | head -1)"
        \\
    , .{});
}

pub fn viewUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear milestone view <ID> [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --quiet      Print only the milestone id
        \\  --data-only  Emit tab-separated fields (or JSON object with --json)
        \\  --help       Show this help message
        \\Examples:
        \\  linear milestone view 6f0f2e4c-8b2b-4c6a-9b0f-6a4b1d2c3e4f --json
        \\
    , .{});
}

pub fn createUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear milestone create --project ID|NAME --name NAME [--description TEXT|--description-file PATH] [--target-date DATE] [--sort-order N] [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --project ID|NAME     Project id, slug, or exact name (required)
        \\  --name NAME           Milestone name (required)
        \\  --description TEXT    Milestone description
        \\  --description-file PATH  Read the description from a file (use '-' for stdin)
        \\  --target-date DATE    ISO target date (YYYY-MM-DD)
        \\  --sort-order N        Position within the project (float; lower sorts first)
        \\  --yes                 Skip confirmation prompt (alias: --force)
        \\  --quiet               Print only the milestone id
        \\  --data-only           Emit tab-separated fields (or JSON object with --json)
        \\  --help                Show this help message
        \\Examples:
        \\  linear milestone create --project Roadmap --name "Beta" --target-date 2026-09-30 --yes
        \\  linear milestone create --project Roadmap --name "GA" --description-file notes.md --yes --quiet
        \\
    , .{});
}

pub fn updateUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear milestone update <ID> [--name NAME] [--description TEXT|--description-file PATH] [--target-date DATE] [--sort-order N] [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --name NAME           New milestone name
        \\  --description TEXT    New description
        \\  --description-file PATH  Read the description from a file (use '-' for stdin)
        \\  --target-date DATE    ISO target date (YYYY-MM-DD)
        \\  --sort-order N        Position within the project (float; lower sorts first)
        \\  --yes                 Skip confirmation prompt (alias: --force)
        \\  --quiet               Print only the milestone id
        \\  --data-only           Emit tab-separated fields (or JSON object with --json)
        \\  --help                Show this help message
        \\At least one field flag is required.
        \\Examples:
        \\  linear milestone update 6f0f2e4c-8b2b-4c6a-9b0f-6a4b1d2c3e4f --target-date 2026-10-15 --yes
        \\
    , .{});
}

pub fn deleteUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear milestone delete <ID> --yes [--dry-run] [--quiet] [--data-only] [--help]
        \\       linear milestone delete --bulk ID,ID | --bulk-file PATH | --bulk-stdin --yes [--dry-run] [...]
        \\Flags:
        \\  --yes            Skip confirmation prompt (alias: --force)
        \\  --dry-run        Resolve and validate the milestone without deleting; exits 0
        \\  --quiet          Print only the milestone id
        \\  --data-only      Emit tab-separated fields (or JSON object with --json)
        \\  --bulk ID,ID     Delete several milestones in one serial run (ids are deduplicated)
        \\  --bulk-file PATH Read bulk ids from a file, one per line or comma separated ('-' for stdin)
        \\  --bulk-stdin     Read bulk ids from stdin
        \\  --help           Show this help message
        \\Bulk runs keep going after a failed item, print a succeeded/failed summary on
        \\stderr (suppressed with --json), and exit non-zero when any item failed.
        \\Examples:
        \\  linear milestone delete 6f0f2e4c-8b2b-4c6a-9b0f-6a4b1d2c3e4f --yes
        \\  linear milestone list --project Roadmap --quiet | linear milestone delete --bulk-stdin --dry-run
        \\
    , .{});
}
