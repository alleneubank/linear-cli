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

const Options = struct {
    query: ?[]const u8 = null,
    team: ?[]const u8 = null,
    /// Which fields to *search* (`--search-fields`): the haystack, not the
    /// output. Was spelled `--fields` until that name was handed to the print
    /// projection below.
    search_fields: ?[]const u8 = null,
    /// Which columns to *print* (`--fields`), same meaning as on every other
    /// list command.
    fields: ?[]const u8 = null,
    state_type: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    /// Page size per request, not a total; `--max-items` caps the total.
    limit: usize = 25,
    max_items: ?usize = null,
    cursor: ?[]const u8 = null,
    pages: ?usize = null,
    all: bool = false,
    case_sensitive: bool = false,
    plain: bool = false,
    no_truncate: bool = false,
    quiet: bool = false,
    data_only: bool = false,
    help: bool = false,
};

/// The `--search-fields` vocabulary: which parts of an issue the query text is
/// matched against. Disjoint from the print vocabulary below except for
/// `title`, which is the only name both flags accept.
const SearchField = enum { title, description, comments };
const default_search_fields = [_]SearchField{ .title, .description };

/// Columns `search` can print, and therefore the entire `--fields` vocabulary
/// here. It is exactly `printer.issue_default_fields` because the `SearchIssues`
/// selection set fetches exactly those six: `parent`, `sub_issues`, `project`
/// and `milestone` are real `issues list` columns with nothing behind them on a
/// search response, so they are rejected rather than printed as empty cells.
const available_print_fields = printer.issue_default_fields;

/// Canonical `--search-fields` values, comma-joined for the diagnostics.
/// Derived from `SearchField` for the same reason `issues list` derives its
/// `--sort` vocabulary from `SortField`: the message cannot drift from what the
/// parser accepts.
const search_field_list: []const u8 = joinFieldNames(SearchField, std.enums.values(SearchField));

/// The subset of those that `--search-fields` accepts by default.
const default_search_field_list: []const u8 = joinFieldNames(SearchField, default_search_fields[0..]);

/// Canonical `--fields` values on `search`, derived from
/// `available_print_fields`.
const available_print_field_list: []const u8 = joinFieldNames(printer.IssueField, available_print_fields[0..]);

/// `--search-fields` values that are not print columns at all — the tokens a
/// `--fields` list can only have meant as search targets. Derived by asking
/// `printer.parseIssueField` about every `SearchField`, so a new search field
/// that is not also a column joins this list without anyone editing it.
const search_only_field_list: []const u8 = blk: {
    var out: []const u8 = "";
    for (std.enums.values(SearchField)) |field| {
        const name: []const u8 = @tagName(field);
        if (printer.parseIssueField(name) != null) continue;
        out = if (out.len == 0) name else out ++ ", " ++ name;
    }
    break :blk out;
};

fn joinFieldNames(comptime Field: type, comptime fields: []const Field) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (fields, 0..) |field, idx| {
            const name: []const u8 = @tagName(field);
            out = if (idx == 0) name else out ++ ", " ++ name;
        }
        return out;
    }
}

/// Row projection kept alive across the walk for `--quiet` and `--data-only`.
/// Every field is a slice borrowed from a page's parsed body, so no page may be
/// released until the last row has been written.
const DataRow = struct {
    identifier: []const u8,
    title: []const u8,
    state: []const u8,
    assignee: []const u8,
    priority: []const u8,
    updated: []const u8,
    url: []const u8,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --limit value",
            error.InvalidPageCount => "invalid --pages value",
            error.MissingValue => "missing value",
            error.UnknownFlag => "unknown flag",
            error.UnexpectedArgument => "unexpected argument",
            else => @errorName(err),
        };
        try stderr.print("search: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const raw_query = opts.query orelse {
        try stderr.print("search: missing query\n", .{});
        try usage(stderr);
        return 1;
    };
    const query_value = std.mem.trim(u8, raw_query, " \t");
    if (query_value.len == 0) {
        try stderr.print("search: missing query\n", .{});
        try usage(stderr);
        return 1;
    }

    if (opts.max_items) |max_value| {
        if (max_value == 0) {
            try stderr.print("search: invalid --max-items value\n", .{});
            return 1;
        }
    }

    // Both field lists are resolved before `requireApiKey`, like `common.resolveContent`
    // is: `--fields` and `--search-fields` now sit one keystroke apart, so a value sent
    // to the wrong one must be answerable without credentials and without a request.
    var search_fields_buf = std.ArrayListUnmanaged(SearchField).empty;
    defer search_fields_buf.deinit(ctx.allocator);
    var rejected_search_field: []const u8 = "";
    const selected_search_fields = parseSearchFields(
        opts.search_fields,
        &search_fields_buf,
        ctx.allocator,
        &rejected_search_field,
    ) catch |err| switch (err) {
        error.InvalidField => {
            try stderr.print("search: invalid --search-fields value '{s}'\n", .{rejected_search_field});
            try printSearchFieldVocabulary(stderr);
            return 1;
        },
        else => return err,
    };

    var print_fields_buf = std.ArrayListUnmanaged(printer.IssueField).empty;
    defer print_fields_buf.deinit(ctx.allocator);
    var rejected_print_field: []const u8 = "";
    const selected_print_fields = parsePrintFields(
        opts.fields,
        &print_fields_buf,
        ctx.allocator,
        &rejected_print_field,
    ) catch |err| switch (err) {
        // `description`/`comments` are search targets, not columns. Reporting
        // them as an unknown column would read like a typo when the real fault
        // is that the value belongs to the other flag.
        error.SearchOnlyField => {
            try stderr.print(
                "search: --fields selects printed columns; '{s}' names a search target -- use --search-fields {s}\n",
                .{ rejected_print_field, rejected_print_field },
            );
            try stderr.print(
                "search: search-only values: {s}; valid --fields values: {s}\n",
                .{ search_only_field_list, available_print_field_list },
            );
            return 1;
        },
        // A real `issues list` column that `search` never fetches. Say so, and
        // name the command that can produce it, rather than printing a column
        // of blanks that reads like "no issue has one".
        error.UnavailableField => {
            try stderr.print(
                "search: --fields '{s}' is not fetched by search -- use `issues list --fields {s}`\n",
                .{ rejected_print_field, rejected_print_field },
            );
            try printPrintFieldVocabulary(stderr);
            return 1;
        },
        error.InvalidField => {
            try stderr.print("search: invalid --fields value '{s}'\n", .{rejected_print_field});
            try printPrintFieldVocabulary(stderr);
            return 1;
        },
        else => return err,
    };

    // `title` is the only name both vocabularies accept, so a `--fields` list
    // made up entirely of search targets is exactly the shape a pre-split
    // invocation had. The run is legitimate as a projection and proceeds, but
    // the reinterpretation is called out once on stderr so a silently changed
    // meaning cannot pass unnoticed. Suppressed when `--search-fields` is also
    // present: that caller has already shown they know the difference.
    if (opts.search_fields == null) {
        if (opts.fields) |raw_fields| {
            if (allSearchTargets(selected_print_fields)) {
                try stderr.print(
                    "search: --fields {s} selects printed columns; pass --search-fields {s} to narrow what is searched (default: {s})\n",
                    .{ raw_fields, raw_fields, default_search_field_list },
                );
            }
        }
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "search") catch {
        return 1;
    };

    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var assignee_value = opts.assignee;
    if (opts.assignee) |assignee_raw| {
        const trimmed = std.mem.trim(u8, assignee_raw, " \t");
        if (trimmed.len == 0) {
            try stderr.print("search: invalid --assignee value\n", .{});
            return 1;
        }
        if (std.mem.eql(u8, trimmed, "me")) {
            assignee_value = resolveCurrentUserId(ctx, &client, var_alloc, stderr) catch |err| {
                try stderr.print("search: failed to resolve current user: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else {
            assignee_value = trimmed;
        }
    }

    const team_value = opts.team orelse ctx.config.default_team_id;
    // The filter is identical on every page, so it is built once; only `after`
    // is rewritten between requests.
    var variables = buildVariables(var_alloc, query_value, selected_search_fields, opts, ctx.config.default_state_filter, assignee_value, team_value) catch |err| {
        const message = switch (err) {
            error.InvalidStateFilter => "invalid --state-type value",
            else => @errorName(err),
        };
        try stderr.print("search: {s}\n", .{message});
        return 1;
    };

    const query =
        \\query SearchIssues($filter: IssueFilter!, $first: Int!, $after: String) {
        \\  issues(filter: $filter, first: $first, after: $after) {
        \\    nodes {
        \\      id
        \\      identifier
        \\      title
        \\      state { name type }
        \\      assignee { name }
        \\      priorityLabel
        \\      updatedAt
        \\      url
        \\    }
        \\    pageInfo {
        \\      hasNextPage
        \\      endCursor
        \\    }
        \\  }
        \\}
    ;

    const want_table = !ctx.json_output and !opts.data_only and !opts.quiet;
    const want_data_rows = opts.data_only or opts.quiet;
    const want_raw_nodes = ctx.json_output and !opts.data_only and !opts.quiet;

    // Row fields are slices borrowed from each page's parsed body, so no page
    // may be freed until every row has been printed; the whole `Response` is
    // kept and released together at the end.
    var responses = std.ArrayListUnmanaged(graphql.GraphqlClient.Response).empty;
    defer {
        for (responses.items) |*resp| resp.deinit();
        responses.deinit(ctx.allocator);
    }

    var rows = std.ArrayListUnmanaged(printer.IssueRow).empty;
    defer rows.deinit(ctx.allocator);
    var data_rows = std.ArrayListUnmanaged(DataRow).empty;
    defer data_rows.deinit(ctx.allocator);
    var nodes_accumulator = std.ArrayListUnmanaged(std.json.Value).empty;
    defer nodes_accumulator.deinit(ctx.allocator);

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

        var response = common.send(ctx.allocator, "search", &client, .{
            .query = query,
            .variables = variables,
            .operation_name = "SearchIssues",
        }, stderr) catch {
            return 1;
        };
        var response_owned = true;
        errdefer if (response_owned) response.deinit();

        // `errdefer` does not fire on `return 1` — that is a successful return
        // of an exit code — so a rejected page is freed by hand here.
        common.checkResponse(ctx.io, "search", &response, stderr, api_key) catch {
            if (response_owned) response.deinit();
            return 1;
        };

        try responses.append(ctx.allocator, response);
        response_owned = false;
        const resp = &responses.items[responses.items.len - 1];

        const data_value = resp.data() orelse {
            try stderr.print("search: response missing data\n", .{});
            return 1;
        };
        const issues_obj = common.getObjectField(data_value, "issues") orelse {
            try stderr.print("search: issues not found in response\n", .{});
            return 1;
        };
        const nodes_array = common.getArrayField(issues_obj, "nodes") orelse {
            try stderr.print("search: nodes missing in response\n", .{});
            return 1;
        };

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
                const assignee_display = assignee_name orelse "(unassigned)";
                const priority = common.getStringField(node, "priorityLabel") orelse "";
                const updated = common.getStringField(node, "updatedAt") orelse "";
                const url = common.getStringField(node, "url") orelse "";

                if (want_table) {
                    try rows.append(ctx.allocator, .{
                        .identifier = identifier,
                        .title = title,
                        .state = state_value,
                        .assignee = assignee_display,
                        .priority = priority,
                        .parent = "",
                        .sub_issues = "",
                        .project = "",
                        .milestone = "",
                        .updated = updated,
                    });
                }
                if (want_data_rows) {
                    try data_rows.append(ctx.allocator, .{
                        .identifier = identifier,
                        .title = title,
                        .state = state_value,
                        .assignee = assignee_display,
                        .priority = priority,
                        .updated = updated,
                        .url = url,
                    });
                }
            }
        }

        const page_info = common.getObjectField(issues_obj, "pageInfo");
        const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
        progress.end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;
        progress.more_available = has_next;

        if (allowed_count < take_count and opts.max_items != null) {
            progress.max_items_reached = true;
        }

        if (take_count == 0 or allowed_count == 0) {
            if (has_next) {
                try stderr.print("search: received empty page; stopping pagination\n", .{});
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
            try stderr.print("search: missing endCursor for additional page\n", .{});
            break;
        }
        next_cursor = progress.end_cursor;
    }

    if (progress.max_items_reached) progress.more_available = true;

    const trimmed_team = std.mem.trim(u8, team_value, " \t");
    if (progress.items == 0 and trimmed_team.len > 0) {
        try stderr.print("search: 0 results (team filter: {s})\n", .{trimmed_team});
    }

    const limit_i64 = std.math.cast(i64, page_size) orelse return error.InvalidLimit;

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    const stdout_iface = &out_writer.interface;

    if (opts.quiet) {
        for (data_rows.items) |row| {
            try stdout_iface.writeAll(row.identifier);
            try stdout_iface.writeByte('\n');
        }
    } else if (opts.data_only) {
        if (ctx.json_output) {
            // The JSON record is the whole row, not the `--fields` projection --
            // `issues list --data-only --json` behaves the same way, and a
            // consumer that wants fewer keys has `jq`.
            var out_array = std.json.Array.init(var_alloc);
            for (data_rows.items) |row| {
                var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
                try obj.object.put(var_alloc, "identifier", .{ .string = row.identifier });
                try obj.object.put(var_alloc, "title", .{ .string = row.title });
                try obj.object.put(var_alloc, "state", .{ .string = row.state });
                try obj.object.put(var_alloc, "assignee", .{ .string = row.assignee });
                try obj.object.put(var_alloc, "priority", .{ .string = row.priority });
                try obj.object.put(var_alloc, "updated_at", .{ .string = row.updated });
                try obj.object.put(var_alloc, "url", .{ .string = row.url });
                try out_array.append(obj);
            }
            var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try root_obj.object.put(var_alloc, "nodes", .{ .array = out_array });
            try root_obj.object.put(var_alloc, "pageInfo", try pageInfoValue(var_alloc, progress));
            try root_obj.object.put(var_alloc, "limit", .{ .integer = limit_i64 });
            try printer.printJson(root_obj, stdout_iface, true);
        } else {
            for (data_rows.items) |row| {
                var first = true;
                for (selected_print_fields) |field| {
                    if (!first) try stdout_iface.writeByte('\t') else first = false;
                    try stdout_iface.writeAll(cellValue(row, field));
                }
                if (!first) try stdout_iface.writeByte('\t');
                try stdout_iface.writeAll(row.url);
                try stdout_iface.writeByte('\n');
            }
        }
    } else if (want_raw_nodes) {
        var nodes_value = std.json.Value{ .array = std.json.Array.init(var_alloc) };
        try nodes_value.array.appendSlice(nodes_accumulator.items);

        var issues_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try issues_obj.object.put(var_alloc, "nodes", nodes_value);
        try issues_obj.object.put(var_alloc, "pageInfo", try pageInfoValue(var_alloc, progress));

        var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try root_obj.object.put(var_alloc, "issues", issues_obj);
        try printer.printJson(root_obj, stdout_iface, true);
    } else {
        try printer.printIssueTable(ctx.allocator, stdout_iface, rows.items, selected_print_fields, table_opts);
    }

    try common.printPageSummary(stderr, "search", progress, ctx.json_output);
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

/// The columns `search` never fetches are rejected by `parsePrintFields`, so
/// they cannot reach this function; they resolve to empty rather than
/// `unreachable` so a future selection-set change cannot turn a missed update
/// into undefined behaviour.
fn cellValue(row: DataRow, field: printer.IssueField) []const u8 {
    return switch (field) {
        .identifier => row.identifier,
        .title => row.title,
        .state => row.state,
        .assignee => row.assignee,
        .priority => row.priority,
        .updated => row.updated,
        .parent, .sub_issues, .project, .milestone => "",
    };
}

fn buildVariables(
    allocator: Allocator,
    query_value: []const u8,
    fields: []const SearchField,
    opts: Options,
    default_state_filter: []const []const u8,
    assignee: ?[]const u8,
    team_value: []const u8,
) !std.json.Value {
    if (opts.limit == 0) return error.InvalidLimit;
    const limit_i64 = std.math.cast(i64, opts.limit) orelse return error.InvalidLimit;

    var vars = std.json.Value{ .object = std.json.ObjectMap.empty };
    try vars.object.put(allocator, "first", .{ .integer = limit_i64 });

    var filter = std.json.Value{ .object = std.json.ObjectMap.empty };

    const comparator = if (opts.case_sensitive) "contains" else "containsIgnoreCase";
    var clauses = std.json.Array.init(allocator);
    for (fields) |field| {
        try appendClause(allocator, &clauses, field, comparator, query_value);
    }

    // If query looks like an identifier (e.g., "SEND-53"), also match by issue number
    if (parseIdentifierNumber(query_value)) |issue_number| {
        var num_cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
        try num_cmp.object.put(allocator, "eq", .{ .integer = issue_number });
        var num_entry = std.json.Value{ .object = std.json.ObjectMap.empty };
        try num_entry.object.put(allocator, "number", num_cmp);
        try clauses.append(num_entry);
    }

    if (clauses.items.len == 0) return error.InvalidField;
    try filter.object.put(allocator, "or", .{ .array = clauses });

    const trimmed_team = std.mem.trim(u8, team_value, " \t");
    if (trimmed_team.len > 0) {
        var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try eq_obj.object.put(allocator, "eq", .{ .string = trimmed_team });

        var team_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        if (isUuid(trimmed_team)) {
            try team_obj.object.put(allocator, "id", eq_obj);
        } else {
            try team_obj.object.put(allocator, "key", eq_obj);
        }
        try filter.object.put(allocator, "team", team_obj);
    }

    var state_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    if (opts.state_type) |state_raw| {
        const state_values = parseCsvValues(allocator, state_raw) catch |err| switch (err) {
            error.EmptyList => return error.InvalidStateFilter,
            else => return err,
        };
        var state_type_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try state_type_obj.object.put(allocator, "in", .{ .array = state_values });
        try state_obj.object.put(allocator, "type", state_type_obj);
    } else {
        var state_values = std.json.Array.init(allocator);
        for (default_state_filter) |entry| {
            try state_values.append(.{ .string = entry });
        }
        var state_type_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try state_type_obj.object.put(allocator, "nin", .{ .array = state_values });
        try state_obj.object.put(allocator, "type", state_type_obj);
    }
    try filter.object.put(allocator, "state", state_obj);

    if (assignee) |assignee_value| {
        var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try eq_obj.object.put(allocator, "eq", .{ .string = assignee_value });

        var assignee_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try assignee_obj.object.put(allocator, "id", eq_obj);
        try filter.object.put(allocator, "assignee", assignee_obj);
    }

    try vars.object.put(allocator, "filter", filter);
    return vars;
}

fn appendClause(
    allocator: Allocator,
    clauses: *std.json.Array,
    field: SearchField,
    comparator: []const u8,
    query_value: []const u8,
) !void {
    switch (field) {
        .title => {
            var cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
            try cmp.object.put(allocator, comparator, .{ .string = query_value });
            var entry = std.json.Value{ .object = std.json.ObjectMap.empty };
            try entry.object.put(allocator, "title", cmp);
            try clauses.append(entry);
        },
        .description => {
            var cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
            try cmp.object.put(allocator, comparator, .{ .string = query_value });
            var entry = std.json.Value{ .object = std.json.ObjectMap.empty };
            try entry.object.put(allocator, "description", cmp);
            try clauses.append(entry);
        },
        .comments => {
            var body_cmp = std.json.Value{ .object = std.json.ObjectMap.empty };
            try body_cmp.object.put(allocator, comparator, .{ .string = query_value });

            var comment_filter = std.json.Value{ .object = std.json.ObjectMap.empty };
            try comment_filter.object.put(allocator, "body", body_cmp);

            var comments_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try comments_obj.object.put(allocator, "some", comment_filter);

            var entry = std.json.Value{ .object = std.json.ObjectMap.empty };
            try entry.object.put(allocator, "comments", comments_obj);
            try clauses.append(entry);
        },
    }
}

/// Errors carry no payload in Zig, so the token that was refused is handed back
/// through `rejected` for the diagnostic to name.
const SearchFieldsError = error{ InvalidField, OutOfMemory };

fn parseSearchFields(
    raw: ?[]const u8,
    buffer: *std.ArrayListUnmanaged(SearchField),
    allocator: Allocator,
    rejected: *[]const u8,
) SearchFieldsError![]const SearchField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseSearchFieldName(trimmed) orelse {
                rejected.* = trimmed;
                return error.InvalidField;
            };
            if (!containsSearchField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) {
            rejected.* = value;
            return error.InvalidField;
        }
        return buffer.items;
    }
    return default_search_fields[0..];
}

fn parseSearchFieldName(name: []const u8) ?SearchField {
    for (std.enums.values(SearchField)) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(candidate))) return candidate;
    }
    return null;
}

fn containsSearchField(haystack: []const SearchField, needle: SearchField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}

/// `SearchOnlyField` and `UnavailableField` are split out of `InvalidField`
/// because both have a specific, actionable cause: the value belongs to
/// `--search-fields`, or to `issues list`. Only a value in neither vocabulary is
/// a plain typo.
const PrintFieldsError = error{ InvalidField, SearchOnlyField, UnavailableField, OutOfMemory };

fn parsePrintFields(
    raw: ?[]const u8,
    buffer: *std.ArrayListUnmanaged(printer.IssueField),
    allocator: Allocator,
    rejected: *[]const u8,
) PrintFieldsError![]const printer.IssueField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = printer.parseIssueField(trimmed) orelse {
                rejected.* = trimmed;
                if (parseSearchFieldName(trimmed) != null) return error.SearchOnlyField;
                return error.InvalidField;
            };
            if (!containsPrintField(available_print_fields[0..], field)) {
                rejected.* = trimmed;
                return error.UnavailableField;
            }
            if (!containsPrintField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) {
            rejected.* = value;
            return error.InvalidField;
        }
        return buffer.items;
    }
    return available_print_fields[0..];
}

fn containsPrintField(haystack: []const printer.IssueField, needle: printer.IssueField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}

/// True when every selected column is also a `--search-fields` value, i.e. the
/// list is indistinguishable from one written for the old meaning of `--fields`.
fn allSearchTargets(fields: []const printer.IssueField) bool {
    if (fields.len == 0) return false;
    for (fields) |field| {
        if (parseSearchFieldName(@tagName(field)) == null) return false;
    }
    return true;
}

fn printSearchFieldVocabulary(writer: anytype) !void {
    try writer.print(
        "search: valid --search-fields values: {s} (default: {s})\n",
        .{ search_field_list, default_search_field_list },
    );
}

fn printPrintFieldVocabulary(writer: anytype) !void {
    try writer.print("search: valid --fields values: {s}\n", .{available_print_field_list});
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

/// Parse issue number from identifier (e.g., "SEND-53" -> 53, "ENG-123" -> 123)
/// Returns null if value doesn't look like an identifier.
fn parseIdentifierNumber(value: []const u8) ?i64 {
    // Must have at least "X-1" (3 chars)
    if (value.len < 3) return null;

    // Find the hyphen
    const hyphen_pos = std.mem.indexOfScalar(u8, value, '-') orelse return null;

    // Must have at least one char before and after hyphen
    if (hyphen_pos == 0 or hyphen_pos == value.len - 1) return null;

    // Prefix must be uppercase letters only
    for (value[0..hyphen_pos]) |c| {
        if (!std.ascii.isUpper(c)) return null;
    }

    // Suffix must be digits only - parse as number
    const number_str = value[hyphen_pos + 1 ..];
    return std.fmt.parseInt(i64, number_str, 10) catch null;
}

fn resolveCurrentUserId(ctx: Context, client: *graphql.GraphqlClient, allocator: Allocator, stderr: anytype) ![]const u8 {
    const query = "query Viewer { viewer { id } }";

    var response = common.send(ctx.allocator, "search", client, .{
        .query = query,
        .variables = null,
        .operation_name = "Viewer",
    }, stderr) catch {
        return error.ResolveFailed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "search", &response, stderr, client.api_key) catch {
        return error.ResolveFailed;
    };

    const data_value = response.data() orelse return error.ResolveFailed;
    const viewer_obj = common.getObjectField(data_value, "viewer") orelse return error.ResolveFailed;
    const user_id = common.getStringField(viewer_obj, "id") orelse return error.ResolveFailed;

    return allocator.dupe(u8, user_id);
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
        if (std.mem.eql(u8, arg, "--search-fields")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.search_fields = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--search-fields=")) {
            opts.search_fields = arg["--search-fields=".len..];
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
        if (std.mem.eql(u8, arg, "--state-type")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.state_type = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--state-type=")) {
            opts.state_type = arg["--state-type=".len..];
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
        if (std.mem.eql(u8, arg, "--case-sensitive")) {
            opts.case_sensitive = true;
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
        if (opts.query == null) {
            opts.query = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    if (opts.limit == 0) return error.InvalidLimit;
    if (opts.all and opts.pages != null) return error.ConflictingPageFlags;
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear search <query> [--team ID|KEY] [--search-fields LIST] [--fields LIST] [--state-type TYPES] [--assignee USER_ID|me] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--case-sensitive] [--plain] [--no-truncate] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --team ID|KEY        Restrict search to a team id or key (default: config.default_team_id if set)
        \\  --search-fields LIST Comma-separated fields to SEARCH ({[search_fields]s})
        \\                       (default: {[default_search_fields]s})
        \\  --fields LIST        Comma-separated columns to PRINT ({[print_fields]s})
        \\                       Same meaning as on issues list; the other issues list columns
        \\                       (parent, sub_issues, project, milestone) are not fetched by search
        \\  --state-type TYPES   Comma-separated workflow state types to include (default: exclude completed,canceled)
        \\  --assignee USER_ID   Filter by assignee id (use 'me' for the current user)
        \\  --limit N            Page size per request (default: 25)
        \\  --max-items N        Stop after emitting N issues (may truncate within a page)
        \\  --cursor CURSOR      Start pagination after the provided cursor
        \\  --pages N            Fetch up to N pages (default: 1)
        \\  --all                Fetch all pages until the end
        \\  --case-sensitive     Use case-sensitive matching (default: case-insensitive)
        \\  --plain              Do not pad or truncate table cells
        \\  --no-truncate        Disable ellipsis and padding in table cells
        \\  --quiet              Print only issue identifiers (one per line)
        \\  --data-only          Emit tab-separated rows (or JSON array with --json)
        \\  --help               Show this help message
        \\Examples:
        \\  linear search \"bot\"
        \\  linear search \"memory leak\" --team ENG --search-fields title,description,comments
        \\  linear search \"auth\" --fields identifier,title --data-only
        \\  linear search \"agent\" --state-type backlog,started --assignee me
        \\  linear search \"flake\" --team ENG --all --quiet
        \\
    , .{
        .search_fields = search_field_list,
        .default_search_fields = default_search_field_list,
        .print_fields = available_print_field_list,
    });
}
