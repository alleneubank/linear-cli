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
    team: ?[]const u8 = null,
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

const DataRow = struct {
    id: []const u8,
    name: []const u8,
    color: []const u8,
    description: []const u8,
    team: []const u8,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --limit value",
            error.InvalidPageCount => "invalid --pages value",
            else => @errorName(err),
        };
        try stderr.print("labels list: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const api_key = common.requireApiKey(ctx.config, null, stderr, "labels list") catch {
        return 1;
    };

    var field_buf = std.ArrayListUnmanaged(printer.LabelField).empty;
    defer field_buf.deinit(ctx.allocator);
    const selected_fields = parseLabelFields(opts.fields, &field_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidField => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("labels list: {s}\n", .{message});
        return 1;
    };

    if (opts.limit == 0) {
        try stderr.print("labels list: --limit must be greater than zero\n", .{});
        return 1;
    }
    if (opts.max_items) |max_value| {
        if (max_value == 0) {
            try stderr.print("labels list: invalid --max-items value\n", .{});
            return 1;
        }
    }
    const disable_trunc = opts.plain or opts.no_truncate;
    const table_opts = printer.TableOptions{
        .pad = !disable_trunc,
        .truncate = !disable_trunc,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    const page_size = opts.limit;
    const limit_i64 = std.math.cast(i64, page_size) orelse return error.InvalidLimit;

    // Built once and reused by every page; only `after` changes between requests.
    var team_filter: ?std.json.Value = null;
    if (opts.team) |team_raw| {
        const trimmed = std.mem.trim(u8, team_raw, " \t");
        if (trimmed.len == 0) {
            try stderr.print("labels list: invalid --team value\n", .{});
            return 1;
        }
        var eq_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try eq_obj.object.put(var_alloc, "eq", .{ .string = trimmed });

        var team_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        if (isUuid(trimmed)) {
            try team_obj.object.put(var_alloc, "id", eq_obj);
        } else {
            try team_obj.object.put(var_alloc, "key", eq_obj);
        }

        var filter = std.json.Value{ .object = std.json.ObjectMap.empty };
        try filter.object.put(var_alloc, "team", team_obj);
        team_filter = filter;
    }

    const query =
        \\query IssueLabels($first: Int!, $after: String, $filter: IssueLabelFilter) {
        \\  issueLabels(first: $first, after: $after, filter: $filter) {
        \\    nodes { id name color description team { key } }
        \\    pageInfo { hasNextPage endCursor }
        \\  }
        \\}
    ;

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

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

    var rows = std.ArrayListUnmanaged(printer.LabelRow).empty;
    defer rows.deinit(ctx.allocator);
    var data_rows = std.ArrayListUnmanaged(DataRow).empty;
    defer data_rows.deinit(ctx.allocator);
    var nodes_accumulator = std.ArrayListUnmanaged(std.json.Value).empty;
    defer nodes_accumulator.deinit(ctx.allocator);

    var progress = common.PageProgress{};
    var next_cursor = opts.cursor;
    const page_limit: ?usize = if (opts.all) null else opts.pages orelse 1;

    while (true) {
        if (page_limit) |limit_pages| {
            if (progress.pages >= limit_pages) break;
        }

        var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
        try variables.object.put(var_alloc, "first", .{ .integer = limit_i64 });
        if (next_cursor) |cursor_value| try variables.object.put(var_alloc, "after", .{ .string = cursor_value });
        if (team_filter) |filter| try variables.object.put(var_alloc, "filter", filter);

        var response = common.send(ctx.allocator, "labels list", &client, .{
            .query = query,
            .variables = variables,
            .operation_name = "IssueLabels",
        }, stderr) catch {
            return 1;
        };
        var response_owned = true;
        errdefer if (response_owned) response.deinit();

        // `errdefer` does not fire on `return 1` — that is a successful return
        // of an exit code — so a rejected page is freed by hand here.
        common.checkResponse(ctx.io, "labels list", &response, stderr, api_key) catch {
            if (response_owned) response.deinit();
            return 1;
        };

        try responses.append(ctx.allocator, response);
        response_owned = false;
        const resp = &responses.items[responses.items.len - 1];

        const data_value = resp.data() orelse {
            try stderr.print("labels list: response missing data\n", .{});
            return 1;
        };
        const labels_obj = common.getObjectField(data_value, "issueLabels") orelse {
            try stderr.print("labels list: issueLabels not found in response\n", .{});
            return 1;
        };
        const nodes_array = common.getArrayField(labels_obj, "nodes") orelse {
            try stderr.print("labels list: nodes missing in response\n", .{});
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
                const id = common.getStringField(node, "id") orelse continue;
                const name = common.getStringField(node, "name") orelse "";
                const color = common.getStringField(node, "color") orelse "";
                const description = common.getStringField(node, "description") orelse "";
                const team_obj = common.getObjectField(node, "team");
                const team_key = if (team_obj) |t| common.getStringField(t, "key") orelse "" else "";

                if (want_table) {
                    try rows.append(ctx.allocator, .{
                        .id = id,
                        .name = name,
                        .color = color,
                        .description = description,
                        .team = team_key,
                    });
                }
                if (want_data_rows) {
                    try data_rows.append(ctx.allocator, .{
                        .id = id,
                        .name = name,
                        .color = color,
                        .description = description,
                        .team = team_key,
                    });
                }
            }
        }

        const page_info = common.getObjectField(labels_obj, "pageInfo");
        const has_next = if (page_info) |pi| common.getBoolField(pi, "hasNextPage") orelse false else false;
        progress.end_cursor = if (page_info) |pi| common.getStringField(pi, "endCursor") else null;
        progress.more_available = has_next;

        if (allowed_count < take_count and opts.max_items != null) {
            progress.max_items_reached = true;
        }

        if (take_count == 0 or allowed_count == 0) {
            if (has_next) {
                try stderr.print("labels list: received empty page; stopping pagination\n", .{});
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
            try stderr.print("labels list: missing endCursor for additional page\n", .{});
            break;
        }
        next_cursor = progress.end_cursor;
    }

    if (progress.max_items_reached) progress.more_available = true;

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
            try root_obj.object.put(var_alloc, "pageInfo", try pageInfoValue(var_alloc, progress));
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
    } else if (want_raw_nodes) {
        var nodes_value = std.json.Value{ .array = std.json.Array.init(var_alloc) };
        try nodes_value.array.appendSlice(nodes_accumulator.items);

        var labels_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try labels_obj.object.put(var_alloc, "nodes", nodes_value);
        try labels_obj.object.put(var_alloc, "pageInfo", try pageInfoValue(var_alloc, progress));

        var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
        try root_obj.object.put(var_alloc, "issueLabels", labels_obj);
        try printer.printJson(root_obj, stdout_iface, true);
    } else {
        try printer.printLabelTable(ctx.allocator, stdout_iface, rows.items, selected_fields, table_opts);
    }

    try common.printPageSummary(stderr, "labels list", progress, ctx.json_output);
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

fn fieldKey(field: printer.LabelField) []const u8 {
    return switch (field) {
        .id => "id",
        .name => "name",
        .color => "color",
        .description => "description",
        .team => "team",
    };
}

fn cellValue(row: DataRow, field: printer.LabelField) []const u8 {
    return switch (field) {
        .id => row.id,
        .name => row.name,
        .color => row.color,
        .description => row.description,
        .team => row.team,
    };
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
        return error.UnexpectedArgument;
    }
    if (opts.all and opts.pages != null) return error.ConflictingPageFlags;
    return opts;
}

fn parseLimit(raw: []const u8) !usize {
    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidLimit;
    if (value <= 0) return error.InvalidLimit;
    return std.math.cast(usize, value) orelse error.InvalidLimit;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear labels list [--team ID|KEY] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--fields LIST] [--plain] [--no-truncate] [--quiet] [--data-only] [--help]
        \\Flags:
        \\  --team ID|KEY    Filter by team id or key
        \\  --limit N        Page size per request (default: 50)
        \\  --max-items N    Stop after emitting N labels (may truncate within a page)
        \\  --cursor CURSOR  Start pagination after the provided cursor
        \\  --pages N        Fetch up to N pages (default: 1)
        \\  --all            Fetch all pages until the end
        \\  --fields LIST    Comma-separated columns (id,name,color,description,team)
        \\  --plain          Do not pad or truncate table cells
        \\  --no-truncate    Disable ellipsis and padding in table cells
        \\  --quiet          Print only label ids (one per line)
        \\  --data-only      Emit tab-separated rows (or JSON array with --json)
        \\  --help           Show this help message
        \\Examples:
        \\  linear labels list --team ENG
        \\  linear labels list --team ENG --fields id,name --data-only
        \\  linear labels list --all --quiet
        \\  linear issues list --team ENG --label "$(linear labels list --team ENG --quiet | head -1)"
        \\
    , .{});
}

fn parseLabelFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(printer.LabelField), allocator: Allocator) ![]const printer.LabelField {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseLabelFieldName(trimmed) orelse return error.InvalidField;
            if (!containsLabelField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidField;
        return buffer.items;
    }
    return printer.label_default_fields[0..];
}

fn parseLabelFieldName(name: []const u8) ?printer.LabelField {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    if (std.ascii.eqlIgnoreCase(name, "color")) return .color;
    if (std.ascii.eqlIgnoreCase(name, "description")) return .description;
    if (std.ascii.eqlIgnoreCase(name, "team")) return .team;
    return null;
}

fn containsLabelField(haystack: []const printer.LabelField, needle: printer.LabelField) bool {
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
