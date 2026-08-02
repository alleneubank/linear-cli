const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_endpoint = "https://api.linear.app/graphql";
pub const allowed_endpoint_host = "api.linear.app";
pub const allow_insecure_endpoint_env = "LINEAR_ALLOW_INSECURE_ENDPOINT";

pub const EndpointError = error{
    InvalidEndpointUrl,
    InsecureEndpointScheme,
    EndpointHostNotAllowed,
};

/// Every request carries the Authorization header, so the endpoint is checked
/// against the allowlist before a connection is opened. `LINEAR_ALLOW_INSECURE_ENDPOINT=1`
/// relaxes the check for the mock/QA workflow only.
pub fn validateEndpoint(endpoint: []const u8, allow_insecure: bool) EndpointError!void {
    const uri = std.Uri.parse(endpoint) catch return EndpointError.InvalidEndpointUrl;
    const host_component = uri.host orelse return EndpointError.InvalidEndpointUrl;
    const host = switch (host_component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    if (host.len == 0) return EndpointError.InvalidEndpointUrl;

    if (allow_insecure) return;

    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return EndpointError.InsecureEndpointScheme;
    if (!std.ascii.eqlIgnoreCase(host, allowed_endpoint_host)) return EndpointError.EndpointHostNotAllowed;
}

pub fn endpointErrorMessage(err: EndpointError) []const u8 {
    return switch (err) {
        EndpointError.InvalidEndpointUrl => "endpoint must be an absolute URL with a host",
        EndpointError.InsecureEndpointScheme => "endpoint must use https; set " ++ allow_insecure_endpoint_env ++ "=1 to allow other schemes",
        EndpointError.EndpointHostNotAllowed => "endpoint host must be " ++ allowed_endpoint_host ++ "; set " ++ allow_insecure_endpoint_env ++ "=1 to allow other hosts",
    };
}

pub fn setAllowInsecureEndpoint(enabled: bool) void {
    allow_insecure_endpoint_preference.store(enabled, .release);
}

pub fn getAllowInsecureEndpoint() bool {
    return allow_insecure_endpoint_preference.load(.acquire);
}

pub const GraphqlClient = struct {
    allocator: Allocator,
    io: std.Io,
    api_key: []const u8,
    endpoint: []const u8 = default_endpoint,
    http_client: *std.http.Client,
    keep_alive: bool,
    allow_insecure_endpoint: bool,
    timeout_ms: u32 = 10_000,
    max_retries: u8 = 0,

    pub const Options = struct {
        keep_alive: ?bool = null,
        allow_insecure_endpoint: ?bool = null,
    };

    pub const Error = error{RequestTimedOut};

    pub const RateLimitInfo = struct {
        limit: ?u32 = null,
        remaining: ?u32 = null,
        retry_after_ms: ?u32 = null,
        reset_epoch_ms: ?u64 = null,

        pub fn hasData(self: RateLimitInfo) bool {
            return self.limit != null or self.remaining != null or self.retry_after_ms != null or self.reset_epoch_ms != null;
        }
    };

    pub fn init(allocator: Allocator, io: std.Io, api_key: []const u8) GraphqlClient {
        return initWithOptions(allocator, io, api_key, .{});
    }

    pub fn initWithOptions(allocator: Allocator, io: std.Io, api_key: []const u8, options: Options) GraphqlClient {
        const http_client = shared_client.acquire(allocator, io);
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .http_client = http_client,
            .keep_alive = options.keep_alive orelse keep_alive_preference.load(.acquire),
            .allow_insecure_endpoint = options.allow_insecure_endpoint orelse allow_insecure_endpoint_preference.load(.acquire),
        };
    }

    pub fn deinit(self: *GraphqlClient) void {
        shared_client.release(self.io);
    }

    pub const Request = struct {
        query: []const u8,
        variables: ?std.json.Value = null,
        operation_name: ?[]const u8 = null,
    };

    pub const Response = struct {
        status: u16,
        parsed: std.json.Parsed(std.json.Value),
        rate_limit: RateLimitInfo = .{},

        pub fn data(self: *const Response) ?std.json.Value {
            if (self.parsed.value != .object) return null;
            return self.parsed.value.object.get("data");
        }

        pub fn errors(self: *const Response) ?std.json.Value {
            if (self.parsed.value != .object) return null;
            return self.parsed.value.object.get("errors");
        }

        pub fn hasGraphqlErrors(self: *const Response) bool {
            if (self.errors()) |errs| {
                switch (errs) {
                    .array => |arr| return arr.items.len > 0,
                    .null => return false,
                    else => return true,
                }
            }
            return false;
        }

        pub fn firstErrorMessage(self: *const Response) ?[]const u8 {
            const errs = self.errors() orelse return null;
            switch (errs) {
                .array => |arr| {
                    for (arr.items) |item| {
                        if (item != .object) continue;
                        if (item.object.get("message")) |msg| {
                            if (msg == .string) return msg.string;
                        }
                    }
                },
                else => {},
            }
            return null;
        }

        pub fn isSuccessStatus(self: *const Response) bool {
            return self.status >= 200 and self.status < 300;
        }

        pub fn deinit(self: *Response) void {
            self.parsed.deinit();
        }
    };

    pub fn send(self: *GraphqlClient, allocator: Allocator, req: Request) !Response {
        const payload_bytes = try buildPayload(allocator, req);
        defer allocator.free(payload_bytes);

        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.Io.Clock.real.now(self.io).toNanoseconds())));
        var random = prng.random();
        var rate_limit: RateLimitInfo = .{};

        const start_ms: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
        const deadline_ms = start_ms + @as(i64, @intCast(self.timeout_ms));

        var attempt: u8 = 0;
        const max_attempts: u8 = self.max_retries + 1;
        while (true) : (attempt += 1) {
            response_writer.clearRetainingCapacity();

            if (std.Io.Clock.real.now(self.io).toMilliseconds() >= deadline_ms) return Error.RequestTimedOut;

            const attempt_result = try performRequest(self, payload_bytes, &response_writer.writer);
            rate_limit = attempt_result.rate_limit;
            const status_code: u16 = attempt_result.status;

            const after_ms: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
            if (after_ms >= deadline_ms) return Error.RequestTimedOut;

            const can_retry = shouldRetry(status_code) and attempt + 1 < max_attempts;
            if (can_retry) {
                const remaining_ms = deadline_ms - after_ms;
                const delay_ms = computeDelayMs(attempt, rate_limit, remaining_ms, &random) orelse return Error.RequestTimedOut;
                logRetry(self.io, status_code, attempt + 2, max_attempts, delay_ms);
                try self.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
                continue;
            }

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_writer.writer.buffered(), .{});
            mergeRateLimitFromBody(parsed.value, &rate_limit);
            return .{
                .status = status_code,
                .parsed = parsed,
                .rate_limit = rate_limit,
            };
        }
    }
};

pub fn setDefaultKeepAlive(enabled: bool) void {
    keep_alive_preference.store(enabled, .release);
}

pub fn getDefaultKeepAlive() bool {
    return keep_alive_preference.load(.acquire);
}

pub fn deinitSharedClient(io: std.Io) void {
    shared_client.shutdown(io);
}

const SharedHttpClient = struct {
    mutex: std.Io.Mutex = .init,
    ref_count: usize = 0,
    client: ?std.http.Client = null,

    fn acquire(self: *SharedHttpClient, allocator: Allocator, io: std.Io) *std.http.Client {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.client == null) {
            self.client = std.http.Client{ .allocator = allocator, .io = io };
        }
        markTlsRefresh(&self.client.?);
        self.ref_count += 1;
        return &self.client.?;
    }

    fn release(self: *SharedHttpClient, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.client == null) return;
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
    }

    fn shutdown(self: *SharedHttpClient, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.client == null) return;
        std.debug.assert(self.ref_count == 0);
        self.client.?.deinit();
        self.client = null;
    }
};

var shared_client: SharedHttpClient = .{};
var keep_alive_preference = std.atomic.Value(bool).init(true);
var allow_insecure_endpoint_preference = std.atomic.Value(bool).init(false);

/// Clearing `now` makes the next HTTPS request re-check the clock and rescan
/// the system root certificates. Callers must hold `SharedHttpClient.mutex`.
fn markTlsRefresh(client: *std.http.Client) void {
    client.now = null;
}

fn buildPayload(allocator: Allocator, req: GraphqlClient.Request) ![]u8 {
    const Payload = struct {
        query: []const u8,
        variables: ?std.json.Value = null,
        operationName: ?[]const u8 = null,
    };

    const payload = Payload{
        .query = req.query,
        .variables = req.variables,
        .operationName = req.operation_name,
    };

    return std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .minified });
}

const AttemptResult = struct {
    status: u16,
    rate_limit: GraphqlClient.RateLimitInfo,
};

fn performRequest(
    client: *GraphqlClient,
    payload_bytes: []const u8,
    response_writer: *std.Io.Writer,
) !AttemptResult {
    // Last gate before the Authorization header goes on the wire.
    try validateEndpoint(client.endpoint, client.allow_insecure_endpoint);

    var req = try client.http_client.request(.POST, std.Uri.parse(client.endpoint) catch return error.InvalidEndpoint, .{
        .redirect_behavior = .unhandled,
        .keep_alive = client.keep_alive,
        .headers = .{
            .authorization = .{ .override = client.api_key },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{.{
            .name = "Accept",
            .value = "application/json",
        }},
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload_bytes.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload_bytes);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    const rate_limit = parseRateLimitFromHeaders(response.head.bytes);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer switch (response.head.content_encoding) {
        .identity => {},
        else => client.allocator.free(decompress_buffer),
    };

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{
        .status = @intFromEnum(response.head.status),
        .rate_limit = rate_limit,
    };
}

fn shouldRetry(status_code: u16) bool {
    return status_code == 429 or status_code >= 500;
}

fn computeDelayMs(
    attempt: u8,
    rate_limit: GraphqlClient.RateLimitInfo,
    remaining_ms: i64,
    random: *std.Random,
) ?u64 {
    if (remaining_ms <= 0) return null;

    if (rate_limit.retry_after_ms) |retry_after| {
        const jitter = random.uintLessThan(u64, 100);
        const delay = @as(u64, retry_after) + jitter;
        if (delay == 0) return 1;
        if (delay > @as(u64, @intCast(remaining_ms))) return null;
        return delay;
    }

    const base_ms: u64 = 200;
    const capped_attempt: u8 = @min(attempt, 10);
    var backoff_ms: u64 = base_ms * (@as(u64, 1) << @intCast(capped_attempt));
    backoff_ms = @min(backoff_ms, 5_000);
    const jitter = random.uintLessThan(u64, backoff_ms / 2 + 1);
    const delay_ms = backoff_ms / 2 + jitter;
    if (delay_ms == 0) return 1;
    if (delay_ms > @as(u64, @intCast(remaining_ms))) return null;
    return delay_ms;
}

fn logRetry(io: std.Io, status_code: u16, attempt_number: u8, max_attempts: u8, delay_ms: u64) void {
    var stderr_buf: [0]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    stderr.print(
        "graphql: retrying after HTTP {d} (attempt {d}/{d}) in {d}ms\n",
        .{ status_code, attempt_number, max_attempts, delay_ms },
    ) catch {};
}

fn parseRateLimitFromHeaders(head_bytes: []const u8) GraphqlClient.RateLimitInfo {
    var info: GraphqlClient.RateLimitInfo = .{};
    var it = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = it.next(); // status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon_index], " \t");
        const value = std.mem.trim(u8, line[colon_index + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            if (parseRetryAfterMs(value)) |retry_after| {
                info.retry_after_ms = retry_after;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining")) {
            if (parseHeaderInt(value)) |remaining| info.remaining = std.math.cast(u32, remaining) orelse std.math.maxInt(u32);
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-limit")) {
            if (parseHeaderInt(value)) |limit| info.limit = std.math.cast(u32, limit) orelse std.math.maxInt(u32);
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset")) {
            if (parseHeaderInt(value)) |reset_epoch| {
                info.reset_epoch_ms = reset_epoch * 1000;
            }
        }
    }
    return info;
}

fn parseRetryAfterMs(value: []const u8) ?u32 {
    const seconds = parseHeaderInt(value) orelse return null;
    const ms: u64 = @min(seconds * 1000, @as(u64, std.math.maxInt(u32)));
    return @intCast(ms);
}

fn parseHeaderInt(value: []const u8) ?u64 {
    return std.fmt.parseInt(u64, value, 10) catch null;
}

fn mergeRateLimitFromBody(body: std.json.Value, info: *GraphqlClient.RateLimitInfo) void {
    if (body != .object) return;
    if (body.object.get("errors")) |errs| {
        if (errs != .array) return;
        for (errs.array.items) |item| {
            if (item != .object) continue;
            if (item.object.get("extensions")) |ext| {
                if (ext != .object) continue;
                if (ext.object.get("rateLimit")) |rate_limit_value| {
                    parseRateLimitValue(rate_limit_value, info);
                    return;
                }
            }
        }
    }
}

fn parseRateLimitValue(value: std.json.Value, info: *GraphqlClient.RateLimitInfo) void {
    if (value != .object) return;
    const obj = value.object;
    if (info.limit == null) {
        if (obj.get("limit")) |limit_value| {
            if (limit_value == .integer and limit_value.integer >= 0) info.limit = std.math.cast(u32, @as(u64, @intCast(limit_value.integer))) orelse std.math.maxInt(u32);
        }
    }
    if (info.remaining == null) {
        if (obj.get("remaining")) |remaining_value| {
            if (remaining_value == .integer and remaining_value.integer >= 0) info.remaining = std.math.cast(u32, @as(u64, @intCast(remaining_value.integer))) orelse std.math.maxInt(u32);
        }
    }
    if (info.retry_after_ms == null) {
        if (obj.get("retryAfter")) |retry_value| {
            switch (retry_value) {
                .integer => |val| {
                    if (val >= 0) {
                        const clamped: u64 = @min(@as(u64, @intCast(val)), @as(u64, std.math.maxInt(u32)));
                        info.retry_after_ms = @intCast(clamped);
                    }
                },
                else => {},
            }
        }
    }
}

test "parseRateLimitFromHeaders extracts values" {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Retry-After: 2\r\n" ++
        "X-RateLimit-Remaining: 5\r\n" ++
        "X-RateLimit-Limit: 10\r\n" ++
        "X-RateLimit-Reset: 123\r\n\r\n";
    const info = parseRateLimitFromHeaders(headers);
    try std.testing.expectEqual(@as(u32, 5), info.remaining.?);
    try std.testing.expectEqual(@as(u32, 10), info.limit.?);
    try std.testing.expectEqual(@as(u32, 2000), info.retry_after_ms.?);
    try std.testing.expectEqual(@as(u64, 123000), info.reset_epoch_ms.?);
}

test "computeDelayMs honors retry-after and budget" {
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    const delay = computeDelayMs(0, .{ .retry_after_ms = 50 }, 1000, &random) orelse return error.TestExpectedResult;
    try std.testing.expect(delay >= 50);
    try std.testing.expect(delay <= 150);
}
