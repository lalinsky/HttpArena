const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");
const json = @import("json");
const pg = @import("pg");
const templates = @import("templates/fortunes.zig");

var dataset: ?[]const DatasetItem = null;
// One pool per runtime: a pool belongs to the runtime whose io it was made with.
threadlocal var pool: ?*pg.Pool = null;

const Rating = struct { score: i64, count: i64 };

const DatasetItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const ResponseItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

fn loadDataset(allocator: std.mem.Allocator, io: std.Io) void {
    const file = std.Io.Dir.cwd().openFile(io, "/data/dataset.json", .{}) catch return;
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const decoded = json.decode([]const DatasetItem, allocator, &reader.interface, .{}) catch return;
    dataset = decoded.value;
}

fn baseline(req: *http.Request, res: *http.Response) !void {
    var sum: i64 = 0;
    var it = req.query.iterator();
    while (it.next()) |entry| {
        sum += std.fmt.parseInt(i64, entry.value, 10) catch 0;
    }
    if (req.method == .post) {
        if (try req.body()) |b| {
            sum += std.fmt.parseInt(i64, b, 10) catch 0;
        }
    }
    try res.print(.text, "{d}", .{sum});
}

fn pipeline(_: *http.Request, res: *http.Response) !void {
    res.content_type = .text;
    res.body = "ok";
}

fn delay(req: *http.Request, res: *http.Response) !void {
    const ms = req.params.getInt(u32, "ms") orelse 0;
    if (ms > 0) {
        try req.io.sleep(.fromMilliseconds(ms), .awake);
    }
    try res.print(.text, "{d}", .{ms});
}

fn jsonItems(req: *http.Request, res: *http.Response) !void {
    const items = dataset orelse {
        res.status = .service_unavailable;
        return;
    };

    const count = req.params.getInt(usize, "count") orelse {
        res.status = .bad_request;
        return;
    };
    if (count < 1 or count > items.len) {
        res.status = .bad_request;
        return;
    }

    const m: i64 = req.query.getInt(i64, "m") orelse 1;

    const resp_items = try req.arena.alloc(ResponseItem, count);
    for (items[0..count], 0..) |item, i| {
        resp_items[i] = .{
            .id = item.id,
            .name = item.name,
            .category = item.category,
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags = item.tags,
            .rating = item.rating,
            .total = item.price * item.quantity * m,
        };
    }

    const payload = .{ .items = resp_items, .count = count };

    res.compress = true;
    try res.encode(.json, json.encode, payload);
}

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

fn asyncDb(req: *http.Request, res: *http.Response) !void {
    const p = pool orelse return res.encode(.json, json.encode, empty_db_response);

    const min = req.query.getInt(i32, "min") orelse 10;
    const max = req.query.getInt(i32, "max") orelse 50;
    const limit = std.math.clamp(req.query.getInt(i32, "limit") orelse 50, 1, 50);

    var result = p.queryOpts(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
        .{ min, max, limit },
        .{ .cache_name = "async_db" },
    ) catch return res.encode(.json, json.encode, empty_db_response);
    defer result.deinit();

    var items: std.ArrayList(DbItem) = .empty;
    while (try result.next()) |row| {
        const tags_json = try row.get([]const u8, 6);
        const tags = json.decodeFromSliceLeaky([]const []const u8, req.arena, tags_json, .{}) catch &.{};

        try items.append(req.arena, DbItem{
            .id = try row.get(i32, 0),
            .name = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .category = try req.arena.dupe(u8, try row.get([]const u8, 2)),
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

    try res.encode(.json, json.encode, DbResponse{ .items = items.items, .count = items.items.len });
}

const Fortune = templates.Fortune;

fn fortuneLessThan(_: void, a: Fortune, b: Fortune) bool {
    return std.mem.lessThan(u8, a.message, b.message);
}

fn fortunes(req: *http.Request, res: *http.Response) !void {
    const p = pool orelse {
        res.status = .service_unavailable;
        return;
    };

    var result = try p.queryOpts("SELECT id, message FROM fortune", .{}, .{ .cache_name = "fortunes" });
    defer result.deinit();

    var list: std.ArrayList(Fortune) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .id = try row.get(i32, 0),
            .message = try req.arena.dupe(u8, try row.get([]const u8, 1)),
        });
    }
    try list.append(req.arena, .{ .id = 0, .message = "Additional fortune added at request time." });
    std.mem.sort(Fortune, list.items, {}, fortuneLessThan);

    try res.render(.html, templates.FortunesPage, .{list.items});
}

fn wsEcho(req: *http.Request, res: *http.Response) !void {
    var ws = try res.upgradeWebSocket(req) orelse {
        res.status = .not_found;
        return;
    };
    defer ws.deinit();
    ws.autoflush = false;
    while (true) {
        for (try ws.receiveMany()) |msg| {
            switch (msg.type) {
                .text, .binary => try ws.send(msg.type, msg.data),
                .close => return,
                else => {},
            }
        }
        try ws.flush();
    }
}

fn echoBody(req: *http.Request, res: *http.Response) !void {
    const body = try req.body() orelse "";
    try res.header("Content-Type", "application/octet-stream");
    res.body = body;
}

/// What the entry tunes, read from the environment while the settings are
/// being explored.
const Tuning = struct {
    /// Zero runs one runtime. N runs N runtimes, every one with its own
    /// server on the same ports, the kernel spreading connections over them
    /// with SO_REUSEPORT.
    runtimes: usize = 0,
    /// Executors per runtime; zero is one per CPU for a single runtime and
    /// one for each of N.
    executors: u8 = 0,
    acceptors: ?u16 = null,
    kernel_backlog: ?u31 = null,
    timeouts: bool = true,
    buffer_size: usize = 16384,
    write_buffer_size: usize = 16384,
    db_url: ?[]const u8 = null,
    db_max_conn: u16 = 256,
    cert_path: []const u8 = "/certs/server.crt",
    key_path: []const u8 = "/certs/server.key",

    fn fromEnv(env: *const std.process.Environ.Map) Tuning {
        var t: Tuning = .{};
        t.runtimes = envInt(env, usize, "RUNTIMES") orelse t.runtimes;
        t.executors = envInt(env, u8, "EXECUTORS") orelse t.executors;
        t.acceptors = envInt(env, u16, "ACCEPTORS");
        t.kernel_backlog = envInt(env, u31, "BACKLOG");
        if (env.get("NO_TIMEOUTS")) |v| t.timeouts = std.mem.eql(u8, v, "0");
        t.buffer_size = envInt(env, usize, "BUFFER_SIZE") orelse t.buffer_size;
        t.write_buffer_size = envInt(env, usize, "WRITE_BUFFER_SIZE") orelse t.write_buffer_size;
        t.db_url = env.get("DATABASE_URL");
        t.db_max_conn = envInt(env, u16, "DATABASE_MAX_CONN") orelse t.db_max_conn;
        t.cert_path = env.get("TLS_CERT") orelse t.cert_path;
        t.key_path = env.get("TLS_KEY") orelse t.key_path;
        return t;
    }

    fn envInt(env: *const std.process.Environ.Map, comptime T: type, name: []const u8) ?T {
        const v = env.get(name) orelse return null;
        return std.fmt.parseInt(T, v, 10) catch null;
    }
};

pub fn main(init: std.process.Init) !void {
    const tuning: Tuning = .fromEnv(init.environ_map);

    loadDataset(init.arena.allocator(), init.io);

    if (tuning.runtimes == 0) {
        const executors: @FieldType(zio.RuntimeOptions, "executors") = if (tuning.executors == 0) .auto else .exact(tuning.executors);
        return serve(init.gpa, &tuning, executors, tuning.db_max_conn);
    }

    const per_runtime: @FieldType(zio.RuntimeOptions, "executors") = if (tuning.executors == 0) .exact(1) else .exact(tuning.executors);
    const per_runtime_db: u16 = @intCast(@max(1, tuning.db_max_conn / tuning.runtimes));
    const threads = try init.gpa.alloc(std.Thread, tuning.runtimes - 1);
    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, serveThread, .{ init.gpa, &tuning, per_runtime, per_runtime_db });
    }
    serveThread(init.gpa, &tuning, per_runtime, per_runtime_db);
    for (threads) |t| t.join();
}

fn serveThread(gpa: std.mem.Allocator, tuning: *const Tuning, executors: @FieldType(zio.RuntimeOptions, "executors"), db_max_conn: u16) void {
    serve(gpa, tuning, executors, db_max_conn) catch |err| {
        std.debug.print("runtime failed: {}\n", .{err});
        std.process.exit(1);
    };
}

fn serve(gpa: std.mem.Allocator, tuning: *const Tuning, executors: @FieldType(zio.RuntimeOptions, "executors"), db_max_conn: u16) !void {
    var rt = try zio.Runtime.init(gpa, .{ .executors = executors });
    defer rt.deinit();

    if (tuning.db_url) |url| {
        const uri = std.Uri.parse(url) catch @panic("invalid DATABASE_URL");
        pool = pg.Pool.initUri(rt.io(), gpa, uri, .{
            .size = db_max_conn,
            .connect_on_init_count = 1,
        }) catch null;
    }

    const have_certs = blk: {
        std.Io.Dir.cwd().access(rt.io(), tuning.cert_path, .{}) catch break :blk false;
        std.Io.Dir.cwd().access(rt.io(), tuning.key_path, .{}) catch break :blk false;
        break :blk true;
    };
    const listeners = [_]http.Listener{
        .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8080) },
            .acceptors = tuning.acceptors,
            .kernel_backlog = tuning.kernel_backlog,
        },
        .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8081) },
            .acceptors = tuning.acceptors,
            .kernel_backlog = tuning.kernel_backlog,
            .tls = .{
                .certificate = .{ .file = .{ .cert_path = tuning.cert_path, .key_path = tuning.key_path } },
                .alpn_protocols = &.{"http/1.1"},
            },
        },
    };
    var server = http.Server(void).init(gpa, rt.io(), .{
        .listeners = if (have_certs) &listeners else listeners[0..1],
        .max_connections = 65_536,
        .timeout = if (tuning.timeouts) .{} else .{ .request = null, .keepalive = null },
        .request = .{ .buffer_size = tuning.buffer_size },
        .response = .{ .write_buffer_size = tuning.write_buffer_size },
    }, {});
    defer server.deinit();

    server.router.get("/baseline11", baseline);
    server.router.post("/baseline11", baseline);
    server.router.get("/baseline2", baseline);
    server.router.post("/baseline2", baseline);
    server.router.get("/pipeline", pipeline);
    server.router.get("/delay/:ms", delay);
    server.router.get("/json/:count", jsonItems);
    server.router.post("/echo", echoBody);
    server.router.get("/ws", wsEcho);
    server.router.get("/async-db", asyncDb);
    server.router.get("/fortunes", fortunes);

    // Mounted by the harness; absent when the server is run on its own.
    const static_dir: ?std.Io.Dir = std.Io.Dir.cwd().openDir(rt.io(), "/data/static", .{}) catch null;
    defer if (static_dir) |dir| dir.close(rt.io());
    if (static_dir) |dir| {
        server.router.static("/static", dir, .{ .precompressed = &.{ .br, .gzip } });
    }

    try server.run();
}
