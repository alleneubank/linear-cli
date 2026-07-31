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
    fields: ?[]const u8 = null,
    state_type: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    limit: usize = 25,
    case_sensitive: bool = false,
    help: bool = false,
};

const SearchField = enum { title, description, comments };
const default_fields = [_]SearchField{ .title, .description };

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --limit value",
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

    const api_key = common.requireApiKey(ctx.config, null, stderr, "search") catch {
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

    var fields_buf = std.ArrayListUnmanaged(SearchField).empty;
    defer fields_buf.deinit(ctx.allocator);
    const selected_fields = parseFields(opts.fields, &fields_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("search: {s}\n", .{message});
        return 1;
    };

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
    const variables = buildVariables(var_alloc, query_value, selected_fields, opts, ctx.config.default_state_filter, assignee_value, team_value) catch |err| {
        const message = switch (err) {
            error.InvalidStateFilter => "invalid --state-type value",
            else => @errorName(err),
        };
        try stderr.print("search: {s}\n", .{message});
        return 1;
    };

    const query =
        \\query SearchIssues($filter: IssueFilter!, $first: Int!) {
        \\  issues(filter: $filter, first: $first) {
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

    var response = common.send(ctx.allocator, "search", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "SearchIssues",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "search", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
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
    const page_info = common.getObjectField(issues_obj, "pageInfo");
    const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
    const end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;

    const trimmed_team = std.mem.trim(u8, team_value, " \t");
    if (nodes_array.items.len == 0 and trimmed_team.len > 0) {
        try stderr.print("search: 0 results (team filter: {s})\n", .{trimmed_team});
    }

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
    } else {
        var rows = std.ArrayListUnmanaged(printer.IssueRow).empty;
        defer rows.deinit(ctx.allocator);
        for (nodes_array.items) |node| {
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

        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printIssueTable(ctx.allocator, &out_writer.interface, rows.items, printer.issue_default_fields[0..], .{});
    }

    if (has_next) {
        if (end_cursor) |cursor| {
            try stderr.print("search: additional results available; pagination not implemented (resume with cursor {s})\n", .{cursor});
        } else {
            try stderr.print("search: additional results available; pagination not implemented\n", .{});
        }
    }

    return 0;
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

fn parseFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(SearchField), allocator: Allocator) ![]const SearchField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseFieldName(trimmed) orelse return error.InvalidField;
            if (!containsField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return default_fields[0..];
}

fn parseFieldName(name: []const u8) ?SearchField {
    if (std.ascii.eqlIgnoreCase(name, "title")) return .title;
    if (std.ascii.eqlIgnoreCase(name, "description")) return .description;
    if (std.ascii.eqlIgnoreCase(name, "comments")) return .comments;
    return null;
}

fn containsField(haystack: []const SearchField, needle: SearchField) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
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
        if (std.mem.eql(u8, arg, "--case-sensitive")) {
            opts.case_sensitive = true;
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
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear search <query> [--team ID|KEY] [--fields LIST] [--state-type TYPES] [--assignee USER_ID|me] [--limit N] [--case-sensitive] [--help]
        \\Flags:
        \\  --team ID|KEY        Restrict search to a team id or key (default: config.default_team_id if set)
        \\  --fields LIST        Comma-separated fields to search (title,description,comments)
        \\  --state-type TYPES   Comma-separated workflow state types to include (default: exclude completed,canceled)
        \\  --assignee USER_ID   Filter by assignee id (use 'me' for the current user)
        \\  --limit N            Maximum results to return (default: 25)
        \\  --case-sensitive     Use case-sensitive matching (default: case-insensitive)
        \\  --help               Show this help message
        \\Examples:
        \\  linear search \"bot\"
        \\  linear search \"memory leak\" --team ENG --fields title,description,comments
        \\  linear search \"agent\" --state-type backlog,started --assignee me
        \\
    , .{});
}
