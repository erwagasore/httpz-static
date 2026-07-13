const httpz = @import("httpz");
const mime = @import("mime.zig");
const path = @import("path.zig");

pub const MimeMapping = mime.MimeMapping;

test {
    _ = httpz.Request;
    _ = httpz.Response;
    _ = mime;
    _ = path;

    const custom: MimeMapping = .{
        .extension = ".jsonl",
        .content_type = "application/x-ndjson",
    };
    _ = custom;
}
