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

/// Owns a validated deep copy of user MIME mappings.
pub const OwnedMimeMappings = struct {
    allocator: std.mem.Allocator,
    values: []MimeMapping,

    pub fn init(
        allocator: std.mem.Allocator,
        mappings_to_copy: []const MimeMapping,
    ) (MimeMappingError || std.mem.Allocator.Error)!OwnedMimeMappings {
        try validateMappings(mappings_to_copy);

        const values = try allocator.alloc(MimeMapping, mappings_to_copy.len);
        var initialized: usize = 0;
        errdefer {
            for (values[0..initialized]) |mapping| {
                allocator.free(mapping.extension);
                allocator.free(mapping.content_type);
            }
            allocator.free(values);
        }

        for (mappings_to_copy, 0..) |mapping, index| {
            const extension = try allocator.dupe(u8, mapping.extension);
            const content_type = allocator.dupe(u8, mapping.content_type) catch |err| {
                allocator.free(extension);
                return err;
            };
            values[index] = .{
                .extension = extension,
                .content_type = content_type,
            };
            initialized += 1;
        }

        return .{ .allocator = allocator, .values = values };
    }

    pub fn deinit(self: *OwnedMimeMappings) void {
        for (self.values) |mapping| {
            self.allocator.free(mapping.extension);
            self.allocator.free(mapping.content_type);
        }
        self.allocator.free(self.values);
        self.* = undefined;
    }

    pub fn slice(self: *const OwnedMimeMappings) []const MimeMapping {
        return self.values;
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

    for (mappings, 0..) |mapping, index| {
        validateMapping(mapping) catch @compileError("invalid built-in MIME mapping");
        for (mappings[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(mapping.extension, previous.extension)) {
                @compileError("duplicate MIME extension: " ++ mapping.extension);
            }
        }
    }
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
    try validateParameters(mapping.content_type[media_type_end..]);
}

fn validateParameters(parameters: []const u8) MimeMappingError!void {
    var index: usize = 0;
    while (index < parameters.len) {
        if (parameters[index] != ';') return error.InvalidContentType;
        index += 1;
        skipOptionalWhitespace(parameters, &index);

        const name_start = index;
        while (index < parameters.len and isTokenByte(parameters[index])) index += 1;
        if (index == name_start) return error.InvalidContentType;

        skipOptionalWhitespace(parameters, &index);
        if (index == parameters.len or parameters[index] != '=') {
            return error.InvalidContentType;
        }
        index += 1;
        skipOptionalWhitespace(parameters, &index);
        if (index == parameters.len) return error.InvalidContentType;

        if (parameters[index] == '"') {
            try consumeQuotedValue(parameters, &index);
        } else {
            const value_start = index;
            while (index < parameters.len and isTokenByte(parameters[index])) index += 1;
            if (index == value_start) return error.InvalidContentType;
        }

        skipOptionalWhitespace(parameters, &index);
        if (index < parameters.len and parameters[index] != ';') {
            return error.InvalidContentType;
        }
    }
}

fn consumeQuotedValue(input: []const u8, index: *usize) MimeMappingError!void {
    index.* += 1;
    while (index.* < input.len) {
        const byte = input[index.*];
        switch (byte) {
            '"' => {
                index.* += 1;
                return;
            },
            '\\' => {
                index.* += 1;
                if (index.* == input.len or !isQuotedPairByte(input[index.*])) {
                    return error.InvalidContentType;
                }
            },
            else => if (!isQuotedByte(byte)) return error.InvalidContentType,
        }
        index.* += 1;
    }
    return error.InvalidContentType;
}

fn skipOptionalWhitespace(input: []const u8, index: *usize) void {
    while (index.* < input.len and (input[index.*] == ' ' or input[index.*] == '\t')) {
        index.* += 1;
    }
}

fn isQuotedByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte <= 0x7e and byte != '"');
}

fn isQuotedPairByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte <= 0x7e);
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

test "fromPathWith resolves additions and built-in overrides first" {
    const overrides = [_]MimeMapping{
        .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
        .{ .extension = ".json", .content_type = "application/vnd.example+json" },
        .{
            .extension = ".tmpl",
            .content_type = "text/x-template; charset=utf-8; profile=\"compact v1\"",
        },
    };
    try validateMappings(&overrides);

    try std.testing.expectEqualStrings(
        "application/x-ndjson",
        fromPathWith("events.JSONL", &overrides),
    );
    try std.testing.expectEqualStrings(
        "application/vnd.example+json",
        fromPathWith("data.json", &overrides),
    );
    try std.testing.expectEqualStrings(
        "text/x-template; charset=utf-8; profile=\"compact v1\"",
        fromPathWith("page.tmpl", &overrides),
    );
    try std.testing.expectEqualStrings("image/png", fromPathWith("logo.png", &overrides));
    try std.testing.expectEqualStrings(fallback, fromPathWith("data.unknown", &overrides));
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

test "validateMappings rejects unsafe or malformed content types" {
    const invalid = [_][]const u8{
        "",
        "application",
        "application/",
        "text/ plain",
        "text/plain;;;;",
        "text/plain; invalid parameter",
        "text/plain; charset",
        "text/plain; charset=",
        "text/plain; profile=\"unterminated",
        "text/plain; profile=\"bad\\",
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

test "OwnedMimeMappings retains a deep copy" {
    var extension = ".jsonl".*;
    var content_type = "application/x-ndjson".*;
    const source = [_]MimeMapping{.{
        .extension = &extension,
        .content_type = &content_type,
    }};

    var owned = try OwnedMimeMappings.init(std.testing.allocator, &source);
    defer owned.deinit();

    extension[1] = 'x';
    content_type[0] = 'X';

    try std.testing.expectEqualStrings(".jsonl", owned.slice()[0].extension);
    try std.testing.expectEqualStrings(
        "application/x-ndjson",
        owned.slice()[0].content_type,
    );
    try std.testing.expectEqualStrings(
        "application/x-ndjson",
        fromPathWith("events.jsonl", owned.slice()),
    );
}

test "OwnedMimeMappings cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initOwnedMimeMappings,
        .{},
    );
}

fn initOwnedMimeMappings(allocator: std.mem.Allocator) !void {
    var owned = try OwnedMimeMappings.init(allocator, &.{
        .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
        .{ .extension = ".tmpl", .content_type = "text/x-template; charset=utf-8" },
    });
    defer owned.deinit();
}
