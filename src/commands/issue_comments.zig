//! Read/modify half of `linear issue comment`: `list`, `update`, and `delete`.
//!
//! Creating a comment lives in `issue_comment.zig`; these three share the
//! comment field projection and the same `Comment` id handling, so they are
//! kept together the way `project_issues.zig` keeps add/remove together.
const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");
const git = @import("git");

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
    /// `null` disables branch inference for a missing issue identifier on
    /// `list`, and with it every subprocess this command could start.
    /// `main.zig` installs `git.system_runner`; tests inject a fake.
    git_runner: ?git.Runner = null,
};

const Mode = enum { list, update, delete };

pub const ListOptions = struct {
    identifier: ?[]const u8 = null,
    /// Page size per request, not a total; `--max-items` caps the total.
    limit: usize = 50,
    max_items: ?usize = null,
    cursor: ?[]const u8 = null,
    pages: ?usize = null,
    all: bool = false,
    fields: ?[]const u8 = null,
    plain: bool = false,
    no_truncate: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

pub const UpdateOptions = struct {
    comment_id: ?[]const u8 = null,
    body: ?[]const u8 = null,
    body_file: ?[]const u8 = null,
    yes: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

pub const DeleteOptions = struct {
    comment_id: ?[]const u8 = null,
    yes: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

/// Row projection for one comment. `body` stays verbatim for JSON output while
/// `body_display` is folded to a single line for the table and the
/// tab-separated `--data-only` form, where a raw newline or tab would corrupt
/// the record.
const CommentData = struct {
    id: []const u8,
    author: []const u8,
    body: []const u8,
    body_display: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    parent: []const u8,
    url: []const u8,
};

/// Reports whether `name` selects one of the read/modify subcommands. Anything
/// else is an issue identifier for the comment-create path.
pub fn isSubcommand(name: []const u8) bool {
    return parseMode(name) != null;
}

fn parseMode(name: []const u8) ?Mode {
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "update")) return .update;
    if (std.mem.eql(u8, name, "delete")) return .delete;
    return null;
}

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;

    if (ctx.args.len == 0) {
        try stderr.print("issue comment: expected 'list', 'update', or 'delete'\n", .{});
        return 1;
    }

    const mode = parseMode(ctx.args[0]) orelse {
        try stderr.print("issue comment: unknown command: {s}\n", .{ctx.args[0]});
        return 1;
    };
    const rest = ctx.args[1..];

    return switch (mode) {
        .list => runList(ctx, rest),
        .update => runUpdate(ctx, rest),
        .delete => runDelete(ctx, rest),
    };
}

fn runList(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseListOptions(args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --limit value",
            error.InvalidPageCount => "invalid --pages value",
            else => @errorName(err),
        };
        try stderr.print("issue comment list: {s}\n", .{message});
        try listUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try listUsage(&out_writer.interface);
        return 0;
    }

    var inferred: ?[]u8 = null;
    defer if (inferred) |value| ctx.allocator.free(value);
    const target = opts.identifier orelse blk: {
        const runner = ctx.git_runner orelse {
            try stderr.print("issue comment list: missing issue identifier\n", .{});
            return 1;
        };
        inferred = git.requireInferredIdentifier(runner, ctx.allocator, ctx.io, stderr, "issue comment list") catch {
            return 1;
        };
        break :blk inferred.?;
    };

    if (opts.limit == 0) {
        try stderr.print("issue comment list: --limit must be greater than zero\n", .{});
        return 1;
    }
    if (opts.max_items) |max_value| {
        if (max_value == 0) {
            try stderr.print("issue comment list: invalid --max-items value\n", .{});
            return 1;
        }
    }

    var field_buf = std.ArrayListUnmanaged(printer.CommentField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseCommentFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("issue comment list: {s}\n", .{message});
        return 1;
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue comment list") catch {
        return 1;
    };

    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    const limit_i64 = std.math.cast(i64, opts.limit) orelse return error.InvalidLimit;
    // `id` and `first` are identical on every page; only `after` is rewritten.
    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = target });
    try variables.object.put(var_alloc, "first", .{ .integer = limit_i64 });

    // `Issue.comments` is a nested connection, so `after` threads into the inner
    // field and the cursor state comes back at `data.issue.comments.pageInfo`
    // rather than at the top level like every other list command.
    const query =
        \\query IssueComments($id: String!, $first: Int!, $after: String) {
        \\  issue(id: $id) {
        \\    id
        \\    identifier
        \\    comments(first: $first, after: $after) {
        \\      nodes { id body createdAt updatedAt url user { name } parent { id } }
        \\      pageInfo { hasNextPage endCursor }
        \\    }
        \\  }
        \\}
    ;

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const want_raw_nodes = ctx.json_output and !opts.data_only and !opts.quiet;

    // Row fields are slices borrowed from each page's parsed body, so no page
    // may be freed until every row has been printed; the whole `Response` is
    // kept and released together at the end.
    var responses = std.ArrayListUnmanaged(graphql.GraphqlClient.Response).empty;
    defer {
        for (responses.items) |*resp| resp.deinit();
        responses.deinit(ctx.allocator);
    }

    var rows = std.ArrayListUnmanaged(CommentData).empty;
    defer rows.deinit(ctx.allocator);
    var nodes_accumulator = std.ArrayListUnmanaged(std.json.Value).empty;
    defer nodes_accumulator.deinit(ctx.allocator);

    // Identity of the issue the comments hang off, taken from the first page so
    // the `--json` envelope keeps the shape the API returned.
    var issue_id: ?[]const u8 = null;
    var issue_identifier: ?[]const u8 = null;

    var progress = common.PageProgress{};
    const page_size = opts.limit;
    var next_cursor = opts.cursor;
    const page_limit: ?usize = if (opts.all) null else opts.pages orelse 1;

    while (true) {
        if (page_limit) |limit_pages| {
            if (progress.pages >= limit_pages) break;
        }

        if (next_cursor) |cursor_value| {
            try variables.object.put(var_alloc, "after", .{ .string = cursor_value });
        }

        var response = common.send(ctx.allocator, "issue comment list", &client, .{
            .query = query,
            .variables = variables,
            .operation_name = "IssueComments",
        }, stderr) catch {
            return 1;
        };
        var response_owned = true;
        errdefer if (response_owned) response.deinit();

        // `errdefer` does not fire on `return 1` — that is a successful return
        // of an exit code — so a rejected page is freed by hand here.
        common.checkResponse(ctx.io, "issue comment list", &response, stderr, api_key) catch {
            if (response_owned) response.deinit();
            return 1;
        };

        try responses.append(ctx.allocator, response);
        response_owned = false;
        const resp = &responses.items[responses.items.len - 1];

        const data_value = resp.data() orelse {
            try stderr.print("issue comment list: response missing data\n", .{});
            return 1;
        };

        // A null or absent `issue` is a real outcome (bad identifier, revoked
        // access mid-walk), not something to index into.
        const issue_obj = common.getObjectField(data_value, "issue") orelse {
            try stderr.print("issue comment list: issue '{s}' not found\n", .{target});
            return 1;
        };
        const comments_obj = common.getObjectField(issue_obj, "comments") orelse {
            try stderr.print("issue comment list: comments missing in response\n", .{});
            return 1;
        };
        const nodes_array = common.getArrayField(comments_obj, "nodes") orelse {
            try stderr.print("issue comment list: nodes missing in response\n", .{});
            return 1;
        };

        if (issue_id == null) issue_id = common.getStringField(issue_obj, "id");
        if (issue_identifier == null) issue_identifier = common.getStringField(issue_obj, "identifier");

        if (opts.max_items) |max_value| {
            if (progress.items >= max_value) {
                progress.max_items_reached = true;
                break;
            }
        }

        const take_count = @min(nodes_array.items.len, page_size);
        const remaining_allowed = if (opts.max_items) |max_value| max_value - progress.items else take_count;
        const allowed_count = @min(take_count, remaining_allowed);
        const page_nodes = nodes_array.items[0..allowed_count];

        progress.items += allowed_count;
        if (opts.max_items) |max_value| {
            if (progress.items >= max_value) progress.max_items_reached = true;
        }
        progress.pages += 1;

        if (want_raw_nodes) {
            for (page_nodes) |node| try nodes_accumulator.append(ctx.allocator, node);
        } else {
            for (page_nodes) |node| {
                if (node != .object) continue;
                const id = common.getStringField(node, "id") orelse continue;
                const body = common.getStringField(node, "body") orelse "";
                const user_obj = common.getObjectField(node, "user");
                const author = if (user_obj) |u| common.getStringField(u, "name") orelse "(unknown)" else "(unknown)";
                const parent_obj = common.getObjectField(node, "parent");
                const parent = if (parent_obj) |p| common.getStringField(p, "id") orelse "" else "";
                try rows.append(ctx.allocator, .{
                    .id = id,
                    .author = author,
                    .body = body,
                    .body_display = try foldToSingleLine(var_alloc, body),
                    .created_at = common.getStringField(node, "createdAt") orelse "",
                    .updated_at = common.getStringField(node, "updatedAt") orelse "",
                    .parent = parent,
                    .url = common.getStringField(node, "url") orelse "",
                });
            }
        }

        // The nested connection's own `pageInfo`, not the response root's.
        const page_info = common.getObjectField(comments_obj, "pageInfo");
        const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
        progress.end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;
        progress.more_available = has_next;

        if (allowed_count < take_count and opts.max_items != null) {
            progress.max_items_reached = true;
        }

        if (take_count == 0 or allowed_count == 0) {
            if (has_next) {
                try stderr.print("issue comment list: received empty page; stopping pagination\n", .{});
            }
            break;
        }

        if (!has_next) break;
        if (page_limit) |limit_pages| {
            if (progress.pages >= limit_pages) break;
        }
        if (progress.max_items_reached) {
            progress.more_available = true;
            break;
        }
        if (progress.end_cursor == null) {
            try stderr.print("issue comment list: missing endCursor for additional page\n", .{});
            break;
        }
        next_cursor = progress.end_cursor;
    }

    if (progress.max_items_reached) progress.more_available = true;

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (want_raw_nodes) {
        var nodes_value = std.json.Value{ .array = std.json.Array.init(var_alloc) };
        try nodes_value.array.appendSlice(nodes_accumulator.items);

        var comments_out = std.json.Value{ .object = std.json.ObjectMap.empty };
        try comments_out.object.put(var_alloc, "nodes", nodes_value);
        try comments_out.object.put(var_alloc, "pageInfo", try pageInfoValue(var_alloc, progress));

        var issue_out = std.json.Value{ .object = std.json.ObjectMap.empty };
        if (issue_id) |value| try issue_out.object.put(var_alloc, "id", .{ .string = value });
        if (issue_identifier) |value| try issue_out.object.put(var_alloc, "identifier", .{ .string = value });
        try issue_out.object.put(var_alloc, "comments", comments_out);

        var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try root_obj.object.put(var_alloc, "issue", issue_out);
        try printer.printJson(root_obj, stdout_iface, true);

        try common.printPageSummary(stderr, "issue comment list", progress, ctx.json_output);
        return 0;
    }

    if (opts.quiet) {
        for (rows.items) |row| {
            try stdout_iface.writeAll(row.id);
            try stdout_iface.writeByte('\n');
        }
    } else if (opts.data_only) {
        if (ctx.json_output) {
            var out_array = std.json.Array.init(var_alloc);
            for (rows.items) |row| {
                var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
                for (selected_fields) |field| {
                    try obj.object.put(var_alloc, fieldKey(field), .{ .string = jsonValue(row, field) });
                }
                try out_array.append(obj);
            }
            var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try root_obj.object.put(var_alloc, "nodes", .{ .array = out_array });
            try root_obj.object.put(var_alloc, "pageInfo", try pageInfoValue(var_alloc, progress));
            try root_obj.object.put(var_alloc, "limit", .{ .integer = limit_i64 });
            try printer.printJson(root_obj, stdout_iface, true);
        } else {
            for (rows.items) |row| {
                var first = true;
                for (selected_fields) |field| {
                    if (!first) try stdout_iface.writeByte('\t') else first = false;
                    try stdout_iface.writeAll(cellValue(row, field));
                }
                try stdout_iface.writeByte('\n');
            }
        }
    } else {
        var table_rows = std.ArrayListUnmanaged(printer.CommentRow).empty;
        defer table_rows.deinit(ctx.allocator);
        for (rows.items) |row| {
            try table_rows.append(ctx.allocator, .{
                .id = row.id,
                .author = row.author,
                .body = row.body_display,
                .created_at = row.created_at,
                .updated_at = row.updated_at,
                .parent = row.parent,
                .url = row.url,
            });
        }
        try printer.printCommentTable(ctx.allocator, stdout_iface, table_rows.items, selected_fields, table_opts);
    }

    try common.printPageSummary(stderr, "issue comment list", progress, ctx.json_output);
    return 0;
}

/// Renders the walk's final cursor state in the same `pageInfo` shape the API
/// uses, so a `--json` consumer can resume with `--cursor` unchanged.
fn pageInfoValue(allocator: Allocator, progress: common.PageProgress) !std.json.Value {
    var page_info = std.json.Value{ .object = std.json.ObjectMap.empty };
    try page_info.object.put(allocator, "hasNextPage", .{ .bool = progress.more_available });
    if (progress.end_cursor) |cursor_value| {
        try page_info.object.put(allocator, "endCursor", .{ .string = cursor_value });
    }
    return page_info;
}

fn runUpdate(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseUpdateOptions(args) catch |err| {
        try stderr.print("issue comment update: {s}\n", .{@errorName(err)});
        try updateUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try updateUsage(&out_writer.interface);
        return 0;
    }

    const comment_id = opts.comment_id orelse {
        try stderr.print("issue comment update: missing comment id\n", .{});
        return 1;
    };

    if (opts.body == null and opts.body_file == null) {
        try stderr.print("issue comment update: --body or --body-file is required\n", .{});
        return 1;
    }

    const body_source = common.resolveContent(
        ctx.allocator,
        ctx.io,
        opts.body,
        opts.body_file,
        stderr,
        "issue comment update",
        "--body",
    ) catch {
        return 1;
    };
    defer body_source.deinit(ctx.allocator);
    const body_content = body_source.value orelse "";

    if (body_content.len == 0) {
        try stderr.print("issue comment update: comment body cannot be empty\n", .{});
        return 1;
    }

    if (!opts.yes) {
        try stderr.print("issue comment update: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue comment update") catch {
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

    var input = std.json.Value{ .object = std.json.ObjectMap.empty };
    try input.object.put(var_alloc, "body", .{ .string = body_content });

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = comment_id });
    try variables.object.put(var_alloc, "input", input);

    const mutation =
        \\mutation CommentUpdate($id: String!, $input: CommentUpdateInput!) {
        \\  commentUpdate(id: $id, input: $input) {
        \\    success
        \\    comment {
        \\      id
        \\      body
        \\      url
        \\      updatedAt
        \\      issue { identifier }
        \\    }
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue comment update", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "CommentUpdate",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue comment update", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue comment update: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "commentUpdate") orelse {
        try stderr.print("issue comment update: commentUpdate missing in response\n", .{});
        return 1;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    const comment_obj = common.getObjectField(payload, "comment");
    if (!success) {
        try reportUserError(payload, stderr, "issue comment update");
        return 1;
    }

    const comment = comment_obj orelse {
        try stderr.print("issue comment update: comment missing in response\n", .{});
        return 1;
    };

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const resolved_id = common.getStringField(comment, "id") orelse comment_id;
    const url = common.getStringField(comment, "url") orelse "";
    const updated_at = common.getStringField(comment, "updatedAt") orelse "";
    const issue_obj = common.getObjectField(comment, "issue");
    const identifier = if (issue_obj) |iss| common.getStringField(iss, "identifier") orelse "" else "";

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(resolved_id);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    const pairs = [_]printer.KeyValue{
        .{ .key = "Comment", .value = resolved_id },
        .{ .key = "Issue", .value = identifier },
        .{ .key = "Updated", .value = updated_at },
        .{ .key = "URL", .value = url },
    };
    const data_pairs = [_]printer.KeyValue{
        .{ .key = "comment", .value = resolved_id },
        .{ .key = "issue", .value = identifier },
        .{ .key = "updated_at", .value = updated_at },
        .{ .key = "url", .value = url },
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

    try printer.printKeyValues(stdout_iface, pairs[0..]);
    return 0;
}

fn runDelete(ctx: Context, args: [][]const u8) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseDeleteOptions(args) catch |err| {
        try stderr.print("issue comment delete: {s}\n", .{@errorName(err)});
        try deleteUsage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try deleteUsage(&out_writer.interface);
        return 0;
    }

    const comment_id = opts.comment_id orelse {
        try stderr.print("issue comment delete: missing comment id\n", .{});
        return 1;
    };

    if (!opts.yes) {
        try stderr.print("issue comment delete: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue comment delete") catch {
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
    try variables.object.put(var_alloc, "id", .{ .string = comment_id });

    const mutation =
        \\mutation CommentDelete($id: String!) {
        \\  commentDelete(id: $id) { success }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue comment delete", &client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "CommentDelete",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue comment delete", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue comment delete: response missing data\n", .{});
        return 1;
    };

    const payload = common.getObjectField(data_value, "commentDelete") orelse {
        try stderr.print("issue comment delete: commentDelete missing in response\n", .{});
        return 1;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    if (!success) {
        try reportUserError(payload, stderr, "issue comment delete");
        return 1;
    }

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        try stdout_iface.writeAll(comment_id);
        try stdout_iface.writeByte('\n');
        return 0;
    }

    const data_pairs = [_]printer.KeyValue{
        .{ .key = "comment", .value = comment_id },
        .{ .key = "deleted", .value = "true" },
    };

    if (opts.data_only) {
        if (ctx.json_output) {
            var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try data_obj.object.put(var_alloc, "comment", .{ .string = comment_id });
            try data_obj.object.put(var_alloc, "deleted", .{ .bool = true });
            try printer.printJson(data_obj, stdout_iface, true);
            return 0;
        }

        try printer.printKeyValuesPlain(stdout_iface, data_pairs[0..]);
        return 0;
    }

    try stdout_iface.print("issue comment delete: deleted {s}\n", .{comment_id});
    return 0;
}

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

/// Comment bodies are multi-line markdown; table cells and tab-separated rows
/// are single-line records, so control whitespace is folded to spaces there.
/// JSON output keeps the body verbatim.
fn foldToSingleLine(allocator: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, value, "\r\n\t") == null) return value;
    const copy = try allocator.dupe(u8, value);
    for (copy) |*ch| {
        switch (ch.*) {
            '\r', '\n', '\t' => ch.* = ' ',
            else => {},
        }
    }
    return copy;
}

fn fieldKey(field: printer.CommentField) []const u8 {
    return switch (field) {
        .id => "id",
        .author => "author",
        .body => "body",
        .created_at => "created_at",
        .updated_at => "updated_at",
        .parent => "parent",
        .url => "url",
    };
}

fn cellValue(row: CommentData, field: printer.CommentField) []const u8 {
    return switch (field) {
        .id => row.id,
        .author => row.author,
        .body => row.body_display,
        .created_at => row.created_at,
        .updated_at => row.updated_at,
        .parent => row.parent,
        .url => row.url,
    };
}

fn jsonValue(row: CommentData, field: printer.CommentField) []const u8 {
    return switch (field) {
        .body => row.body,
        else => cellValue(row, field),
    };
}

fn parseCommentFields(
    raw: ?[]const u8,
    buffer: *std.ArrayListUnmanaged(printer.CommentField),
    allocator: Allocator,
) ![]const printer.CommentField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseCommentFieldName(trimmed) orelse return error.InvalidField;
            if (!containsCommentField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.comment_default_fields[0..];
}

fn parseCommentFieldName(name: []const u8) ?printer.CommentField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "author")) return .author;
    if (std.ascii.eqlIgnoreCase(name, "body")) return .body;
    if (std.ascii.eqlIgnoreCase(name, "created_at")) return .created_at;
    if (std.ascii.eqlIgnoreCase(name, "updated_at")) return .updated_at;
    if (std.ascii.eqlIgnoreCase(name, "parent")) return .parent;
    if (std.ascii.eqlIgnoreCase(name, "url")) return .url;
    return null;
}

fn containsCommentField(haystack: []const printer.CommentField, needle: printer.CommentField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}

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
        if (opts.identifier == null) {
            opts.identifier = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    if (opts.all and opts.pages != null) return error.ConflictingPageFlags;
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
        if (std.mem.eql(u8, arg, "--body")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.body = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--body=")) {
            opts.body = arg["--body=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--body-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.body_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--body-file=")) {
            opts.body_file = arg["--body-file=".len..];
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
        if (opts.comment_id == null) {
            opts.comment_id = arg;
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
        if (opts.comment_id == null) {
            opts.comment_id = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn listUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue comment list [ID|IDENTIFIER] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--fields LIST] [--plain] [--no-truncate] [--quiet] [--data-only] [--help]
        \\Without an identifier the issue is inferred from the current branch name.
        \\Flags:
        \\  --limit N        Page size per request (default: 50)
        \\  --max-items N    Stop after emitting N comments (may truncate within a page)
        \\  --cursor CURSOR  Start pagination after the provided cursor
        \\  --pages N        Fetch up to N pages (default: 1)
        \\  --all            Fetch all pages until the end
        \\  --fields LIST    Comma-separated columns (id,author,body,created_at,updated_at,parent,url)
        \\  --plain          Do not pad or truncate table cells
        \\  --no-truncate    Disable ellipsis and padding in table cells
        \\  --quiet          Print only comment ids (one per line)
        \\  --data-only      Emit tab-separated rows (or JSON array with --json)
        \\  --help           Show this help message
        \\Notes:
        \\  Table and tab-separated output fold newlines and tabs inside a comment
        \\  body to spaces; use --json to get bodies back verbatim.
        \\Examples:
        \\  linear issue comment list ENG-123
        \\  linear issue comment list ENG-123 --fields id,parent --data-only
        \\  linear issue comment list ENG-123 --json
        \\  linear issue comment list ENG-123 --all --quiet
        \\
    , .{});
}

pub fn updateUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue comment update <COMMENT_ID> --body TEXT [--yes] [--quiet] [--data-only] [--help]
        \\       linear issue comment update <COMMENT_ID> --body-file PATH [--yes] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --body TEXT        Replacement comment body
        \\  --body-file PATH   Read the replacement body from a file (use '-' for stdin)
        \\  --yes              Skip confirmation prompt (alias: --force)
        \\  --quiet            Print only the comment id
        \\  --data-only        Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help             Show this help message
        \\Examples:
        \\  linear issue comment update comment-1 --body "Corrected text" --yes
        \\  linear issue comment update comment-1 --body-file body.md --yes
        \\
    , .{});
}

pub fn deleteUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue comment delete <COMMENT_ID> --yes [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --yes         Skip confirmation prompt (alias: --force)
        \\  --quiet       Print only the comment id
        \\  --data-only   Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --help        Show this help message
        \\Examples:
        \\  linear issue comment delete comment-1 --yes
        \\
    , .{});
}
