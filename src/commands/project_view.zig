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
    identifier: ?[]const u8 = null,
    fields: ?[]const u8 = null,
    issue_limit: usize = 10,
    help: bool = false,
};

const Field = enum { id, name, slug, description, state, start_date, target_date, url, lead, teams, issues };
const default_fields = [_]Field{ .name, .state, .lead, .teams, .start_date, .target_date, .url, .issues, .description };

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        const message = switch (err) {
            error.InvalidLimit => "invalid --issue-limit value",
            else => @errorName(err),
        };
        try stderr.print("project view: {s}\n", .{message});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    const target = opts.identifier orelse {
        try stderr.print("project view: missing id\n", .{});
        return 1;
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "project view") catch {
        return 1;
    };

    var fields_buf = std.ArrayListUnmanaged(Field).empty;
    defer fields_buf.deinit(ctx.allocator);
    const selected_fields = parseFields(opts.fields, &fields_buf, ctx.allocator) catch |err| switch (err) {
        error.InvalidFieldList => {
            try stderr.print("project view: invalid --fields value\n", .{});
            return 1;
        },
        else => return err,
    };
    if (selected_fields.len == 0) {
        try stderr.print("project view: no fields selected\n", .{});
        return 1;
    }
    const include_issues = containsField(selected_fields, .issues) and opts.issue_limit > 0;
    const include_teams = containsField(selected_fields, .teams);
    const include_lead = containsField(selected_fields, .lead);

    var client = graphql.GraphqlClient.init(ctx.allocator, ctx.io, api_key);
    defer client.deinit();
    client.max_retries = ctx.retries;
    client.timeout_ms = ctx.timeout_ms;
    if (ctx.endpoint) |ep| client.endpoint = ep;

    const resolved = common.resolveProjectId(ctx.allocator, &client, target, stderr, "project view") catch {
        return 1;
    };
    defer if (resolved.owned) ctx.allocator.free(resolved.value);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const var_alloc = arena.allocator();

    var variables = std.json.Value{ .object = std.json.ObjectMap.empty };
    try variables.object.put(var_alloc, "id", .{ .string = resolved.value });
    if (include_issues) {
        const limit_i64 = std.math.cast(i64, opts.issue_limit) orelse return error.InvalidLimit;
        try variables.object.put(var_alloc, "issueLimit", .{ .integer = limit_i64 });
    }

    var query_builder = std.ArrayListUnmanaged(u8).empty;
    defer query_builder.deinit(ctx.allocator);
    try query_builder.appendSlice(ctx.allocator, "query ProjectView($id: String!");
    if (include_issues) try query_builder.appendSlice(ctx.allocator, ", $issueLimit: Int!");
    try query_builder.appendSlice(
        ctx.allocator,
        ") {\n  project(id: $id) {\n    id\n    name\n    slugId\n    description\n    state\n    startDate\n    targetDate\n    url\n",
    );
    if (include_lead) try query_builder.appendSlice(ctx.allocator, "    lead { name }\n");
    if (include_teams) try query_builder.appendSlice(ctx.allocator, "    teams(first: 10) { nodes { key name } }\n");
    if (include_issues) try query_builder.appendSlice(ctx.allocator, "    issues(first: $issueLimit) { nodes { identifier title } pageInfo { hasNextPage } }\n");
    try query_builder.appendSlice(ctx.allocator, "  }\n}\n");
    const query = query_builder.items;

    var response = common.send(ctx.allocator, "project view", &client, .{
        .query = query,
        .variables = variables,
        .operation_name = "ProjectView",
    }, stderr) catch {
        return 1;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "project view", &response, stderr, api_key) catch {
        return 1;
    };

    const data_value = response.data() orelse {
        try stderr.print("project view: response missing data\n", .{});
        return 1;
    };

    if (ctx.json_output) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try printer.printJson(data_value, &out_writer.interface, true);
        return 0;
    }

    const project_obj = common.getObjectField(data_value, "project") orelse {
        try stderr.print("project view: project not found\n", .{});
        return 1;
    };

    var owned_values = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (owned_values.items) |value| ctx.allocator.free(value);
        owned_values.deinit(ctx.allocator);
    }

    const base_values = struct {
        id: []const u8,
        name: []const u8,
        slug: []const u8,
        description: ?[]const u8,
        state: []const u8,
        start_date: ?[]const u8,
        target_date: ?[]const u8,
        url: []const u8,
        lead: ?[]const u8,
        teams: ?[]const u8,
        issues: ?[]const u8,
    }{
        .id = common.getStringField(project_obj, "id") orelse "(unknown)",
        .name = common.getStringField(project_obj, "name") orelse "(unknown)",
        .slug = common.getStringField(project_obj, "slugId") orelse "",
        .description = common.getStringField(project_obj, "description"),
        .state = common.getStringField(project_obj, "state") orelse "",
        .start_date = common.getStringField(project_obj, "startDate"),
        .target_date = common.getStringField(project_obj, "targetDate"),
        .url = common.getStringField(project_obj, "url") orelse "",
        .lead = if (include_lead) blk: {
            if (common.getObjectField(project_obj, "lead")) |lead_obj| break :blk common.getStringField(lead_obj, "name");
            break :blk null;
        } else null,
        .teams = if (include_teams) try parseTeams(ctx.allocator, project_obj, &owned_values) else null,
        .issues = if (include_issues) try parseIssues(ctx.allocator, project_obj, &owned_values) else null,
    };

    var display_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer display_pairs.deinit(ctx.allocator);

    var issues_truncated = false;
    if (include_issues) {
        if (common.getObjectField(project_obj, "issues")) |issues_obj| {
            if (common.getObjectField(issues_obj, "pageInfo")) |page_info| {
                issues_truncated = common.getBoolField(page_info, "hasNextPage") orelse false;
            }
        }
    }

    for (selected_fields) |field| {
        switch (field) {
            .id => try appendPair(&display_pairs, ctx.allocator, "ID", base_values.id),
            .name => try appendPair(&display_pairs, ctx.allocator, "Name", base_values.name),
            .slug => if (base_values.slug.len > 0) try appendPair(&display_pairs, ctx.allocator, "Slug", base_values.slug),
            .description => if (base_values.description) |desc| try appendPair(&display_pairs, ctx.allocator, "Description", desc),
            .state => try appendPair(&display_pairs, ctx.allocator, "State", base_values.state),
            .start_date => if (base_values.start_date) |start_value|
                try appendPair(&display_pairs, ctx.allocator, "Start", start_value),
            .target_date => if (base_values.target_date) |target_value|
                try appendPair(&display_pairs, ctx.allocator, "Target", target_value),
            .url => if (base_values.url.len > 0) try appendPair(&display_pairs, ctx.allocator, "URL", base_values.url),
            .lead => if (base_values.lead) |lead_value| try appendPair(&display_pairs, ctx.allocator, "Lead", lead_value),
            .teams => if (base_values.teams) |teams_value| try appendPair(&display_pairs, ctx.allocator, "Teams", teams_value),
            .issues => if (base_values.issues) |issues_value| try appendPair(&display_pairs, ctx.allocator, "Issues", issues_value),
        }
    }

    var out_buf: [0]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try printer.printKeyValues(&out_writer.interface, display_pairs.items);

    if (issues_truncated and include_issues) {
        try stderr.print("project view: issues limited to {d}; additional issues omitted\n", .{opts.issue_limit});
    }

    return 0;
}

fn parseTeams(allocator: Allocator, project_obj: std.json.Value, owned: *std.ArrayListUnmanaged([]u8)) !?[]const u8 {
    const teams_obj = common.getObjectField(project_obj, "teams") orelse return null;
    const nodes = common.getArrayField(teams_obj, "nodes") orelse return null;
    var joined = std.ArrayListUnmanaged(u8).empty;
    defer joined.deinit(allocator);
    var added: usize = 0;
    for (nodes.items) |team| {
        if (team != .object) continue;
        const key = common.getStringField(team, "key") orelse "";
        const name = common.getStringField(team, "name") orelse "";
        if (key.len == 0 and name.len == 0) continue;
        if (added > 0) try joined.appendSlice(allocator, ", ");
        if (key.len > 0) {
            try joined.appendSlice(allocator, key);
            if (name.len > 0) {
                try joined.appendSlice(allocator, " (");
                try joined.appendSlice(allocator, name);
                try joined.appendSlice(allocator, ")");
            }
        } else {
            try joined.appendSlice(allocator, name);
        }
        added += 1;
    }
    if (added == 0) return null;
    const owned_value = try joined.toOwnedSlice(allocator);
    try owned.append(allocator, owned_value);
    return owned_value;
}

fn parseIssues(allocator: Allocator, project_obj: std.json.Value, owned: *std.ArrayListUnmanaged([]u8)) !?[]const u8 {
    const issues_obj = common.getObjectField(project_obj, "issues") orelse return null;
    const nodes = common.getArrayField(issues_obj, "nodes") orelse return null;
    var joined = std.ArrayListUnmanaged(u8).empty;
    defer joined.deinit(allocator);
    var added: usize = 0;
    for (nodes.items) |issue| {
        if (issue != .object) continue;
        const ident = common.getStringField(issue, "identifier") orelse continue;
        const title = common.getStringField(issue, "title") orelse "";
        if (added > 0) try joined.appendSlice(allocator, ", ");
        try joined.appendSlice(allocator, ident);
        if (title.len > 0) {
            try joined.appendSlice(allocator, " ");
            try joined.appendSlice(allocator, title);
        }
        added += 1;
    }
    if (added == 0) return null;
    const owned_value = try joined.toOwnedSlice(allocator);
    try owned.append(allocator, owned_value);
    return owned_value;
}

fn parseFields(raw: ?[]const u8, buffer: *std.ArrayListUnmanaged(Field), allocator: Allocator) ![]const Field {
    if (raw) |value| {
        var iter = std.mem.tokenizeScalar(u8, value, ',');
        while (iter.next()) |field_raw| {
            const trimmed = std.mem.trim(u8, field_raw, " \t");
            if (trimmed.len == 0) continue;
            const field = parseFieldName(trimmed) orelse return error.InvalidFieldList;
            if (!containsField(buffer.items, field)) {
                try buffer.append(allocator, field);
            }
        }
        if (buffer.items.len == 0) return error.InvalidFieldList;
        return buffer.items;
    }
    return default_fields[0..];
}

fn parseFieldName(name: []const u8) ?Field {
    if (std.ascii.eqlIgnoreCase(name, "id")) return .id;
    if (std.ascii.eqlIgnoreCase(name, "name")) return .name;
    if (std.ascii.eqlIgnoreCase(name, "slug") or std.ascii.eqlIgnoreCase(name, "slugId")) return .slug;
    if (std.ascii.eqlIgnoreCase(name, "description")) return .description;
    if (std.ascii.eqlIgnoreCase(name, "state")) return .state;
    if (std.ascii.eqlIgnoreCase(name, "start_date") or std.ascii.eqlIgnoreCase(name, "startDate")) return .start_date;
    if (std.ascii.eqlIgnoreCase(name, "target_date") or std.ascii.eqlIgnoreCase(name, "targetDate")) return .target_date;
    if (std.ascii.eqlIgnoreCase(name, "url")) return .url;
    if (std.ascii.eqlIgnoreCase(name, "lead")) return .lead;
    if (std.ascii.eqlIgnoreCase(name, "teams")) return .teams;
    if (std.ascii.eqlIgnoreCase(name, "issues")) return .issues;
    return null;
}

fn containsField(haystack: []const Field, needle: Field) bool {
    for (haystack) |entry| {
        if (entry == needle) return true;
    }
    return false;
}

fn appendPair(list: *std.ArrayListUnmanaged(printer.KeyValue), allocator: Allocator, key: []const u8, value: []const u8) !void {
    try list.append(allocator, .{ .key = key, .value = value });
}

pub fn parseOptions(args: [][]const u8) !Options {
    var opts = Options{};
    var idx: usize = 0;
    while (idx < args.len) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
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
        if (std.mem.eql(u8, arg, "--issue-limit")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.issue_limit = parseLimit(args[idx + 1]) catch return error.InvalidLimit;
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--issue-limit=")) {
            opts.issue_limit = parseLimit(arg["--issue-limit=".len..]) catch return error.InvalidLimit;
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
    return opts;
}

fn parseLimit(raw: []const u8) !usize {
    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidLimit;
    if (value < 0) return error.InvalidLimit;
    return std.math.cast(usize, value) orelse error.InvalidLimit;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear project view <ID> [--fields LIST] [--issue-limit N] [--help]
        \\Flags:
        \\  --fields LIST     Comma-separated fields (id,name,slug,description,state,start_date,target_date,url,lead,teams,issues)
        \\  --issue-limit N   Issues to fetch when the issues field is requested (0 disables; default: 10)
        \\  --help            Show this help message
        \\Examples:
        \\  linear project view a6e7e3aa-53d0-42ab-9049-ac7aaa51f732
        \\  linear project view 0949c8955675 --fields name,state,issues --issue-limit 5
        \\
    , .{});
}
