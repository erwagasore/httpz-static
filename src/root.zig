const httpz = @import("httpz");
const path = @import("path.zig");

/// Static-file middleware for httpz.
pub const package_name = "httpz-static";

test {
    _ = httpz.Request;
    _ = httpz.Response;
    _ = path;
}
