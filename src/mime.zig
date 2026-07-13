const std = @import("std");

pub const fallback = "application/octet-stream";

const Mapping = struct {
    extension: []const u8,
    content_type: []const u8,
};

const mappings = [_]Mapping{
    .{ .extension = ".html", .content_type = "text/html; charset=utf-8" },
    .{ .extension = ".htm", .content_type = "text/html; charset=utf-8" },
    .{ .extension = ".css", .content_type = "text/css; charset=utf-8" },
    .{ .extension = ".txt", .content_type = "text/plain; charset=utf-8" },
    .{ .extension = ".csv", .content_type = "text/csv; charset=utf-8" },
    .{ .extension = ".md", .content_type = "text/markdown; charset=utf-8" },
    .{ .extension = ".js", .content_type = "text/javascript; charset=utf-8" },
    .{ .extension = ".mjs", .content_type = "text/javascript; charset=utf-8" },
    .{ .extension = ".cjs", .content_type = "text/javascript; charset=utf-8" },
    .{ .extension = ".json", .content_type = "application/json" },
    .{ .extension = ".map", .content_type = "application/json" },
    .{ .extension = ".webmanifest", .content_type = "application/manifest+json" },
    .{ .extension = ".xml", .content_type = "application/xml" },
    .{ .extension = ".rss", .content_type = "application/rss+xml" },
    .{ .extension = ".atom", .content_type = "application/atom+xml" },
    .{ .extension = ".yaml", .content_type = "application/yaml" },
    .{ .extension = ".yml", .content_type = "application/yaml" },
    .{ .extension = ".toml", .content_type = "application/toml" },
    .{ .extension = ".svg", .content_type = "image/svg+xml" },
    .{ .extension = ".png", .content_type = "image/png" },
    .{ .extension = ".jpg", .content_type = "image/jpeg" },
    .{ .extension = ".jpeg", .content_type = "image/jpeg" },
    .{ .extension = ".gif", .content_type = "image/gif" },
    .{ .extension = ".webp", .content_type = "image/webp" },
    .{ .extension = ".avif", .content_type = "image/avif" },
    .{ .extension = ".bmp", .content_type = "image/bmp" },
    .{ .extension = ".ico", .content_type = "image/x-icon" },
    .{ .extension = ".tif", .content_type = "image/tiff" },
    .{ .extension = ".tiff", .content_type = "image/tiff" },
    .{ .extension = ".woff", .content_type = "font/woff" },
    .{ .extension = ".woff2", .content_type = "font/woff2" },
    .{ .extension = ".ttf", .content_type = "font/ttf" },
    .{ .extension = ".otf", .content_type = "font/otf" },
    .{ .extension = ".eot", .content_type = "application/vnd.ms-fontobject" },
    .{ .extension = ".wasm", .content_type = "application/wasm" },
    .{ .extension = ".pdf", .content_type = "application/pdf" },
    .{ .extension = ".zip", .content_type = "application/zip" },
    .{ .extension = ".tar", .content_type = "application/x-tar" },
    .{ .extension = ".gz", .content_type = "application/gzip" },
    .{ .extension = ".mp4", .content_type = "video/mp4" },
    .{ .extension = ".webm", .content_type = "video/webm" },
    .{ .extension = ".mp3", .content_type = "audio/mpeg" },
    .{ .extension = ".wav", .content_type = "audio/wav" },
    .{ .extension = ".ogg", .content_type = "audio/ogg" },
};

comptime {
    @setEvalBranchQuota(10_000);

    for (mappings, 0..) |mapping, index| {
        if (mapping.extension.len < 2 or mapping.extension[0] != '.') {
            @compileError("MIME extensions must begin with a dot");
        }
        for (mappings[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(mapping.extension, previous.extension)) {
                @compileError("duplicate MIME extension: " ++ mapping.extension);
            }
        }
    }
}

/// Returns the content type associated with the final extension in `path`.
/// Matching is ASCII case-insensitive and does not allocate.
pub fn fromPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return fallback;

    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(extension, mapping.extension)) {
            return mapping.content_type;
        }
    }

    return fallback;
}

test "fromPath resolves textual content types with conventional charsets" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromPath("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", fromPath("styles/site.css"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", fromPath("app.js"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", fromPath("README.txt"));
}

test "fromPath resolves structured and binary content types" {
    try std.testing.expectEqualStrings("application/json", fromPath("data.json"));
    try std.testing.expectEqualStrings("image/svg+xml", fromPath("icons/logo.svg"));
    try std.testing.expectEqualStrings("image/png", fromPath("images/logo.png"));
    try std.testing.expectEqualStrings("font/woff2", fromPath("fonts/site.woff2"));
    try std.testing.expectEqualStrings("application/wasm", fromPath("runtime.wasm"));
}

test "fromPath matches extensions case-insensitively" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromPath("INDEX.HTML"));
    try std.testing.expectEqualStrings("image/webp", fromPath("cover.WeBp"));
    try std.testing.expectEqualStrings("application/wasm", fromPath("runtime.WaSm"));
}

test "fromPath uses only the final extension" {
    try std.testing.expectEqualStrings("application/gzip", fromPath("archive.tar.gz"));
    try std.testing.expectEqualStrings("application/json", fromPath("bundle.js.map"));
}

test "fromPath falls back for missing and unknown extensions" {
    try std.testing.expectEqualStrings(fallback, fromPath("LICENSE"));
    try std.testing.expectEqualStrings(fallback, fromPath("archive.unknown"));
    try std.testing.expectEqualStrings(fallback, fromPath("directory.with.dots/file"));
}
