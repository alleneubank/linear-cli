const std = @import("std");
const config = @import("config");
const graphql = @import("graphql");
const printer = @import("printer");
const common = @import("common");

const Allocator = std.mem.Allocator;

/// Default ceiling for `--paginate`. High enough for the connections Linear
/// actually returns, low enough that a query whose `pageInfo` never flips to
/// `hasNextPage: false` stops instead of hammering the API forever.
pub const default_max_pages: usize = 20;

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

pub const Options = struct {
    query_path: ?[]const u8 = null,
    inline_query: ?[]const u8 = null,
    vars_json: ?[]const u8 = null,
    vars_file: ?[]const u8 = null,
    data_only: bool = false,
    operation_name: ?[]const u8 = null,
    fields: ?[]const u8 = null,
    yes: bool = false,
    dry_run: bool = false,
    paginate: bool = false,
    max_pages: usize = default_max_pages,
    help: bool = false,
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidMaxPages => "invalid --max-pages value",
            else => @errorName(err),
        };
        try stderr.print("gql: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    if (opts.vars_json != null and opts.vars_file != null) {
        try stderr.print("gql: only one of --vars or --vars-file may be provided\n", .{});
        return 1;
    }

    if (opts.query_path != null and opts.inline_query != null) {
        try stderr.print("gql: cannot use both --query and inline query argument\n", .{});
        return 1;
    }

    const query_result = try loadQuery(ctx.allocator, ctx.io, opts.query_path, opts.inline_query);
    const query = query_result.data;
    defer if (query_result.owned) ctx.allocator.free(query);

    // `gql` can run arbitrary mutations, so it carries the same confirmation
    // gate as the dedicated mutating commands.
    const mutating = isMutation(query);
    if (mutating and !opts.yes and !opts.dry_run) {
        try stderr.print("gql: confirmation required; re-run with --yes to proceed\n", .{});
        return 1;
    }

    // Validated before the first request (and before any key is required) so a
    // query that cannot be walked fails immediately instead of quietly
    // returning a single page.
    if (opts.paginate) {
        if (mutating) {
            try stderr.print("gql: --paginate cannot be used with a mutation document\n", .{});
            return 1;
        }
        if (!declaresAfterVariable(query)) {
            try stderr.print("gql: --paginate requires the query to declare an $after variable\n", .{});
            return 1;
        }
        if (!selectsPageInfo(query)) {
            try stderr.print("gql: --paginate requires the query to select pageInfo {{ hasNextPage endCursor }}\n", .{});
            return 1;
        }
    }

    // A dry run makes no request, so it must not require credentials; the key
    // is only resolved once a request is actually going to be sent.
    if (opts.dry_run) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try out_writer.interface.print(
            "gql: dry run; would send {s} operation ({d} bytes), no request made\n",
            .{ if (mutating) "mutation" else "query", query.len },
        );
        return 0;
    }

    const api_key = ctx.config.resolveApiKey(null) catch |err| {
        try stderr.print("gql: {s}\n", .{@errorName(err)});
        try stderr.print("set LINEAR_API_KEY or configure api_key in the config file\n", .{});
        return 1;
    };

    var vars_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer {
        if (vars_parsed) |*parsed| parsed.deinit();
    }

    var variables_value: ?std.json.Value = null;
    if (opts.vars_json) |inline_vars| {
        const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, inline_vars, .{});
        vars_parsed = parsed;
        variables_value = vars_parsed.?.value;
    } else if (opts.vars_file) |vars_path| {
        const vars_text = try readFile(ctx.allocator, ctx.io, vars_path);
        defer ctx.allocator.free(vars_text);

        const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, vars_text, .{});
        vars_parsed = parsed;
        variables_value = vars_parsed.?.value;
    }

    if (opts.paginate) {
        if (variables_value) |value| {
            if (value != .object) {
                try stderr.print("gql: --paginate requires variables to be a JSON object\n", .{});
                return 1;
            }
        }
    }

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    // Parsed values are borrowed from their response, so every page has to stay
    // alive until the merged document has been written.
    var responses = std.ArrayListUnmanaged(graphql.GraphqlClient.Response).empty;
    defer {
        for (responses.items) |*resp| resp.deinit();
        responses.deinit(ctx.allocator);
    }

    var merge_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer merge_arena.deinit();
    const merge_alloc = merge_arena.allocator();

    var merged_root: ?std.json.Value = null;
    var merged_data: ?std.json.Value = null;

    if (opts.paginate) {
        const walked = walkPages(ctx, &client, &responses, merge_alloc, query, variables_value, opts, stderr) catch |err| {
            if (err == common.CommandError.CommandFailed) return 1;
            return err;
        };
        merged_root = walked.root;
        merged_data = walked.data;
    } else {
        var response = common.send(ctx.allocator, "gql", &client, .{
            .query = query,
            .variables = variables_value,
            .operation_name = opts.operation_name,
        }, stderr) catch {
            return 1;
        };
        responses.append(ctx.allocator, response) catch |err| {
            response.deinit();
            return err;
        };
    }

    const last = &responses.items[responses.items.len - 1];
    const data_value = if (merged_data) |value| value else last.data();
    const envelope_value = if (merged_root) |value| value else last.parsed.value;

    var stdout_buf: [0]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buf);
    const pretty = !ctx.json_output;
    var fields_buf = std.ArrayListUnmanaged([]const u8).empty;
    defer fields_buf.deinit(ctx.allocator);
    const selected_fields = parseFields(opts.fields, &fields_buf, ctx.allocator) catch |err| {
        const message = switch (err) {
            error.InvalidFieldList => "invalid --fields value",
            else => @errorName(err),
        };
        try stderr.print("gql: {s}\n", .{message});
        return 1;
    };

    if (opts.data_only) {
        const data_root = data_value orelse {
            try stderr.print("gql: response did not include a data field\n", .{});
            return 1;
        };

        if (selected_fields) |fields| {
            printer.printJsonFields(data_root, &stdout_writer.interface, pretty, fields) catch |err| {
                const message = switch (err) {
                    error.UnknownField => "requested field not found in response",
                    error.InvalidRoot => "fields can only target objects",
                    else => @errorName(err),
                };
                try stderr.print("gql: {s}\n", .{message});
                return 1;
            };
        } else {
            try printer.printJson(data_root, &stdout_writer.interface, pretty);
        }
    } else {
        if (selected_fields) |fields| {
            const target = data_value orelse {
                try stderr.print("gql: response did not include a data field\n", .{});
                return 1;
            };
            printer.printJsonFields(target, &stdout_writer.interface, pretty, fields) catch |err| {
                const message = switch (err) {
                    error.UnknownField => "requested field not found in response",
                    error.InvalidRoot => "fields can only target objects",
                    else => @errorName(err),
                };
                try stderr.print("gql: {s}\n", .{message});
                return 1;
            };
        } else {
            try printer.printJson(envelope_value, &stdout_writer.interface, pretty);
        }
    }

    if (!last.isSuccessStatus()) {
        try stderr.print("gql: HTTP status {d}\n", .{last.status});
        if (last.firstErrorMessage()) |msg| {
            try stderr.print("gql: {s}\n", .{msg});
        }
        return 1;
    }

    if (last.hasGraphqlErrors()) {
        if (last.firstErrorMessage()) |msg| {
            try stderr.print("gql: {s}\n", .{msg});
        }
        return 1;
    }

    return 0;
}

const Merged = struct {
    /// Null when a page came back failed; the caller then falls back to
    /// printing that page's raw envelope and reporting the error.
    root: ?std.json.Value = null,
    data: ?std.json.Value = null,
};

/// Re-issues the query with each `endCursor` until the connection is exhausted,
/// the `--max-pages` bound is hit, or a page fails.
///
/// Every page is appended to `responses` (never freed here) because the merged
/// document borrows node values from all of them.
fn walkPages(
    ctx: Context,
    client: *graphql.GraphqlClient,
    responses: *std.ArrayListUnmanaged(graphql.GraphqlClient.Response),
    merge_alloc: Allocator,
    query: []const u8,
    base_variables: ?std.json.Value,
    opts: Options,
    stderr: *std.Io.Writer,
) !Merged {
    var nodes_accumulator = std.ArrayListUnmanaged(std.json.Value).empty;
    defer nodes_accumulator.deinit(ctx.allocator);

    var connection_path: ?[]const []const u8 = null;
    var last_page_info: ?std.json.Value = null;
    var next_cursor: ?[]const u8 = null;
    var page_count: usize = 0;
    var truncated = false;

    while (true) {
        const variables = try withCursor(merge_alloc, base_variables, next_cursor);

        var response = common.send(ctx.allocator, "gql", client, .{
            .query = query,
            .variables = variables,
            .operation_name = opts.operation_name,
        }, stderr) catch {
            return common.CommandError.CommandFailed;
        };
        responses.append(ctx.allocator, response) catch |err| {
            response.deinit();
            return err;
        };
        const resp = &responses.items[responses.items.len - 1];
        page_count += 1;

        // A failed page stops the walk; the caller prints that page verbatim and
        // reports the HTTP/GraphQL error, exactly as an unpaginated run would.
        if (!resp.isSuccessStatus() or resp.hasGraphqlErrors()) return .{};

        const data_root = resp.data() orelse {
            try stderr.print("gql: response did not include a data field\n", .{});
            return common.CommandError.CommandFailed;
        };

        if (connection_path == null) {
            const discovered = try findConnection(merge_alloc, data_root);
            connection_path = discovered orelse {
                try stderr.print(
                    "gql: --paginate found no connection selecting both 'nodes' and 'pageInfo' in the response\n",
                    .{},
                );
                return common.CommandError.CommandFailed;
            };
        }

        const connection = resolvePath(data_root, connection_path.?) orelse {
            try stderr.print("gql: --paginate lost the connection on page {d}\n", .{page_count});
            return common.CommandError.CommandFailed;
        };
        const nodes = common.getArrayField(connection, "nodes") orelse {
            try stderr.print("gql: --paginate found no 'nodes' array on page {d}\n", .{page_count});
            return common.CommandError.CommandFailed;
        };
        try nodes_accumulator.appendSlice(ctx.allocator, nodes.items);

        const page_info = common.getObjectField(connection, "pageInfo");
        last_page_info = page_info;

        const has_next = if (page_info) |info| common.getBoolField(info, "hasNextPage") orelse false else false;
        if (!has_next) break;

        if (page_count >= opts.max_pages) {
            truncated = true;
            break;
        }

        next_cursor = if (page_info) |info| common.getStringField(info, "endCursor") else null;
        if (next_cursor == null) {
            try stderr.print("gql: --paginate needs an endCursor to continue but the page did not return one\n", .{});
            return common.CommandError.CommandFailed;
        }
    }

    var nodes_value = std.json.Value{ .array = std.json.Array.init(merge_alloc) };
    try nodes_value.array.appendSlice(nodes_accumulator.items);

    const first = &responses.items[0];
    const first_data = first.data() orelse {
        try stderr.print("gql: response did not include a data field\n", .{});
        return common.CommandError.CommandFailed;
    };

    const data = try rebuildPath(merge_alloc, first_data, connection_path.?, nodes_value, last_page_info);
    const root = try replaceData(merge_alloc, first.parsed.value, data);

    if (truncated) {
        try stderr.print(
            "gql: --paginate stopped after {d} pages (--max-pages {d}); more results remain\n",
            .{ page_count, opts.max_pages },
        );
    }

    return .{ .root = root, .data = data };
}

/// Shallow-copies `base` and sets `after`. Page one passes a null cursor and
/// gets the caller's variables back untouched.
fn withCursor(allocator: Allocator, base: ?std.json.Value, cursor: ?[]const u8) !?std.json.Value {
    const cursor_value = cursor orelse return base;

    var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
    if (base) |value| {
        if (value == .object) {
            var iter = value.object.iterator();
            while (iter.next()) |entry| {
                try obj.object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }
    try obj.object.put(allocator, "after", .{ .string = cursor_value });
    return obj;
}

/// Reports whether `value` is a GraphQL connection this command can walk: it
/// must select a `nodes` array and a `pageInfo` object carrying `hasNextPage`.
fn isConnection(value: std.json.Value) bool {
    if (common.getArrayField(value, "nodes") == null) return false;
    const page_info = common.getObjectField(value, "pageInfo") orelse return false;
    return common.getBoolField(page_info, "hasNextPage") != null;
}

/// Locates the connection to walk, breadth-first so a top-level connection wins
/// over a nested one. Returns the key path from `root`, or null when the
/// response has no walkable connection. Only object children are traversed:
/// a connection buried inside an array has no single stable path to merge into.
fn findConnection(allocator: Allocator, root: std.json.Value) !?[]const []const u8 {
    const Entry = struct {
        value: std.json.Value,
        path: []const []const u8,
    };

    var queue = std.ArrayListUnmanaged(Entry).empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, .{ .value = root, .path = &.{} });

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const entry = queue.items[head];
        if (entry.value != .object) continue;
        if (isConnection(entry.value)) return entry.path;

        var iter = entry.value.object.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.* != .object) continue;
            const child_path = try allocator.alloc([]const u8, entry.path.len + 1);
            @memcpy(child_path[0..entry.path.len], entry.path);
            child_path[entry.path.len] = kv.key_ptr.*;
            try queue.append(allocator, .{ .value = kv.value_ptr.*, .path = child_path });
        }
    }

    return null;
}

fn resolvePath(root: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = root;
    for (path) |key| {
        if (current != .object) return null;
        current = current.object.get(key) orelse return null;
    }
    if (current != .object) return null;
    return current;
}

/// Rebuilds `value` with the object at `path` carrying the merged `nodes` and
/// the final `pageInfo`. Only the objects along `path` are copied; every other
/// entry is shared with the response that owns it, which is why the responses
/// have to outlive the printed document.
fn rebuildPath(
    allocator: Allocator,
    value: std.json.Value,
    path: []const []const u8,
    nodes: std.json.Value,
    page_info: ?std.json.Value,
) !std.json.Value {
    if (value != .object) return error.InvalidConnection;

    var copy = std.json.Value{ .object = std.json.ObjectMap.empty };
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        try copy.object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    if (path.len == 0) {
        try copy.object.put(allocator, "nodes", nodes);
        if (page_info) |info| try copy.object.put(allocator, "pageInfo", info);
        return copy;
    }

    const child = value.object.get(path[0]) orelse return error.InvalidConnection;
    const rebuilt = try rebuildPath(allocator, child, path[1..], nodes, page_info);
    try copy.object.put(allocator, path[0], rebuilt);
    return copy;
}

fn replaceData(allocator: Allocator, envelope: std.json.Value, data: std.json.Value) !std.json.Value {
    if (envelope != .object) return data;

    var copy = std.json.Value{ .object = std.json.ObjectMap.empty };
    var iter = envelope.object.iterator();
    while (iter.next()) |entry| {
        try copy.object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    try copy.object.put(allocator, "data", data);
    return copy;
}

/// Reports whether the document *declares* an `$after` variable. A definition
/// reads `$after: String`, a use reads `after: $after`, so the trailing colon
/// is what tells them apart — otherwise a query that references `$after`
/// without declaring it would look paginatable and fail server-side.
pub fn declaresAfterVariable(query: []const u8) bool {
    const needle = "$after";
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, query, idx, needle)) |found| {
        idx = found + needle.len;
        if (idx < query.len and isNameChar(query[idx])) continue;

        var cursor = idx;
        while (cursor < query.len and std.ascii.isWhitespace(query[cursor])) : (cursor += 1) {}
        if (cursor < query.len and query[cursor] == ':') return true;
    }
    return false;
}

/// Reports whether the document selects the three fields the walk depends on.
pub fn selectsPageInfo(query: []const u8) bool {
    return containsIdentifier(query, "pageInfo") and
        containsIdentifier(query, "hasNextPage") and
        containsIdentifier(query, "endCursor");
}

fn containsIdentifier(haystack: []const u8, needle: []const u8) bool {
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |found| {
        idx = found + needle.len;
        const before_ok = found == 0 or !isNameChar(haystack[found - 1]);
        const after_ok = idx >= haystack.len or !isNameChar(haystack[idx]);
        if (before_ok and after_ok) return true;
    }
    return false;
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
        if (std.mem.eql(u8, arg, "--query")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.query_path = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--query=")) {
            opts.query_path = arg["--query=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--vars")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.vars_json = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--vars=")) {
            opts.vars_json = arg["--vars=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--vars-file")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.vars_file = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--vars-file=")) {
            opts.vars_file = arg["--vars-file=".len..];
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-only")) {
            opts.data_only = true;
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
        if (std.mem.eql(u8, arg, "--paginate")) {
            opts.paginate = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-pages")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.max_pages = try parseMaxPages(args[idx + 1]);
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--max-pages=")) {
            opts.max_pages = try parseMaxPages(arg["--max-pages=".len..]);
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
        if (std.mem.eql(u8, arg, "--operation-name")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.operation_name = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--operation-name=")) {
            opts.operation_name = arg["--operation-name=".len..];
            idx += 1;
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        // Positional argument: treat as inline query
        if (opts.inline_query != null) return error.UnexpectedArgument;
        opts.inline_query = arg;
        idx += 1;
    }

    return opts;
}

fn parseMaxPages(raw: []const u8) !usize {
    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidMaxPages;
    if (value <= 0) return error.InvalidMaxPages;
    return std.math.cast(usize, value) orelse error.InvalidMaxPages;
}

/// Reports whether the document declares a mutation operation.
///
/// Scans only top-level tokens (brace depth 0) so field names such as
/// `mutation` inside a selection set cannot trigger a false positive, and skips
/// `#` comments plus string/block-string literals. Handles leading whitespace,
/// named operations (`mutation Foo {`), and documents that mix operations.
pub fn isMutation(query: []const u8) bool {
    var idx: usize = 0;
    var depth: usize = 0;
    while (idx < query.len) {
        const ch = query[idx];
        switch (ch) {
            '#' => {
                while (idx < query.len and query[idx] != '\n') : (idx += 1) {}
            },
            '"' => idx = skipStringLiteral(query, idx),
            '{' => {
                depth += 1;
                idx += 1;
            },
            '}' => {
                if (depth > 0) depth -= 1;
                idx += 1;
            },
            else => {
                if (isNameStart(ch)) {
                    const start = idx;
                    while (idx < query.len and isNameChar(query[idx])) : (idx += 1) {}
                    if (depth == 0 and std.mem.eql(u8, query[start..idx], "mutation")) return true;
                } else {
                    idx += 1;
                }
            },
        }
    }
    return false;
}

/// Returns the index just past the literal that starts at `start`.
fn skipStringLiteral(query: []const u8, start: usize) usize {
    if (std.mem.startsWith(u8, query[start..], "\"\"\"")) {
        var idx = start + 3;
        while (idx < query.len) : (idx += 1) {
            if (query[idx] == '\\') {
                idx += 1;
                continue;
            }
            if (std.mem.startsWith(u8, query[idx..], "\"\"\"")) return idx + 3;
        }
        return query.len;
    }

    var idx = start + 1;
    while (idx < query.len) : (idx += 1) {
        switch (query[idx]) {
            '\\' => idx += 1,
            '"' => return idx + 1,
            '\n' => return idx + 1,
            else => {},
        }
    }
    return query.len;
}

fn isNameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn parseFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged([]const u8), allocator: Allocator) !?[]const []const u8 {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            if (trimmed.len == 0) continue;
            try buffer.append(allocator, trimmed);
        }
        if (buffer.items.len == 0) return error.InvalidFieldList;
        return buffer.items;
    }
    return null;
}

const QueryResult = struct {
    data: []const u8,
    owned: bool,
};

fn loadQuery(allocator: Allocator, io: std.Io, path: ?[]const u8, inline_query: ?[]const u8) !QueryResult {
    if (path) |query_path| {
        return .{ .data = try readFile(allocator, io, query_path), .owned = true };
    }

    if (inline_query) |q| {
        return .{ .data = q, .owned = false };
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    return .{ .data = try stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)), .owned = true };
}

fn readFile(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

pub fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: linear gql [QUERY] [--query FILE] [--vars JSON|--vars-file FILE] [--data-only] [--operation-name NAME] [--fields LIST] [--paginate] [--max-pages N] [--yes] [--dry-run] [--help]
        \\
        \\Arguments:
        \\  QUERY                 Inline GraphQL query string (alternative to --query or stdin)
        \\
        \\Flags:
        \\  --query FILE          Read GraphQL query from a file (default: stdin)
        \\  --vars JSON           Inline JSON variables
        \\  --vars-file FILE      Load JSON variables from a file
        \\  --data-only           Print only the data payload
        \\  --operation-name NAME Set GraphQL operationName
        \\  --fields LIST         Comma-separated top-level fields to include in the output
        \\  --paginate            Follow pageInfo.endCursor and merge every page's nodes
        \\  --max-pages N         Cap on --paginate requests (default: 20)
        \\  --yes                 Required for mutation documents (alias: --force)
        \\  --dry-run             Report the operation without sending a request
        \\  --help                Show this help message
        \\
        \\Pagination:
        \\  --paginate re-issues the query with each returned endCursor and merges the
        \\  connection's nodes arrays into the first page's document. The query must
        \\  declare an $after variable, pass it to the connection, and select
        \\  pageInfo { hasNextPage endCursor }; anything else is rejected up front.
        \\  The shallowest connection in the response is the one that gets walked.
        \\
        \\Environment:
        \\  LINEAR_API_KEY        Overrides api_key from config when present
        \\
        \\Examples:
        \\  linear gql 'query { viewer { id } }' --data-only --json
        \\  linear gql --query query.graphql --vars '{"id":"abc"}'
        \\  linear gql 'mutation { issueDelete(id: "abc") { success } }' --yes
        \\  linear gql --query issues.graphql --paginate --max-pages 5 --data-only
        \\  echo "query { viewer { id } }" | linear gql --data-only --json
        \\
    );
}
