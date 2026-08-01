const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");

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

/// Every field `IssueSortInput` accepts, in schema declaration order. Each one
/// takes its own input type (`PrioritySort`, `ManualSort`, ...), but all of them
/// carry the same `order: PaginationSortOrder`, so one `{ <field>: { order } }`
/// shape covers the whole set.
///
/// Tag names are the schema spellings, which makes `graphqlName` a plain
/// `@tagName` for everything but the two timestamp fields: those keep the short
/// tags the flag shipped with (`--sort created|updated`), and map back to
/// `createdAt`/`updatedAt` on the wire.
const SortField = enum {
    priority,
    estimate,
    title,
    label,
    labelGroup,
    slaStatus,
    created,
    updated,
    completedAt,
    dueDate,
    accumulatedStateUpdatedAt,
    cycle,
    milestone,
    assignee,
    delegate,
    project,
    team,
    manual,
    workflowState,
    customer,
    customerRevenue,
    customerCount,
    customerImportantCount,
    rootIssue,
    linkCount,
    release,

    /// The `IssueSortInput` key this field is sent as, and the canonical value
    /// `--sort` accepts for it.
    fn graphqlName(self: SortField) []const u8 {
        return switch (self) {
            .created => "createdAt",
            .updated => "updatedAt",
            else => @tagName(self),
        };
    }
};

/// Canonical `--sort` field names, comma-joined for the invalid-value
/// diagnostic. Derived from `SortField`, so a new field cannot drift out of the
/// message that lists them.
const sort_field_list: []const u8 = blk: {
    var out: []const u8 = "";
    for (std.enums.values(SortField), 0..) |field, idx| {
        const name: []const u8 = field.graphqlName();
        out = if (idx == 0) name else out ++ ", " ++ name;
    }
    break :blk out;
};

/// Column the help text's wrapped field list continues at (the description
/// column, past the `Fields: ` label).
const sort_help_indent = " " ** 32;
/// Width the wrapped field list is allowed to occupy after `sort_help_indent`.
const sort_help_width = 62;

/// The same list, wrapped into the help text's description column.
const sort_field_help: []const u8 = blk: {
    var out: []const u8 = "";
    var line_len: usize = 0;
    for (std.enums.values(SortField), 0..) |field, idx| {
        const name: []const u8 = field.graphqlName();
        if (idx == 0) {
            out = name;
            line_len = name.len;
        } else if (line_len + 2 + name.len > sort_help_width) {
            out = out ++ ",\n" ++ sort_help_indent ++ name;
            line_len = name.len;
        } else {
            out = out ++ ", " ++ name;
            line_len += 2 + name.len;
        }
    }
    break :blk out;
};

const SortDirection = enum {
    asc,
    desc,
};

const Sort = struct {
    field: SortField,
    direction: SortDirection,
};

const Options = struct {
    team: ?[]const u8 = null,
    state_type: ?[]const u8 = null,
    state_id: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    label: ?[]const u8 = null,
    updated_since: ?[]const u8 = null,
    created_since: ?[]const u8 = null,
    sort: ?Sort = null,
    limit: usize = 25,
    max_items: ?usize = null,
    sub_limit: usize = 10,
    sub_limit_explicit: bool = false,
    cursor: ?[]const u8 = null,
    pages: ?usize = null,
    all: bool = false,
    fields: ?[]const u8 = null,
    project: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    include_projects: bool = false,
    plain: bool = false,
    no_truncate: bool = false,
    human_time: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

const DataRow = struct {
    identifier: []const u8,
    title: []const u8,
    state: []const u8,
    assignee: []const u8,
    priority: []const u8,
    parent_identifier: []const u8,
    parent_url: []const u8,
    sub_issue_identifiers: []const u8,
    project: []const u8,
    milestone: []const u8,
    created_raw: []const u8,
    updated_raw: []const u8,
    url: []const u8,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    var opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidPageCount => "invalid --pages value",
            error.InvalidLimit => "invalid --limit value",
            error.InvalidSort => "invalid --sort value",
            else => @errorName(err),
        };
        try stderr.print("issues list: {s}\n", .{message});
        // "invalid --sort value" alone was actionable when there were two
        // fields; with the whole `IssueSortInput` vocabulary it is not, so the
        // diagnostic spells the accepted values out.
        if (err == error.InvalidSort) try printSortVocabulary(stderr);
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issues") catch {
        return 1;
    };

    var field_buf = std.ArrayListUnmanaged(printer.IssueField).empty;
    defer field_buf.deinit(ctx.allocator);
    var selected_fields = parseIssueFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("issues list: {s}\n", .{message});
        return 1;
    };
    if (opts.include_projects) {
        if (!containsIssueField(selected_fields, .project)) try field_buf.append(ctx.allocator, .project);
        if (!containsIssueField(selected_fields, .milestone)) try field_buf.append(ctx.allocator, .milestone);
        selected_fields = field_buf.items;
    }
    // `children(first:)` is a per-issue sub-query, so it is only worth paying for
    // when the caller actually wants sub-issues: either the `sub_issues` column is
    // selected, or `--sub-limit` was passed explicitly. Without this gate the
    // default field set (which excludes sub-issues) still fetched and discarded
    // them. `--sub-limit 0` remains the explicit opt-out.
    const sub_requested = containsIssueField(selected_fields, .sub_issues) or opts.sub_limit_explicit;
    const sub_enabled = sub_requested and opts.sub_limit > 0;
    if (!sub_enabled) {
        var write: usize = 0;
        for (selected_fields) |field| {
            if (field == .sub_issues) continue;
            field_buf.items[write] = field;
            write += 1;
        }
        field_buf.items.len = write;
        selected_fields = field_buf.items;
    }
    const fields_include_parent = containsIssueField(selected_fields, .parent);
    const fields_include_project = containsIssueField(selected_fields, .project);
    const fields_include_milestone = containsIssueField(selected_fields, .milestone);
    const parent_enabled = sub_enabled or fields_include_parent;
    const project_enabled = opts.include_projects or fields_include_project;
    const milestone_enabled = opts.include_projects or fields_include_milestone;
    if (selected_fields.len == 0) {
        try stderr.print("issues list: no fields selected\n", .{});
        return 1;
    }
    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    const team_value = opts.team orelse ctx.config.default_team_id;
    if (team_value.len == 0) {
        try stderr.print("issues list: missing team selection\n", .{});
        return 1;
    }
    if (opts.max_items) |max_value| {
        if (max_value == 0) {
            try stderr.print("issues list: invalid --max-items value\n", .{});
            return 1;
        }
    }

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var query_builder = std.ArrayListUnmanaged(u8).empty;
    defer query_builder.deinit(ctx.allocator);
    try query_builder.appendSlice(
        ctx.allocator,
        "query Issues($filter: IssueFilter, $first: Int!, $after: String, $orderBy: PaginationOrderBy, $sort: [IssueSortInput!]",
    );
    if (sub_enabled) try query_builder.appendSlice(ctx.allocator, ", $subLimit: Int!");
    try query_builder.appendSlice(
        ctx.allocator,
        ") {\n  issues(filter: $filter, first: $first, after: $after, orderBy: $orderBy, sort: $sort) {\n    nodes {\n      id\n      identifier\n      title\n      state { name type }\n      assignee { name }\n      priorityLabel\n      createdAt\n      updatedAt\n      url\n",
    );
    if (parent_enabled) try query_builder.appendSlice(ctx.allocator, "      parent { identifier url }\n");
    if (sub_enabled) try query_builder.appendSlice(ctx.allocator, "      children(first: $subLimit) { nodes { identifier url } pageInfo { hasNextPage } }\n");
    if (project_enabled) try query_builder.appendSlice(ctx.allocator, "      project { name }\n");
    if (milestone_enabled) try query_builder.appendSlice(ctx.allocator, "      milestone: projectMilestone { title: name }\n");
    try query_builder.appendSlice(
        ctx.allocator,
        "    }\n    pageInfo {\n      hasNextPage\n      endCursor\n    }\n  }\n}\n",
    );
    const query = query_builder.items;

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    validateTeamSelection(ctx, &client, team_value, stderr) catch |err| switch (err) {
        error.InvalidTeam => {
            try stderr.print("issues list: team '{s}' not found\n", .{team_value});
            return 1;
        },
        common.CommandError.CommandFailed => return 1,
        else => {
            try stderr.print("issues list: {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    var owned_assignee: ?[]const u8 = null;
    defer if (owned_assignee) |value| ctx.allocator.free(value);
    if (opts.assignee) |assignee_raw| {
        const trimmed = std.mem.trim(u8, assignee_raw, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, "me")) {
            const viewer_id = common.resolveViewerId(ctx.allocator, &client, stderr, "issues list") catch {
                return 1;
            };
            owned_assignee = viewer_id;
            opts.assignee = viewer_id;
        } else if (trimmed.len != assignee_raw.len or trimmed.ptr != assignee_raw.ptr) {
            opts.assignee = trimmed;
        }
    }

    var responses = std.ArrayListUnmanaged(graphql.GraphqlClient.Response).empty;
    defer {
        for (responses.items) |*resp| resp.deinit();
        responses.deinit(ctx.allocator);
    }

    var rows = std.ArrayListUnmanaged(printer.IssueRow).empty;
    defer rows.deinit(ctx.allocator);

    var owned_times = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (owned_times.items) |value| ctx.allocator.free(value);
        owned_times.deinit(ctx.allocator);
    }

    var data_rows = std.ArrayListUnmanaged(DataRow).empty;
    defer data_rows.deinit(ctx.allocator);

    var nodes_accumulator = std.ArrayListUnmanaged(std.json.Value).empty;
    defer nodes_accumulator.deinit(ctx.allocator);

    var total_fetched: usize = 0;
    var page_count: usize = 0;
    var more_available = false;
    var max_items_reached = false;
    var sub_truncated = false;
    var last_end_cursor: ?[]const u8 = null;
    const page_size = opts.limit;
    var next_cursor = opts.cursor;
    const want_table = !ctx.json_output and !opts.data_only and !opts.quiet;
    const want_data_rows = opts.data_only or opts.quiet;
    const want_raw_nodes = ctx.json_output and !opts.data_only and !opts.quiet;
    const page_limit: ?usize = if (opts.all) null else opts.pages orelse 1;

    while (true) {
        if (page_limit) |limit_pages| {
            if (page_count >= limit_pages) break;
        }

        const variables = buildVariables(
            var_alloc,
            team_value,
            opts,
            ctx.config.default_state_filter,
            page_size,
            next_cursor,
            if (sub_enabled) opts.sub_limit else null,
        ) catch |err| {
            try stderr.print("issues list: {s}\n", .{@errorName(err)});
            return 1;
        };

        var response = common.send(ctx.allocator, "issues", &client, .{
            .query = query,
            .variables = variables,
            .operation_name = "Issues",
        }, stderr) catch {
            return 1;
        };
        var response_owned = true;
        errdefer if (response_owned) response.deinit();

        // `errdefer` does not fire on `return 1` — that is a successful return of
        // an exit code — so a rejected page has to be freed by hand before the
        // ownership transfer below takes over.
        common.checkResponse(ctx.io, "issues", &response, stderr, api_key) catch {
            if (response_owned) response.deinit();
            return 1;
        };

        try responses.append(ctx.allocator, response);
        response_owned = false;
        const resp = &responses.items[responses.items.len - 1];

        const data_value = resp.data() orelse {
            try stderr.print("issues list: response missing data\n", .{});
            return 1;
        };

        const issues_obj = common.getObjectField(data_value, "issues") orelse {
            try stderr.print("issues list: issues not found in response\n", .{});
            return 1;
        };
        const nodes_array = common.getArrayField(issues_obj, "nodes") orelse {
            try stderr.print("issues list: nodes missing in response\n", .{});
            return 1;
        };

        if (opts.max_items) |max_value| {
            if (total_fetched >= max_value) {
                max_items_reached = true;
                break;
            }
        }

        const take_count = @min(nodes_array.items.len, page_size);
        const remaining_allowed = if (opts.max_items) |max_value| max_value - total_fetched else take_count;
        const allowed_count = @min(take_count, remaining_allowed);
        const page_nodes = nodes_array.items[0..allowed_count];

        total_fetched += allowed_count;
        if (opts.max_items) |max_value| {
            if (total_fetched >= max_value) max_items_reached = true;
        }
        page_count += 1;

        if (want_raw_nodes) {
            const sanitize = (!parent_enabled) or (!sub_enabled) or (!project_enabled) or (!milestone_enabled);
            for (page_nodes) |node| {
                if (node != .object) continue;
                if (!sanitize) {
                    try nodes_accumulator.append(ctx.allocator, node);
                    continue;
                }

                var cleaned = std.json.Value{ .object = std.json.ObjectMap.empty };
                var iter = node.object.iterator();
                while (iter.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const is_sub_key = std.mem.eql(u8, key, "children") or std.mem.eql(u8, key, "subIssues");
                    const is_milestone_key = std.mem.eql(u8, key, "milestone") or std.mem.eql(u8, key, "projectMilestone");
                    const skip = (!parent_enabled and std.mem.eql(u8, key, "parent")) or
                        (!sub_enabled and is_sub_key) or
                        (!project_enabled and std.mem.eql(u8, key, "project")) or
                        (!milestone_enabled and is_milestone_key);
                    if (skip) continue;
                    try cleaned.object.put(var_alloc, key, entry.value_ptr.*);
                }
                try nodes_accumulator.append(ctx.allocator, cleaned);
            }
        }

        if (want_table or want_data_rows) {
            for (page_nodes) |node| {
                if (node != .object) continue;

                const identifier = common.getStringField(node, "identifier") orelse continue;
                const title = common.getStringField(node, "title") orelse "";
                const state_obj = common.getObjectField(node, "state");
                const state_name = if (state_obj) |st| common.getStringField(st, "name") else null;
                const state_type = if (state_obj) |st| common.getStringField(st, "type") else null;
                const state_value = state_name orelse state_type orelse "";
                const assignee_obj = common.getObjectField(node, "assignee");
                const assignee_name = if (assignee_obj) |assignee| common.getStringField(assignee, "name") else null;
                const assignee_value = assignee_name orelse "(unassigned)";
                const priority = common.getStringField(node, "priorityLabel") orelse "";
                const created_raw = common.getStringField(node, "createdAt") orelse "";
                const updated_raw = common.getStringField(node, "updatedAt") orelse "";
                const url = common.getStringField(node, "url") orelse "";
                const parent_obj = if (parent_enabled) common.getObjectField(node, "parent") else null;
                const parent_identifier = if (parent_obj) |p| common.getStringField(p, "identifier") else null;
                const parent_url = if (parent_obj) |p| common.getStringField(p, "url") else null;
                const parent_display = if (parent_enabled) parent_identifier orelse "" else "";
                var sub_display: []const u8 = "";
                if (sub_enabled) {
                    const subs_obj = common.getObjectField(node, "children") orelse common.getObjectField(node, "subIssues");
                    if (subs_obj) |subs| {
                        if (common.getArrayField(subs, "nodes")) |sub_nodes| {
                            var joined = std.ArrayListUnmanaged(u8).empty;
                            defer joined.deinit(ctx.allocator);
                            for (sub_nodes.items, 0..) |sub, idx| {
                                if (sub != .object) continue;
                                const sub_ident = common.getStringField(sub, "identifier") orelse continue;
                                if (idx > 0) try joined.appendSlice(ctx.allocator, ", ");
                                try joined.appendSlice(ctx.allocator, sub_ident);
                            }
                            if (joined.items.len > 0) {
                                const owned = try joined.toOwnedSlice(ctx.allocator);
                                try owned_times.append(ctx.allocator, owned);
                                sub_display = owned;
                            }
                        }
                        if (common.getObjectField(subs, "pageInfo")) |si_page| {
                            if (common.getBoolField(si_page, "hasNextPage") orelse false) sub_truncated = true;
                        }
                    }
                }
                const project_obj = if (project_enabled) common.getObjectField(node, "project") else null;
                const project_name = if (project_obj) |proj| common.getStringField(proj, "name") else null;
                const milestone_obj = if (milestone_enabled)
                    common.getObjectField(node, "milestone") orelse common.getObjectField(node, "projectMilestone")
                else
                    null;
                const milestone_title = if (milestone_obj) |m|
                    common.getStringField(m, "title") orelse common.getStringField(m, "name")
                else
                    null;

                var updated_display = updated_raw;
                if (opts.human_time and want_table) {
                    const formatted = printer.humanTime(ctx.allocator, ctx.io, updated_raw, null) catch null;
                    if (formatted) |value| {
                        try owned_times.append(ctx.allocator, value);
                        updated_display = value;
                    }
                }

                if (want_table) {
                    try rows.append(ctx.allocator, .{
                        .identifier = identifier,
                        .title = title,
                        .state = state_value,
                        .assignee = assignee_value,
                        .priority = priority,
                        .parent = parent_display,
                        .sub_issues = if (sub_enabled) sub_display else "",
                        .project = if (project_enabled) project_name orelse "" else "",
                        .milestone = if (milestone_enabled) milestone_title orelse "" else "",
                        .updated = updated_display,
                    });
                }

                if (want_data_rows) {
                    try data_rows.append(ctx.allocator, .{
                        .identifier = identifier,
                        .title = title,
                        .state = state_value,
                        .assignee = assignee_value,
                        .priority = priority,
                        .parent_identifier = if (parent_enabled) parent_identifier orelse "" else "",
                        .parent_url = if (parent_enabled) parent_url orelse "" else "",
                        .sub_issue_identifiers = if (sub_enabled) sub_display else "",
                        .project = if (project_enabled) project_name orelse "" else "",
                        .milestone = if (milestone_enabled) milestone_title orelse "" else "",
                        .created_raw = created_raw,
                        .updated_raw = updated_raw,
                        .url = url,
                    });
                }
            }
        }

        const page_info = common.getObjectField(issues_obj, "pageInfo");
        const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
        last_end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;
        more_available = has_next;

        if (allowed_count < take_count and opts.max_items != null) {
            max_items_reached = true;
        }

        if (take_count == 0 or allowed_count == 0) {
            if (has_next) {
                try stderr.print("issues list: received empty page; stopping pagination\n", .{});
            }
            break;
        }

        if (!has_next) break;
        if (page_limit) |limit_pages| {
            if (page_count >= limit_pages) break;
        }
        if (max_items_reached) {
            more_available = true;
            break;
        }
        if (last_end_cursor == null) {
            try stderr.print("issues list: missing endCursor for additional page\n", .{});
            break;
        }
        next_cursor = last_end_cursor;
    }

    if (max_items_reached) {
        more_available = true;
    }

    if (opts.quiet) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        for (data_rows.items) |row| {
            try out_writer.interface.writeAll(row.identifier);
            try out_writer.interface.writeByte('\n');
        }
    } else if (opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        if (ctx.json_output) {
            var out_array = std.json.Array.init(var_alloc);
            for (data_rows.items) |row| {
                var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
                try obj.object.put(var_alloc, "identifier", .{ .string = row.identifier });
                try obj.object.put(var_alloc, "title", .{ .string = row.title });
                try obj.object.put(var_alloc, "state", .{ .string = row.state });
                try obj.object.put(var_alloc, "assignee", .{ .string = row.assignee });
                try obj.object.put(var_alloc, "priority", .{ .string = row.priority });
                if (row.parent_identifier.len > 0) try obj.object.put(var_alloc, "parent_identifier", .{ .string = row.parent_identifier });
                if (row.parent_url.len > 0) try obj.object.put(var_alloc, "parent_url", .{ .string = row.parent_url });
                if (row.sub_issue_identifiers.len > 0) {
                    var subs = std.json.Array.init(var_alloc);
                    var iter = std.mem.splitSequence(u8, row.sub_issue_identifiers, ", ");
                    while (iter.next()) |entry| {
                        if (entry.len == 0) continue;
                        try subs.append(.{ .string = entry });
                    }
                    try obj.object.put(var_alloc, "sub_issue_identifiers", .{ .array = subs });
                }
                if (row.project.len > 0) try obj.object.put(var_alloc, "project", .{ .string = row.project });
                if (row.milestone.len > 0) try obj.object.put(var_alloc, "milestone", .{ .string = row.milestone });
                if (row.created_raw.len > 0) {
                    try obj.object.put(var_alloc, "created_at", .{ .string = row.created_raw });
                }
                try obj.object.put(var_alloc, "updated_at", .{ .string = row.updated_raw });
                try obj.object.put(var_alloc, "url", .{ .string = row.url });
                try out_array.append(obj);
            }
            var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try root_obj.object.put(var_alloc, "nodes", .{ .array = out_array });

            var page_info_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try page_info_obj.object.put(var_alloc, "hasNextPage", .{ .bool = more_available });
            if (last_end_cursor) |cursor_value| {
                try page_info_obj.object.put(var_alloc, "endCursor", .{ .string = cursor_value });
            }
            try root_obj.object.put(var_alloc, "pageInfo", page_info_obj);
            const limit_value: i64 = @intCast(page_size);
            try root_obj.object.put(var_alloc, "limit", .{ .integer = limit_value });
            if (opts.max_items) |max_value| {
                const max_i64: i64 = std.math.cast(i64, max_value) orelse limit_value;
                try root_obj.object.put(var_alloc, "maxItems", .{ .integer = max_i64 });
            }
            if (opts.sort) |sort_value| {
                var sort_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
                const sort_field = sort_value.field.graphqlName();
                const sort_dir = switch (sort_value.direction) {
                    .asc => "asc",
                    .desc => "desc",
                };
                try sort_obj.object.put(var_alloc, "field", .{ .string = sort_field });
                try sort_obj.object.put(var_alloc, "direction", .{ .string = sort_dir });
                try root_obj.object.put(var_alloc, "sort", sort_obj);
            }
            try printer.printJson(root_obj, &out_writer.interface, true);
        } else {
            for (data_rows.items) |row| {
                var first = true;
                for (selected_fields) |field| {
                    const value = switch (field) {
                        .identifier => row.identifier,
                        .title => row.title,
                        .state => row.state,
                        .assignee => row.assignee,
                        .priority => row.priority,
                        .parent => row.parent_identifier,
                        .sub_issues => row.sub_issue_identifiers,
                        .project => row.project,
                        .milestone => row.milestone,
                        .updated => row.updated_raw,
                    };
                    if (!first) try out_writer.interface.writeByte('\t') else first = false;
                    try out_writer.interface.writeAll(value);
                }
                if (!first) try out_writer.interface.writeByte('\t');
                try out_writer.interface.writeAll(row.url);
                try out_writer.interface.writeByte('\n');
            }
        }
    } else if (ctx.json_output) {
        var nodes_value = std.json.Value{ .array = std.json.Array.init(var_alloc) };
        try nodes_value.array.appendSlice(nodes_accumulator.items);

        var page_info_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try page_info_obj.object.put(var_alloc, "hasNextPage", .{ .bool = more_available });
        if (last_end_cursor) |cursor_value| {
            try page_info_obj.object.put(var_alloc, "endCursor", .{ .string = cursor_value });
        }

        var issues_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try issues_obj.object.put(var_alloc, "nodes", nodes_value);
        try issues_obj.object.put(var_alloc, "pageInfo", page_info_obj);

        var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try root_obj.object.put(var_alloc, "issues", issues_obj);
        try root_obj.object.put(var_alloc, "pageInfo", page_info_obj);
        const limit_value: i64 = @intCast(page_size);
        try root_obj.object.put(var_alloc, "limit", .{ .integer = limit_value });
        if (opts.max_items) |max_value| {
            const max_i64: i64 = std.math.cast(i64, max_value) orelse limit_value;
            try root_obj.object.put(var_alloc, "maxItems", .{ .integer = max_i64 });
        }
        if (opts.sort) |sort_value| {
            var sort_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            const sort_field = sort_value.field.graphqlName();
            const sort_dir = switch (sort_value.direction) {
                .asc => "asc",
                .desc => "desc",
            };
            try sort_obj.object.put(var_alloc, "field", .{ .string = sort_field });
            try sort_obj.object.put(var_alloc, "direction", .{ .string = sort_dir });
            try root_obj.object.put(var_alloc, "sort", sort_obj);
        }

        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(root_obj, &out_writer.interface, true);
    } else {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printIssueTable(ctx.allocator, &out_writer.interface, rows.items, selected_fields, table_opts);
    }

    try common.printPageSummary(stderr, "issues list", .{
        .items = total_fetched,
        .pages = page_count,
        .more_available = more_available,
        .end_cursor = last_end_cursor,
        .max_items_reached = max_items_reached,
    }, ctx.json_output);
    if (sub_truncated and sub_enabled) {
        try stderr.print("issues list: sub-issues limited to {d}; additional sub-issues omitted\n", .{opts.sub_limit});
    }

    return 0;
}

fn validateTeamSelection(
    ctx: Context,
    client: *graphql.GraphqlClient,
    team_value: []const u8,
    stderr: anytype,
) !void {
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
        \\    nodes { id }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issues list", client, .{
        .query = query,
        .variables = variables,
        .operation_name = "TeamLookup",
    }, stderr) catch {
        return common.CommandError.CommandFailed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issues list", &response, stderr, client.api_key) catch {
        return common.CommandError.CommandFailed;
    };

    const data_value = response.data() orelse {
        try stderr.print("issues list: response missing data\n", .{});
        return common.CommandError.CommandFailed;
    };
    const teams_obj = common.getObjectField(data_value, "teams") orelse {
        try stderr.print("issues list: teams missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    const nodes_array = common.getArrayField(teams_obj, "nodes") orelse {
        try stderr.print("issues list: team nodes missing in response\n", .{});
        return common.CommandError.CommandFailed;
    };
    if (nodes_array.items.len == 0) return error.InvalidTeam;

    const first = nodes_array.items[0];
    if (first != .object) {
        try stderr.print("issues list: invalid team payload\n", .{});
        return common.CommandError.CommandFailed;
    }
    if (common.getStringField(first, "id") == null) {
        try stderr.print("issues list: team id missing in response\n", .{});
        return common.CommandError.CommandFailed;
    }
}

fn buildVariables(
    allocator: Allocator,
    team: []const u8,
    opts: Options,
    default_state_filter: []const []const u8,
    page_size: usize,
    cursor: ?[]const u8,
    sub_limit: ?usize,
) !std.json.Value {
    const page_size_i64 = std.math.cast(i64, page_size) orelse return error.InvalidLimit;

    var vars = std.json.Value{ .object = std.json.ObjectMap.empty };
    try vars.object.put(allocator, "first", .{ .integer = page_size_i64 });
    if (sub_limit) |limit_value| {
        const limit_i64 = std.math.cast(i64, limit_value) orelse return error.InvalidLimit;
        try vars.object.put(allocator, "subLimit", .{ .integer = limit_i64 });
    }

    var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
    var team_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    try eq_obj.object.put(allocator, "eq", .{ .string = team });
    if (isUuid(team)) {
        try team_obj.object.put(allocator, "id", eq_obj);
    } else {
        try team_obj.object.put(allocator, "key", eq_obj);
    }
    try filter.object.put(allocator, "team", team_obj);

    var state_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    const has_state_type = opts.state_type != null;
    const has_state_id = opts.state_id != null;
    if (has_state_type) {
        const state_values = parseStateTypeCsvValues(allocator, opts.state_type.?) catch |err| switch (err) {
            error.EmptyList => return error.InvalidStateFilter,
            else => return err,
        };
        var state_type_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try state_type_obj.object.put(allocator, "in", .{ .array = state_values });
        try state_obj.object.put(allocator, "type", state_type_obj);
    } else if (!has_state_id) {
        var state_values = std.json.Array.init(allocator);
        for (default_state_filter) |entry| {
            try state_values.append(.{ .string = entry });
        }
        var state_type_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try state_type_obj.object.put(allocator, "nin", .{ .array = state_values });
        try state_obj.object.put(allocator, "type", state_type_obj);
    }

    if (has_state_id) {
        const state_ids = parseCsvValues(allocator, opts.state_id.?) catch |err| switch (err) {
            error.EmptyList => return error.InvalidStateIdFilter,
            else => return err,
        };
        var state_id_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try state_id_obj.object.put(allocator, "in", .{ .array = state_ids });
        try state_obj.object.put(allocator, "id", state_id_obj);
    }

    try filter.object.put(allocator, "state", state_obj);

    if (opts.assignee) |assignee_value| {
        const trimmed = std.mem.trim(u8, assignee_value, " \t");
        if (trimmed.len == 0) return error.InvalidAssigneeFilter;

        var id_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try id_obj.object.put(allocator, "eq", .{ .string = trimmed });

        var assignee_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try assignee_obj.object.put(allocator, "id", id_obj);
        try filter.object.put(allocator, "assignee", assignee_obj);
    }

    if (opts.label) |label_value| {
        const label_ids = parseCsvValues(allocator, label_value) catch |err| switch (err) {
            error.EmptyList => return error.InvalidLabelFilter,
            else => return err,
        };
        var id_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try id_obj.object.put(allocator, "in", .{ .array = label_ids });

        var label_filter = std.json.Value{ .object = std.json.ObjectMap.empty };
        try label_filter.object.put(allocator, "id", id_obj);

        var labels_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try labels_obj.object.put(allocator, "some", label_filter);
        try filter.object.put(allocator, "labels", labels_obj);
    }

    if (opts.updated_since) |updated_value| {
        const trimmed = std.mem.trim(u8, updated_value, " \t");
        if (trimmed.len == 0) return error.InvalidUpdatedSinceFilter;

        var updated_cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
        try updated_cmp.object.put(allocator, "gt", .{ .string = trimmed });
        try filter.object.put(allocator, "updatedAt", updated_cmp);
    }

    if (opts.created_since) |created_value| {
        const trimmed = std.mem.trim(u8, created_value, " \t");
        if (trimmed.len == 0) return error.InvalidCreatedSinceFilter;

        var created_cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
        try created_cmp.object.put(allocator, "gt", .{ .string = trimmed });
        try filter.object.put(allocator, "createdAt", created_cmp);
    }

    if (opts.project) |project_value| {
        const trimmed = std.mem.trim(u8, project_value, " \t");
        if (trimmed.len == 0) return error.InvalidProjectFilter;

        var id_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try id_obj.object.put(allocator, "eq", .{ .string = trimmed });

        var project_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try project_obj.object.put(allocator, "id", id_obj);
        try filter.object.put(allocator, "project", project_obj);
    }

    if (opts.milestone) |milestone_value| {
        const trimmed = std.mem.trim(u8, milestone_value, " \t");
        if (trimmed.len == 0) return error.InvalidMilestoneFilter;

        var id_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try id_obj.object.put(allocator, "eq", .{ .string = trimmed });

        var milestone_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try milestone_obj.object.put(allocator, "id", id_obj);
        try filter.object.put(allocator, "milestone", milestone_obj);
    }

    try vars.object.put(allocator, "filter", filter);
    if (cursor) |cursor_value| try vars.object.put(allocator, "after", .{ .string = cursor_value });
    if (opts.sort) |sort| {
        const field_name = sort.field.graphqlName();
        const order_value = switch (sort.direction) {
            .asc => "Ascending",
            .desc => "Descending",
        };

        var sort_details = std.json.Value{ .object = std.json.ObjectMap.empty };
        try sort_details.object.put(allocator, "order", .{ .string = order_value });

        var sort_entry = std.json.Value{ .object = std.json.ObjectMap.empty };
        try sort_entry.object.put(allocator, field_name, sort_details);

        var sort_array = std.json.Array.init(allocator);
        try sort_array.append(sort_entry);

        // Only `sort` is sent. Linear rejects a request carrying both with
        // "Cannot use both sort and orderBy options", and `sort` is strictly
        // richer -- IssueSortInput carries the direction, PaginationOrderBy
        // carries only the field. Leaving $orderBy unset lets the server apply
        // its default.
        try vars.object.put(allocator, "sort", .{ .array = sort_array });
    }
    return vars;
}

fn parseCsvValues(allocator: Allocator, raw: []const u8) !std.json.Array {
    var values = std.json.Array.init(allocator);
    var iter = std.mem.tokenizeScalar(u8, raw, ',');
    var added: usize = 0;
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;
        try values.append(.{ .string = trimmed });
        added += 1;
    }
    if (added == 0) return error.EmptyList;
    return values;
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (value[idx] != '-') return false;
    }
    return true;
}

/// Maps user-friendly state type aliases to Linear API values.
/// Linear API expects: triage, backlog, unstarted, started, completed, canceled
pub fn normalizeStateType(value: []const u8) []const u8 {
    // Map common aliases to API values
    if (std.ascii.eqlIgnoreCase(value, "in_progress") or
        std.ascii.eqlIgnoreCase(value, "in-progress") or
        std.ascii.eqlIgnoreCase(value, "inprogress"))
    {
        return "started";
    }
    if (std.ascii.eqlIgnoreCase(value, "todo")) {
        return "unstarted";
    }
    // Pass through canonical values unchanged
    return value;
}

fn parseStateTypeCsvValues(allocator: Allocator, raw: []const u8) !std.json.Array {
    var values = std.json.Array.init(allocator);
    var iter = std.mem.tokenizeScalar(u8, raw, ',');
    var added: usize = 0;
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;
        const normalized = normalizeStateType(trimmed);
        try values.append(.{ .string = normalized });
        added += 1;
    }
    if (added == 0) return error.EmptyList;
    return values;
}

pub fn parseOptions(args: []const []const u8) !Options {
    var opts = Options{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--team")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.team = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--team=")) {
            opts.team = arg["--team=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--state") or std.mem.eql(u8, arg, "--state-type")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.state_type = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--state=")) {
            opts.state_type = arg["--state=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--state-type=")) {
            opts.state_type = arg["--state-type=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--state-id")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.state_id = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--state-id=")) {
            opts.state_id = arg["--state-id=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--assignee")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.assignee = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--assignee=")) {
            opts.assignee = arg["--assignee=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--label")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.label = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--label=")) {
            opts.label = arg["--label=".len..];
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
        if (std.mem.eql(u8, arg, "--milestone")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.milestone = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--milestone=")) {
            opts.milestone = arg["--milestone=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--updated-since")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.updated_since = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--updated-since=")) {
            opts.updated_since = arg["--updated-since=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--created-since")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.created_since = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--created-since=")) {
            opts.created_since = arg["--created-since=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sort")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.sort = try parseSort(args[idx + 1]);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sort=")) {
            opts.sort = try parseSort(arg["--sort=".len..]);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.limit = try std.fmt.parseInt(usize, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--limit=")) {
            opts.limit = try std.fmt.parseInt(usize, arg["--limit=".len..], 10);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-items")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.max_items = try std.fmt.parseInt(usize, args[idx + 1], 10);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--max-items=")) {
            opts.max_items = try std.fmt.parseInt(usize, arg["--max-items=".len..], 10);
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sub-limit")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.sub_limit = try std.fmt.parseInt(usize, args[idx + 1], 10);
            opts.sub_limit_explicit = true;
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sub-limit=")) {
            opts.sub_limit = try std.fmt.parseInt(usize, arg["--sub-limit=".len..], 10);
            opts.sub_limit_explicit = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cursor")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.cursor = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cursor=")) {
            opts.cursor = arg["--cursor=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--pages")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            const value = try std.fmt.parseInt(usize, args[idx + 1], 10);
            if (value == 0) return error.InvalidPageCount;
            opts.pages = value;
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--pages=")) {
            const value = try std.fmt.parseInt(usize, arg["--pages=".len..], 10);
            if (value == 0) return error.InvalidPageCount;
            opts.pages = value;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
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
        if (std.mem.eql(u8, arg, "--include-projects")) {
            opts.include_projects = true;
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
        if (std.mem.eql(u8, arg, "--human-time")) {
            opts.human_time = true;
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
    if (opts.limit == 0) return error.InvalidLimit;
    if (opts.all and opts.pages != null) return error.ConflictingPageFlags;
    return opts;
}

fn printSortVocabulary(writer: anytype) !void {
    try writer.print("issues list: valid --sort fields: {s}\n", .{sort_field_list});
    try writer.print(
        "issues list: aliases created -> createdAt, updated -> updatedAt; optional :asc|:desc suffix (default: desc)\n",
        .{},
    );
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issues list [--team ID|KEY] [--state-type TYPES] [--state-id IDS] [--assignee USER_ID] [--label IDS] [--project ID] [--milestone ID] [--updated-since TS] [--created-since TS] [--sort FIELD[:asc|desc]] [--limit N] [--max-items N] [--sub-limit N] [--cursor CURSOR] [--pages N|--all] [--fields LIST] [--include-projects] [--plain] [--no-truncate] [--human-time] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --team ID|KEY         Team id or key (default: config.default_team_id)
        \\  --state-type VALUES   Comma-separated state types: triage,backlog,unstarted,started,completed,canceled
        \\                        (aliases: in_progress/in-progress -> started, todo -> unstarted)
        \\                        (alias: --state; default: exclude completed,canceled)
        \\  --state-id IDS        Comma-separated workflow state ids to include (overrides default exclusion)
        \\  --assignee USER_ID    Filter by assignee id
        \\  --label IDS           Comma-separated label ids to include
        \\  --project ID          Filter by project id
        \\  --milestone ID        Filter by milestone id
        \\  --updated-since TS    Only include issues updated after the timestamp
        \\  --created-since TS    Only include issues created after the timestamp
        \\  --sort FIELD[:DIR]    Sort by an IssueSortInput field (dir asc|desc, default: desc)
        \\                        Fields: {s}
        \\                        Aliases: created -> createdAt, updated -> updatedAt
        \\  --limit N             Page size per request (default: 25)
        \\  --max-items N         Stop after emitting N issues (may truncate within a page)
        \\  --sub-limit N         Sub-issues to fetch per parent; also opts into fetching them
        \\                        (0 disables; default: 10, only used with --fields sub_issues)
        \\  --cursor CURSOR       Start pagination after the provided cursor
        \\  --pages N             Fetch up to N pages (default: 1)
        \\  --all                 Fetch all pages until the end
        \\  --fields LIST         Comma-separated columns (identifier,title,state,assignee,priority,updated,parent,sub_issues,project,milestone)
        \\  --include-projects    Add project and milestone columns (also available via --fields)
        \\  --plain               Do not pad or truncate table cells
        \\  --no-truncate         Disable ellipsis and padding in table cells
        \\  --human-time          Render timestamps as relative values
        \\  --quiet               Print only identifiers (one per line)
        \\  --data-only           Emit tab-separated rows (or JSON array with --json)
        \\  --help                Show this help message
        \\Examples:
        \\  linear issues list --team ENG --pages 2 --limit 50 --sort updated:desc
        \\  linear issues list --team ENG --sort priority:asc --state-type started
        \\  linear issues list --state-type todo,in_progress --label lbl-1,lbl-2 --assignee user-123
        \\
    , .{sort_field_help});
}

fn parseSort(raw: []const u8) !Sort {
    var parts = std.mem.splitScalar(u8, raw, ':');
    const field_raw = parts.next() orelse return error.InvalidSort;
    const field_name = std.mem.trim(u8, field_raw, " \t");
    if (field_name.len == 0) return error.InvalidSort;

    const field = parseSortField(field_name) orelse return error.InvalidSort;

    var direction: SortDirection = .desc;
    if (parts.next()) |dir_raw| {
        const dir_value = std.mem.trim(u8, dir_raw, " \t");
        if (dir_value.len == 0) return error.InvalidSort;
        if (std.ascii.eqlIgnoreCase(dir_value, "asc")) {
            direction = .asc;
        } else if (std.ascii.eqlIgnoreCase(dir_value, "desc")) {
            direction = .desc;
        } else {
            return error.InvalidSort;
        }
        if (parts.next()) |_| return error.InvalidSort;
    }

    return .{
        .field = field,
        .direction = direction,
    };
}

/// Resolves a user-supplied `--sort` field name. The vocabulary is the schema's
/// own, matched case-insensitively, plus the two short aliases the flag was
/// first documented with. Unknown names are rejected here rather than by the
/// API, so a typo costs no request.
fn parseSortField(name: []const u8) ?SortField {
    for (std.enums.values(SortField)) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate.graphqlName())) return candidate;
    }
    if (std.ascii.eqlIgnoreCase(name, "created")) return .created;
    if (std.ascii.eqlIgnoreCase(name, "updated")) return .updated;
    return null;
}

fn parseIssueFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(printer.IssueField), allocator: Allocator) ![]const printer.IssueField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseIssueFieldName(trimmed) orelse return error.InvalidField;
            if (!containsIssueField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    try buffer.appendSlice(allocator, printer.issue_default_fields[0..]);
    return buffer.items;
}

fn parseIssueFieldName(name: []const u8) ?printer.IssueField {
    if (std.ascii.eqlIgnoreCase(name, "identifier") or std.ascii.eqlIgnoreCase(name, "id")) return .identifier;
    if (std.ascii.eqlIgnoreCase(name, "title")) return .title;
    if (std.ascii.eqlIgnoreCase(name, "state")) return .state;
    if (std.ascii.eqlIgnoreCase(name, "assignee")) return .assignee;
    if (std.ascii.eqlIgnoreCase(name, "priority")) return .priority;
    if (std.ascii.eqlIgnoreCase(name, "parent")) return .parent;
    if (std.ascii.eqlIgnoreCase(name, "sub_issues") or std.ascii.eqlIgnoreCase(name, "subIssues")) return .sub_issues;
    if (std.ascii.eqlIgnoreCase(name, "project")) return .project;
    if (std.ascii.eqlIgnoreCase(name, "milestone")) return .milestone;
    if (std.ascii.eqlIgnoreCase(name, "updated") or std.ascii.eqlIgnoreCase(name, "updatedAt")) return .updated;
    return null;
}

fn containsIssueField(haystack: []const printer.IssueField, needle: printer.IssueField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}
