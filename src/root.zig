const httpz = @import("httpz");
const mime = @import("mime.zig");
const path = @import("path.zig");

test {
    _ = httpz.Request;
    _ = httpz.Response;
    _ = mime;
    _ = path;
}
