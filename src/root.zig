const httpz = @import("httpz");

/// Static-file middleware for httpz.
pub const package_name = "httpz-static";

test "httpz dependency is available" {
    _ = httpz.Request;
    _ = httpz.Response;
}
