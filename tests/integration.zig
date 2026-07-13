const std = @import("std");
const httpz = @import("httpz");
const Static = @import("httpz-static");

const testing = std.testing;

test "real httpz server serves static GET and HEAD and rejects encoded attacks" {
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    {
        const fixture = try tmp.dir.createFile(io, "assets/hello.txt", .{});
        defer fixture.close(io);
        try fixture.writeStreamingAll(io, "hello over httpz");
    }

    const port = try availablePort(io);
    var server = try httpz.Server(void).init(io, allocator, .{
        .address = .localhost(port),
        .workers = .{ .count = 1 },
    }, {});
    defer server.deinit();

    const static = try server.middleware(Static, .{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{
            .url_prefix = "/assets",
            .directory_path = "assets",
        }},
        .fallthrough = false,
    });
    _ = try server.router(.{ .middlewares = &.{static} });

    const server_thread = try server.listenInNewThread();
    defer {
        server.stop();
        server_thread.join();
    }

    var get = try request(allocator, io, port, "GET", "/assets/hello.txt");
    defer get.deinit();
    try testing.expectEqual(@as(u16, 200), get.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", get.headers.get("Content-Type").?);
    try testing.expectEqualStrings("16", get.headers.get("Content-Length").?);
    try testing.expectEqualStrings("hello over httpz", get.body);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, get.raw, "Content-Length:"));

    var encoded_get = try request(allocator, io, port, "GET", "/assets/hello%2Etxt");
    defer encoded_get.deinit();
    try testing.expectEqual(@as(u16, 200), encoded_get.status);
    try testing.expectEqualStrings("hello over httpz", encoded_get.body);

    var head = try request(allocator, io, port, "HEAD", "/assets/hello.txt");
    defer head.deinit();
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", head.headers.get("Content-Type").?);
    try testing.expectEqualStrings("16", head.headers.get("Content-Length").?);
    try testing.expectEqualStrings("", head.body);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head.raw, "Content-Length:"));

    const attacks = [_][]const u8{
        "/assets/%2e%2e/secret.txt",
        "/assets/%252e%252e/secret.txt",
        "/assets/nested%2f..%2fsecret.txt",
        "/assets/%00.txt",
    };
    for (attacks) |target| {
        var response = try request(allocator, io, port, "GET", target);
        defer response.deinit();
        try testing.expectEqual(@as(u16, 404), response.status);
        try testing.expectEqualStrings("Not Found", response.body);
    }
}

fn availablePort(io: std.Io) !u16 {
    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try loopback.listen(io, .{});
    defer listener.deinit(io);
    return switch (listener.socket.address) {
        .ip4 => |address| address.port,
        .ip6 => |address| address.port,
    };
}

fn request(
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    method: []const u8,
    target: []const u8,
) !httpz.testing.Testing.Response {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    try stream_writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{ method, target },
    );
    try stream_writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    const raw = try stream_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    return httpz.testing.parseWithAllocator(allocator, raw);
}
