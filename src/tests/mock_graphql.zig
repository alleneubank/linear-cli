const std = @import("std");
const Allocator = std.mem.Allocator;

const RateLimitInfoInternal = struct {
    remaining: ?u32 = null,
    limit: ?u32 = null,
    retry_after_ms: ?u32 = null,
    reset_epoch_ms: ?u64 = null,

    pub fn hasData(self: RateLimitInfoInternal) bool {
        return self.remaining != null or self.limit != null or self.retry_after_ms != null or self.reset_epoch_ms != null;
    }
};

pub const MockResponse = struct {
    body: []const u8,
    status: u16 = 200,
    rate_limit: RateLimitInfoInternal = .{},
};

const ResponseSeries = struct {
    allocator: Allocator,
    responses: std.ArrayListUnmanaged(MockResponse),
    next: usize = 0,

    fn deinit(self: ResponseSeries) void {
        for (self.responses.items) |resp| {
            self.allocator.free(resp.body);
        }
        var list = self.responses;
        list.deinit(self.allocator);
    }

    fn take(self: *ResponseSeries) MockResponse {
        const idx = @min(self.next, self.responses.items.len - 1);
        const resp = self.responses.items[idx];
        if (self.next + 1 < self.responses.items.len) {
            self.next += 1;
        }
        return resp;
    }
};

pub const MockServer = struct {
    allocator: Allocator,
    fixtures: std.StringHashMap(ResponseSeries),
    last_request: ?CapturedRequest = null,
    /// Number of `send` calls this server has served. Tests that care about how
    /// many requests a command made — bulk dedupe, pagination page counts —
    /// assert on this rather than inferring it from the output.
    request_count: usize = 0,

    pub const CapturedRequest = struct {
        operation: []const u8,
        query: []const u8,
        variables_json: ?[]const u8 = null,
    };

    pub fn init(allocator: Allocator) MockServer {
        return .{
            .allocator = allocator,
            .fixtures = std.StringHashMap(ResponseSeries).init(allocator),
        };
    }

    pub fn deinit(self: *MockServer) void {
        self.clearLastRequest();
        var it = self.fixtures.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.fixtures.deinit();
    }

    pub fn set(self: *MockServer, operation: []const u8, payload: []const u8) !void {
        try self.setWithStatus(operation, payload, 200);
    }

    pub fn setWithStatus(self: *MockServer, operation: []const u8, payload: []const u8, status: u16) !void {
        const response = MockResponse{ .body = payload, .status = status };
        try self.setResponses(operation, &.{response});
    }

    pub fn setResponses(self: *MockServer, operation: []const u8, responses: []const MockResponse) !void {
        var list = std.ArrayListUnmanaged(MockResponse).empty;
        errdefer {
            for (list.items) |item| {
                self.allocator.free(item.body);
            }
            list.deinit(self.allocator);
        }

        for (responses) |resp| {
            const duped = try self.allocator.dupe(u8, resp.body);
            try list.append(self.allocator, .{ .body = duped, .status = resp.status, .rate_limit = resp.rate_limit });
        }

        const series = ResponseSeries{
            .allocator = self.allocator,
            .responses = list,
            .next = 0,
        };

        if (try self.fixtures.fetchPut(operation, series)) |previous| {
            previous.value.deinit();
        }
    }

    pub fn setSequence(self: *MockServer, operation: []const u8, payloads: []const []const u8) !void {
        var responses = try self.allocator.alloc(MockResponse, payloads.len);
        defer self.allocator.free(responses);
        for (payloads, 0..) |payload, idx| {
            responses[idx] = .{ .body = payload };
        }
        try self.setResponses(operation, responses);
    }

    fn lookup(self: *MockServer, operation: []const u8) ?MockResponse {
        if (self.fixtures.getPtr(operation)) |entry| {
            return entry.take();
        }
        return null;
    }

    fn clearLastRequest(self: *MockServer) void {
        if (self.last_request) |req| {
            self.allocator.free(req.operation);
            self.allocator.free(req.query);
            if (req.variables_json) |vars| self.allocator.free(vars);
            self.last_request = null;
        }
    }

    fn recordRequest(self: *MockServer, op_name: []const u8, query: []const u8, variables: ?std.json.Value) !void {
        self.clearLastRequest();
        const op_copy = try self.allocator.dupe(u8, op_name);
        errdefer self.allocator.free(op_copy);
        const query_copy = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(query_copy);

        var vars_copy: ?[]u8 = null;
        if (variables) |vars_value| {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();

            var jw = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
            try jw.write(vars_value);
            vars_copy = try self.allocator.dupe(u8, out.written());
        }

        self.last_request = .{
            .operation = op_copy,
            .query = query_copy,
            .variables_json = vars_copy,
        };
    }

    pub fn lastRequest(self: *MockServer) ?CapturedRequest {
        return self.last_request;
    }
};

threadlocal var active_server: ?*MockServer = null;

pub const ServerScope = struct {
    previous: ?*MockServer,

    pub fn restore(self: *ServerScope) void {
        active_server = self.previous;
    }
};

pub fn useServer(server: *MockServer) ServerScope {
    const previous = active_server;
    active_server = server;
    return .{ .previous = previous };
}

pub const GraphqlClient = struct {
    allocator: Allocator,
    io: std.Io,
    api_key: []const u8,
    endpoint: []const u8 = "https://api.linear.app/graphql",
    keep_alive: bool = true,
    timeout_ms: u32 = 10_000,
    max_retries: u8 = 0,
    server: ?*MockServer,

    pub const Error = error{ RequestTimedOut, MockServerNotInstalled, MissingOperationName, MissingFixture };

    pub const RateLimitInfo = RateLimitInfoInternal;

    pub const Request = struct {
        query: []const u8,
        variables: ?std.json.Value = null,
        operation_name: ?[]const u8 = null,
    };

    pub const Response = struct {
        status: u16,
        parsed: std.json.Parsed(std.json.Value),
        rate_limit: RateLimitInfoInternal = .{},

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

    pub fn init(allocator: Allocator, io: std.Io, api_key: []const u8) GraphqlClient {
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .server = active_server,
        };
    }

    pub fn deinit(self: *GraphqlClient) void {
        _ = self;
    }

    pub fn send(self: *GraphqlClient, allocator: Allocator, req: Request) !Response {
        const server = self.server orelse return Error.MockServerNotInstalled;
        server.request_count += 1;
        const op_name = req.operation_name orelse return Error.MissingOperationName;
        const fixture = server.lookup(op_name) orelse return Error.MissingFixture;
        try server.recordRequest(op_name, req.query, req.variables);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture.body, .{});
        return .{
            .status = fixture.status,
            .parsed = parsed,
            .rate_limit = fixture.rate_limit,
        };
    }
};

pub fn loadFixture(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
}
