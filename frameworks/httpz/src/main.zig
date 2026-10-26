const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");

const websocket = httpz.websocket;

pub const std_options: std.Options = .{ .log_scope_levels = &.{
    .{ .scope = .websocket, .level = .err },
} };

const Rating = struct { score: i64, count: i64 };

const DbItem = struct {
    id: i32,
    name: []const u8,
    category: []const u8,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const DbResponse = struct {
    items: []const DbItem,
    count: usize,
};

const empty_db_response: DbResponse = .{ .items = &.{}, .count = 0 };

const App = struct {
    pool: ?*pg.Pool,

    pub const WebsocketHandler = EchoClient;
};

const EchoClient = struct {
    conn: *websocket.Conn,

    pub fn init(conn: *websocket.Conn, _: void) !EchoClient {
        return .{ .conn = conn };
    }

    pub fn clientMessage(self: *EchoClient, data: []const u8, kind: websocket.MessageTextType) !void {
        switch (kind) {
            .text => try self.conn.writeText(data),
            .binary => try self.conn.writeBin(data),
        }
    }
};

fn baseline(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var sum: i64 = 0;
    var it = (try req.query()).iterator();
    while (it.next()) |kv| {
        sum += std.fmt.parseInt(i64, kv.value, 10) catch 0;
    }
    if (req.method == .POST) {
        if (req.body()) |b| {
            sum += std.fmt.parseInt(i64, b, 10) catch 0;
        }
    }
    res.content_type = .TEXT;
    try res.writer().print("{d}", .{sum});
}

fn pipeline(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .TEXT;
    res.body = "ok";
}

fn queryInt(comptime T: type, query: anytype, name: []const u8) ?T {
    const value = query.get(name) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn asyncDb(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const pool = app.pool orelse return res.json(empty_db_response, .{});

    const query = try req.query();
    const min = queryInt(i32, query, "min") orelse 10;
    const max = queryInt(i32, query, "max") orelse 50;
    const limit = std.math.clamp(queryInt(i32, query, "limit") orelse 50, 1, 50);

    const result = pool.queryOpts(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
        .{ min, max, limit },
        .{ .cache_name = "async_db" },
    ) catch |err| {
        std.log.err("async-db query: {}", .{err});
        return res.json(empty_db_response, .{});
    };
    defer result.deinit();

    var items: std.ArrayList(DbItem) = .empty;
    while (try result.next()) |row| {
        const tags_json = try row.get([]const u8, 6);
        const tags = std.json.parseFromSliceLeaky([]const []const u8, res.arena, tags_json, .{ .allocate = .alloc_always }) catch &.{};

        try items.append(res.arena, .{
            .id = try row.get(i32, 0),
            .name = try res.arena.dupe(u8, try row.get([]const u8, 1)),
            .category = try res.arena.dupe(u8, try row.get([]const u8, 2)),
            .price = try row.get(i32, 3),
            .quantity = try row.get(i32, 4),
            .active = try row.get(bool, 5),
            .tags = tags,
            .rating = .{
                .score = try row.get(i32, 7),
                .count = try row.get(i32, 8),
            },
        });
    }

    try res.json(DbResponse{ .items = items.items, .count = items.items.len }, .{});
}

fn wsEcho(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (try httpz.upgradeWebsocket(EchoClient, req, res, {}) == false) {
        res.status = 400;
        res.body = "invalid websocket handshake";
    }
}

fn envCount(env: *std.process.Environ.Map, name: []const u8) ?u16 {
    const value = env.get(name) orelse return null;
    return std.fmt.parseInt(u16, value, 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var app: App = .{ .pool = null };
    if (init.environ_map.get("DATABASE_URL")) |url| {
        const uri = std.Uri.parse(url) catch @panic("invalid DATABASE_URL");
        const max_conn = if (init.environ_map.get("DATABASE_MAX_CONN")) |v|
            std.fmt.parseInt(u16, v, 10) catch 256
        else
            256;
        app.pool = pg.Pool.initUri(io, allocator, uri, .{
            .size = max_conn,
            .connect_on_init_count = 0,
        }) catch |err| blk: {
            std.log.err("connecting to Postgres: {}", .{err});
            break :blk null;
        };
    }

    const cpus: u16 = @intCast(std.Thread.getCpuCount() catch 1);
    var server = try httpz.Server(*App).init(io, allocator, .{
        .address = .all(8080),
        .workers = .{ .count = envCount(init.environ_map, "HTTPZ_WORKERS") orelse cpus },
        .thread_pool = .{ .count = envCount(init.environ_map, "HTTPZ_THREADS") orelse cpus },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/baseline11", baseline, .{});
    router.post("/baseline11", baseline, .{});
    router.get("/pipeline", pipeline, .{});
    router.get("/async-db", asyncDb, .{});
    router.get("/ws", wsEcho, .{});

    try server.listen();
}
