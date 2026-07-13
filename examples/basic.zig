const std = @import("std");
const httpz = @import("httpz");
const Static = @import("httpz-static");

const port = 8080;

pub fn main(init: std.process.Init) !void {
    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(port),
    }, {});
    defer server.deinit();
    defer server.stop();

    const static = try server.middleware(Static, .{
        .io = init.io,
        .mounts = &.{.{
            .url_prefix = "/assets",
            .directory_path = "examples/public",
        }},
    });

    var router = try server.router(.{ .middlewares = &.{static} });
    router.get("/", index, .{});

    std.debug.print("listening on http://localhost:{d}\n", .{port});
    std.debug.print("static file: http://localhost:{d}/assets/hello.txt\n", .{port});
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .TEXT;
    res.body = "Try GET or HEAD /assets/hello.txt\n";
}
