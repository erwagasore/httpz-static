const httpz = @import("httpz");
const mime = @import("mime.zig");
const path = @import("path.zig");

pub const MimeMapping = mime.Mapping;

test {
    _ = httpz.Request;
    _ = httpz.Response;
    _ = mime;
    _ = path;
}
