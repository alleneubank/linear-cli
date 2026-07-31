//! `linear issue delete` — archives one issue, or a batch of them via the
//! shared serial executor in `bulk.zig`.
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

const Options = struct {
    target: ?[]const u8 = null,
    quiet: bool = false,
    data_only: bool = false,
    yes: bool = false,
    dry_run: bool = false,
    reason: ?[]const u8 = null,
    bulk: bulk.Options = .{},
    help: bool = false,
};

/// Everything one item of the run needs. The writers and the `emitted` counter
/// are shared across the batch, which is what lets the JSON path emit a single
/// array instead of a stream of unrelated documents.
const ItemState = struct {
    ctx: Context,
    opts: Options,
    client: *graphql.GraphqlClient,
    api_key: []const u8,
    reason: ?[]const u8,
    stderr: *std.Io.Writer,
    stdout: *std.Io.Writer,
    json_stream: bool,
    emitted: *usize,

    fn emitJson(self: ItemState, value: std.json.Value) !void {
        if (self.json_stream and self.emitted.* > 0) try self.stdout.writeAll(",");
        try printer.printJson(value, self.stdout, true);
        self.emitted.* += 1;
    }
};

pub fn run(ctx: Context) !u8 {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    var stderr = &stderr_writer.interface;
    const opts = parseOptions(ctx.args) catch |err| {
        try stderr.print("issue delete: {s}\n", .{@errorName(err)});
        try usage(stderr);
        return 1;
    };

    if (opts.help) {
        var out_buf: [0]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(ctx.io, &out_buf);
        try usage(&out_writer.interface);
        return 0;
    }

    // Resolved before any network work so a bad path or an empty list fails
    // without touching the API.
    var bulk_targets = bulk.collect(ctx.allocator, ctx.io, opts.bulk, stderr, "issue delete") catch {
        return 1;
    };
    defer if (bulk_targets) |*targets| targets.deinit();

    if (bulk_targets != null and opts.target != null) {
        try stderr.print("issue delete: pass an identifier or --bulk, not both\n", .{});
        return 1;
    }

    var single_target: [1][]const u8 = undefined;
    const targets: []const []const u8 = if (bulk_targets) |resolved| resolved.items else blk: {
        single_target[0] = opts.target orelse {
            try stderr.print("issue delete: missing identifier or id\n", .{});
            return 1;
        };
        break :blk single_target[0..];
    };

    const api_key = common.requireApiKey(ctx.config, null, stderr, "issue delete") catch {
        return 1;
    };
    const reason = if (opts.reason) |raw_reason| blk: {
        const trimmed = std.mem.trim(u8, raw_reason, " \t");
        if (trimmed.len == 0) {
            try stderr.print("issue delete: invalid --reason value\n", .{});
            return 1;
        }
        break :blk trimmed;
    } else null;

    // A dry run sends no mutation, so it stays usable without `--yes`.
    if (!opts.dry_run and !opts.yes) {
        try stderr.print("issue delete: confirmation required; re-run with --yes to proceed\n", .{});
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
    // `--quiet` beats `--json` on the mutation path but not on the dry-run
    // path, so the wrapper has to mirror the per-item output rules exactly.
    const emits_json = if (opts.dry_run) ctx.json_output else (ctx.json_output and !opts.quiet);
    const json_stream = bulk_mode and emits_json;

    var emitted: usize = 0;
    const state = ItemState{
        .ctx = ctx,
        .opts = opts,
        .client = &client,
        .api_key = api_key,
        .reason = reason,
        .stderr = stderr,
        .stdout = stdout_iface,
        .json_stream = json_stream,
        .emitted = &emitted,
    };

    if (json_stream) try stdout_iface.writeAll("[\n");
    const summary = try bulk.execute(ItemState, state, targets, deleteOne);
    if (json_stream) try stdout_iface.writeAll("]\n");

    if (bulk_mode and !ctx.json_output) {
        try bulk.printSummary(stderr, "issue delete", summary);
    }

    return summary.exitCode();
}

fn deleteOne(state: ItemState, index: usize, target: []const u8) !bulk.Outcome {
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
            \\query IssueDeleteLookup($id: String!) {
            \\  issue(id: $id) {
            \\    id
            \\    identifier
            \\    title
            \\  }
            \\}
        ;

        var lookup_response = common.send(ctx.allocator, "issue delete", state.client, .{
            .query = lookup_query,
            .variables = variables,
            .operation_name = "IssueDeleteLookup",
        }, stderr) catch {
            return .failed;
        };
        defer lookup_response.deinit();

        common.checkResponse(ctx.io, "issue delete", &lookup_response, stderr, state.api_key) catch {
            return .failed;
        };

        const data_value = lookup_response.data() orelse {
            try stderr.print("issue delete: response missing data\n", .{});
            return .failed;
        };
        const issue_obj = common.getObjectField(data_value, "issue") orelse {
            try stderr.print("issue delete: issue not found\n", .{});
            return .failed;
        };

        const resolved_identifier = common.getStringField(issue_obj, "identifier") orelse target;
        const resolved_id = common.getStringField(issue_obj, "id") orelse target;
        const resolved_title = common.getStringField(issue_obj, "title");

        const dry_data_pairs = [_]printer.KeyValue{
            .{ .key = "identifier", .value = resolved_identifier },
            .{ .key = "id", .value = resolved_id },
            .{ .key = "dry_run", .value = "true" },
        };

        if (ctx.json_output) {
            var obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try obj.object.put(var_alloc, "identifier", .{ .string = resolved_identifier });
            try obj.object.put(var_alloc, "id", .{ .string = resolved_id });
            if (resolved_title) |title_value| try obj.object.put(var_alloc, "title", .{ .string = title_value });
            try obj.object.put(var_alloc, "dry_run", .{ .bool = true });
            if (state.reason) |reason_value| try obj.object.put(var_alloc, "reason", .{ .string = reason_value });
            try state.emitJson(obj);
            return .succeeded;
        }

        if (opts.data_only) {
            var data_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
            defer data_pairs.deinit(ctx.allocator);
            try data_pairs.appendSlice(ctx.allocator, dry_data_pairs[0..]);
            if (resolved_title) |title_value| try data_pairs.append(ctx.allocator, .{ .key = "title", .value = title_value });
            if (state.reason) |reason_value| try data_pairs.append(ctx.allocator, .{ .key = "reason", .value = reason_value });
            try printer.printKeyValuesPlain(stdout_iface, data_pairs.items);
            return .succeeded;
        }

        if (opts.quiet) {
            try stdout_iface.print("issue delete: dry run; {s}\n", .{resolved_identifier});
            return .succeeded;
        }

        try stdout_iface.print("issue delete: dry run; would delete {s} (id {s})", .{ resolved_identifier, resolved_id });
        if (resolved_title) |title_value| try stdout_iface.print(" title \"{s}\"", .{title_value});
        if (state.reason) |reason_value| try stdout_iface.print(" reason: {s}", .{reason_value});
        try stdout_iface.writeByte('\n');
        return .succeeded;
    }

    const mutation =
        \\mutation IssueDelete($id: String!) {
        \\  issueDelete(id: $id) {
        \\    success
        \\    entity { id identifier }
        \\    lastSyncId
        \\  }
        \\}
    ;

    var response = common.send(ctx.allocator, "issue delete", state.client, .{
        .query = mutation,
        .variables = variables,
        .operation_name = "IssueDelete",
    }, stderr) catch {
        return .failed;
    };
    defer response.deinit();

    common.checkResponse(ctx.io, "issue delete", &response, stderr, state.api_key) catch {
        return .failed;
    };

    const data_value = response.data() orelse {
        try stderr.print("issue delete: response missing data\n", .{});
        return .failed;
    };

    const payload = common.getObjectField(data_value, "issueDelete") orelse {
        try stderr.print("issue delete: issueDelete missing in response\n", .{});
        return .failed;
    };

    const success = common.getBoolField(payload, "success") orelse false;
    const issue_obj = common.getObjectField(payload, "entity");

    if (!success) {
        if (issue_obj) |issue| {
            if (common.getStringField(issue, "identifier")) |identifier| {
                try stderr.print("issue delete: delete failed for {s}\n", .{identifier});
                return .failed;
            }
        }
        try stderr.print("issue delete: request failed\n", .{});
        return .failed;
    }

    if (ctx.json_output and !opts.quiet and !opts.data_only) {
        if (state.reason) |reason_value| {
            var root_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            try root_obj.object.put(var_alloc, "response", data_value);
            try root_obj.object.put(var_alloc, "reason", .{ .string = reason_value });
            try state.emitJson(root_obj);
        } else {
            try state.emitJson(data_value);
        }
        return .succeeded;
    }

    const identifier = if (issue_obj) |issue|
        common.getStringField(issue, "identifier") orelse target
    else
        target;
    const id_value = if (issue_obj) |issue|
        common.getStringField(issue, "id") orelse "(unknown)"
    else
        "(unknown)";

    var pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer pairs.deinit(ctx.allocator);
    var data_pairs = std.ArrayListUnmanaged(printer.KeyValue).empty;
    defer data_pairs.deinit(ctx.allocator);
    try pairs.appendSlice(ctx.allocator, &[_]printer.KeyValue{
        .{ .key = "Identifier", .value = identifier },
        .{ .key = "ID", .value = id_value },
    });
    try data_pairs.appendSlice(ctx.allocator, &[_]printer.KeyValue{
        .{ .key = "identifier", .value = identifier },
        .{ .key = "id", .value = id_value },
    });
    if (state.reason) |reason_value| {
        try pairs.append(ctx.allocator, .{ .key = "Reason", .value = reason_value });
        try data_pairs.append(ctx.allocator, .{ .key = "reason", .value = reason_value });
    }

    if (opts.quiet) {
        try stdout_iface.writeAll(identifier);
        try stdout_iface.writeByte('\n');
        return .succeeded;
    }

    if (opts.data_only) {
        if (ctx.json_output) {
            var data_obj = std.json.Value{ .object = std.json.ObjectMap.empty };
            for (data_pairs.items) |pair| {
                try data_obj.object.put(var_alloc, pair.key, .{ .string = pair.value });
            }
            try state.emitJson(data_obj);
            return .succeeded;
        }

        try printer.printKeyValuesPlain(stdout_iface, data_pairs.items);
        return .succeeded;
    }

    try printer.printKeyValues(stdout_iface, pairs.items);
    return .succeeded;
}

fn parseOptions(args: []const []const u8) !Options {
    var opts = Options{};
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
        if (std.mem.eql(u8, arg, "--reason")) {
            if (idx + 1 >= args.len) return error.MissingValue;
            opts.reason = args[idx + 1];
            idx += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--reason=")) {
            opts.reason = arg["--reason=".len..];
            idx += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownFlag;
        if (opts.target == null) {
            opts.target = arg;
            idx += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return opts;
}

pub fn usage(writer: anytype) !void {
    try writer.print(
        \\Usage: linear issue delete <ID|IDENTIFIER> [--quiet] [--data-only] [--yes] [--dry-run] [--reason TEXT] [--help]
        \\       linear issue delete --bulk ID,ID | --bulk-file PATH | --bulk-stdin [--yes] [--dry-run] [...]
        \\Flags:
        \\  --quiet          Print only the identifier
        \\  --data-only      Emit tab-separated fields without formatting (or JSON object with --json)
        \\  --yes            Skip confirmation prompt (useful for scripts; alias: --force)
        \\  --dry-run        Resolve and validate the issue without deleting; prints the target and exits 0
        \\  --reason TEXT    Attach a reason (echoed in output; for audit logging)
        \\  --bulk ID,ID     Delete several issues in one serial run (ids are deduplicated)
        \\  --bulk-file PATH Read bulk ids from a file, one per line or comma separated ('-' for stdin)
        \\  --bulk-stdin     Read bulk ids from stdin
        \\  --help           Show this help message
        \\Bulk runs keep going after a failed item, print a succeeded/failed summary on
        \\stderr (suppressed with --json), and exit non-zero when any item failed.
        \\Examples:
        \\  linear issue delete ENG-123
        \\  linear issue delete 12345 --quiet
        \\  linear issue delete --bulk ENG-1,ENG-2 --yes --quiet
        \\  linear issues list --team ENG --quiet | linear issue delete --bulk-stdin --dry-run
        \\
    , .{});
}
