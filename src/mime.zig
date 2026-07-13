const std = @import("std");

pub const fallback = "application/octet-stream";

pub const MimeMapping = struct {
    /// Final file extension, including the leading dot.
    extension: []const u8,
    /// Complete value for the HTTP `Content-Type` header.
    content_type: []const u8,
};

pub const MimeMappingError = error{
    InvalidExtension,
    InvalidContentType,
    DuplicateExtension,
};

/// Resolves file paths using validated, deeply owned user overrides before
/// consulting the built-in MIME table and binary fallback.
pub const MimeResolver = struct {
    arena: std.heap.ArenaAllocator,
    overrides: []MimeMapping,

    pub fn init(
        backing_allocator: std.mem.Allocator,
        overrides_to_copy: []const MimeMapping,
    ) (MimeMappingError || std.mem.Allocator.Error)!MimeResolver {
        try validateMappings(overrides_to_copy);

        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const overrides = try allocator.alloc(MimeMapping, overrides_to_copy.len);
        for (overrides_to_copy, overrides) |source, *destination| {
            destination.* = .{
                .extension = try allocator.dupe(u8, source.extension),
                .content_type = try allocator.dupe(u8, source.content_type),
            };
        }

        return .{ .arena = arena, .overrides = overrides };
    }

    pub fn deinit(self: *MimeResolver) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn fromPath(self: *const MimeResolver, path: []const u8) []const u8 {
        return fromPathWith(path, self.overrides);
    }
};

const mappings = [_]MimeMapping{
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
    validateMappings(&mappings) catch
        @compileError("invalid or duplicate built-in MIME mapping");
}

/// Validates user-provided mappings once during middleware initialization.
pub fn validateMappings(overrides: []const MimeMapping) MimeMappingError!void {
    for (overrides, 0..) |mapping, index| {
        try validateMapping(mapping);
        for (overrides[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(mapping.extension, previous.extension)) {
                return error.DuplicateExtension;
            }
        }
    }
}

/// Returns the content type associated with the final extension in `path`.
/// Matching is ASCII case-insensitive and does not allocate.
pub fn fromPath(path: []const u8) []const u8 {
    return fromPathWith(path, &.{});
}

/// Resolves prevalidated user overrides before consulting the built-in table.
/// The result borrows static storage or an override content-type slice, so the
/// overrides must outlive every response that uses the result.
pub fn fromPathWith(path: []const u8, overrides: []const MimeMapping) []const u8 {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return fallback;

    for (overrides) |mapping| {
        if (std.ascii.eqlIgnoreCase(extension, mapping.extension)) {
            return mapping.content_type;
        }
    }
    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(extension, mapping.extension)) {
            return mapping.content_type;
        }
    }

    return fallback;
}

fn validateMapping(mapping: MimeMapping) MimeMappingError!void {
    if (mapping.extension.len < 2 or mapping.extension[0] != '.') {
        return error.InvalidExtension;
    }
    for (mapping.extension[1..]) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '.' or byte == '/' or byte == '\\') {
            return error.InvalidExtension;
        }
    }

    const media_type_end = std.mem.indexOfScalar(u8, mapping.content_type, ';') orelse
        mapping.content_type.len;
    const media_type = mapping.content_type[0..media_type_end];
    const slash = std.mem.indexOfScalar(u8, media_type, '/') orelse
        return error.InvalidContentType;
    if (slash == 0 or slash + 1 == media_type.len) return error.InvalidContentType;

    for (media_type, 0..) |byte, index| {
        if (index != slash and !isTokenByte(byte)) return error.InvalidContentType;
    }
    for (mapping.content_type[media_type_end..]) |byte| {
        if (byte < 0x20 or byte > 0x7e) return error.InvalidContentType;
    }
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
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

test "MimeResolver resolves additions and built-in overrides first" {
    const overrides = [_]MimeMapping{
        .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
        .{ .extension = ".json", .content_type = "application/vnd.example+json" },
        .{
            .extension = ".tmpl",
            .content_type = "text/x-template; charset=utf-8; profile=\"compact v1\"",
        },
    };
    var resolver = try MimeResolver.init(std.testing.allocator, &overrides);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(
        "application/x-ndjson",
        resolver.fromPath("events.JSONL"),
    );
    try std.testing.expectEqualStrings(
        "application/vnd.example+json",
        resolver.fromPath("data.json"),
    );
    try std.testing.expectEqualStrings(
        "text/x-template; charset=utf-8; profile=\"compact v1\"",
        resolver.fromPath("page.tmpl"),
    );
    try std.testing.expectEqualStrings("image/png", resolver.fromPath("logo.png"));
    try std.testing.expectEqualStrings(fallback, resolver.fromPath("data.unknown"));
}

test "validateMappings rejects malformed extensions" {
    const invalid = [_][]const u8{
        "",
        "jsonl",
        ".tar.gz",
        ".bad/path",
        ".bad\\path",
        ".with space",
    };
    for (invalid) |extension| {
        try std.testing.expectError(
            error.InvalidExtension,
            validateMappings(&.{.{
                .extension = extension,
                .content_type = "application/octet-stream",
            }}),
        );
    }
}

test "validateMappings rejects malformed media types and unsafe header bytes" {
    const invalid = [_][]const u8{
        "",
        "application",
        "application/",
        "text/ plain",
        "text/plain\x00bad",
        "text/plain\x7fbad",
        "text/plain\r\nX-Injected: true",
    };
    for (invalid) |content_type| {
        try std.testing.expectError(
            error.InvalidContentType,
            validateMappings(&.{.{
                .extension = ".custom",
                .content_type = content_type,
            }}),
        );
    }
}

test "validateMappings rejects duplicate extensions case-insensitively" {
    try std.testing.expectError(
        error.DuplicateExtension,
        validateMappings(&.{
            .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
            .{ .extension = ".JSONL", .content_type = "application/json" },
        }),
    );
}

test "MimeResolver retains a deep copy" {
    var extension = ".jsonl".*;
    var content_type = "application/x-ndjson".*;
    const source = [_]MimeMapping{.{
        .extension = &extension,
        .content_type = &content_type,
    }};

    var resolver = try MimeResolver.init(std.testing.allocator, &source);
    defer resolver.deinit();

    extension[1] = 'x';
    content_type[0] = 'X';

    try std.testing.expectEqualStrings(
        "application/x-ndjson",
        resolver.fromPath("events.jsonl"),
    );
}

test "MimeResolver cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initMimeResolver,
        .{},
    );
}

fn initMimeResolver(allocator: std.mem.Allocator) !void {
    var resolver = try MimeResolver.init(allocator, &.{
        .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
        .{ .extension = ".tmpl", .content_type = "text/x-template; charset=utf-8" },
    });
    defer resolver.deinit();
}
