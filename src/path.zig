const std = @import("std");

pub const PrefixError = error{
    InvalidPrefix,
    DuplicatePrefix,
};

pub const PathError = error{
    MalformedEscape,
    UnsafePath,
};

pub const Match = struct {
    index: usize,
    relative_path: []const u8,
};

/// Validates and copies a URL mount prefix in its canonical form.
/// All trailing slashes are removed except for the root prefix itself.
pub fn normalizePrefix(
    allocator: std.mem.Allocator,
    prefix: []const u8,
) (PrefixError || std.mem.Allocator.Error)![]u8 {
    if (prefix.len == 0 or prefix[0] != '/') return error.InvalidPrefix;

    var end = prefix.len;
    while (end > 1 and prefix[end - 1] == '/') end -= 1;

    const normalized = prefix[0..end];
    for (normalized) |byte| {
        switch (byte) {
            0, '\\', '%', '?', '#' => return error.InvalidPrefix,
            else => {},
        }
    }

    if (normalized.len > 1) {
        var segments = std.mem.splitScalar(u8, normalized[1..], '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or
                std.mem.eql(u8, segment, ".") or
                std.mem.eql(u8, segment, ".."))
            {
                return error.InvalidPrefix;
            }
        }
    }

    return allocator.dupe(u8, normalized);
}

/// Rejects duplicate prefixes after they have been normalized.
pub fn ensureUniquePrefixes(prefixes: []const []const u8) PrefixError!void {
    for (prefixes, 0..) |prefix, index| {
        for (prefixes[0..index]) |previous| {
            if (std.mem.eql(u8, prefix, previous)) return error.DuplicatePrefix;
        }
    }
}

/// Selects the longest segment-boundary match and returns its relative raw path.
pub fn longestMatch(request_path: []const u8, prefixes: []const []const u8) ?Match {
    if (request_path.len == 0 or request_path[0] != '/') return null;

    var best: ?Match = null;
    var best_len: usize = 0;

    for (prefixes, 0..) |prefix, index| {
        const relative_path = relativeToPrefix(request_path, prefix) orelse continue;
        if (best == null or prefix.len > best_len) {
            best = .{ .index = index, .relative_path = relative_path };
            best_len = prefix.len;
        }
    }

    return best;
}

/// Validates a raw relative URL path, decodes it exactly once, then validates
/// the decoded filesystem-relative representation.
pub fn decodeAndValidate(
    allocator: std.mem.Allocator,
    raw_path: []const u8,
) (PathError || std.mem.Allocator.Error)![]const u8 {
    try validateFilesystemRelative(raw_path);

    var decoded_len = raw_path.len;
    var has_escape = false;
    var index: usize = 0;
    while (index < raw_path.len) {
        if (raw_path[index] != '%') {
            index += 1;
            continue;
        }

        has_escape = true;
        if (index + 2 >= raw_path.len) return error.MalformedEscape;
        const byte = decodeByte(raw_path[index + 1], raw_path[index + 2]) orelse
            return error.MalformedEscape;
        if (byte == '/' or byte == '\\' or byte == 0) return error.UnsafePath;

        decoded_len -= 2;
        index += 3;
    }

    if (!has_escape) return raw_path;

    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < raw_path.len) {
        if (raw_path[input_index] == '%') {
            decoded[output_index] = decodeByte(
                raw_path[input_index + 1],
                raw_path[input_index + 2],
            ).?;
            input_index += 3;
        } else {
            decoded[output_index] = raw_path[input_index];
            input_index += 1;
        }
        output_index += 1;
    }

    try validateFilesystemRelative(decoded);
    try rejectNestedEncoding(decoded);
    return decoded;
}

fn relativeToPrefix(request_path: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0 or prefix[0] != '/') return null;

    if (std.mem.eql(u8, prefix, "/")) return request_path[1..];
    if (!std.mem.startsWith(u8, request_path, prefix)) return null;
    if (request_path.len == prefix.len) return request_path[prefix.len..];
    if (request_path[prefix.len] != '/') return null;
    return request_path[prefix.len + 1 ..];
}

fn validateFilesystemRelative(path: []const u8) PathError!void {
    if (path.len > 0 and path[0] == '/') return error.UnsafePath;
    if (hasWindowsDrivePrefix(path)) return error.UnsafePath;

    for (path) |byte| {
        if (byte == 0 or byte == '\\') return error.UnsafePath;
    }

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.UnsafePath;
    }
}

fn rejectNestedEncoding(path: []const u8) PathError!void {
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] != '%' or index + 2 >= path.len) continue;
        if (decodeByte(path[index + 1], path[index + 2]) != null) {
            return error.UnsafePath;
        }
    }
}

fn hasWindowsDrivePrefix(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn decodeByte(high: u8, low: u8) ?u8 {
    const high_value = hexValue(high) orelse return null;
    const low_value = hexValue(low) orelse return null;
    return high_value << 4 | low_value;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "normalizePrefix canonicalizes trailing slashes" {
    const allocator = std.testing.allocator;

    const assets = try normalizePrefix(allocator, "/assets///");
    defer allocator.free(assets);
    try std.testing.expectEqualStrings("/assets", assets);

    const root = try normalizePrefix(allocator, "/");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("/", root);
}

test "normalizePrefix rejects malformed prefixes" {
    const invalid = [_][]const u8{
        "",
        "assets",
        "/assets//images",
        "/assets/./images",
        "/assets/../images",
        "/assets\\images",
        "/assets%2fimages",
        "/assets?version=1",
        "/assets#fragment",
        "/assets\x00images",
    };

    for (invalid) |prefix| {
        try std.testing.expectError(
            error.InvalidPrefix,
            normalizePrefix(std.testing.allocator, prefix),
        );
    }
}

test "ensureUniquePrefixes rejects normalized duplicates" {
    const allocator = std.testing.allocator;
    const first = try normalizePrefix(allocator, "/assets");
    defer allocator.free(first);
    const second = try normalizePrefix(allocator, "/assets/");
    defer allocator.free(second);

    try ensureUniquePrefixes(&.{ "/assets", "/images", "/" });
    try std.testing.expectError(
        error.DuplicatePrefix,
        ensureUniquePrefixes(&.{ first, "/images", second }),
    );
}

test "longestMatch respects precedence and segment boundaries" {
    const prefixes = [_][]const u8{ "/", "/assets", "/assets/icons" };

    const nested = longestMatch("/assets/icons/logo.svg", &prefixes).?;
    try std.testing.expectEqual(@as(usize, 2), nested.index);
    try std.testing.expectEqualStrings("logo.svg", nested.relative_path);

    const exact = longestMatch("/assets", &prefixes).?;
    try std.testing.expectEqual(@as(usize, 1), exact.index);
    try std.testing.expectEqualStrings("", exact.relative_path);

    const boundary = longestMatch("/assets-old/logo.svg", &prefixes).?;
    try std.testing.expectEqual(@as(usize, 0), boundary.index);
    try std.testing.expectEqualStrings("assets-old/logo.svg", boundary.relative_path);

    try std.testing.expect(longestMatch("/other", &.{"/assets"}) == null);
    try std.testing.expect(longestMatch("relative", &prefixes) == null);
}

test "decodeAndValidate decodes safe paths exactly once" {
    const allocator = std.testing.allocator;

    const decoded = try decodeAndValidate(allocator, "images/logo%20one%2Esvg");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("images/logo one.svg", decoded);

    const borrowed = "images/logo.svg";
    try std.testing.expectEqualStrings(borrowed, try decodeAndValidate(allocator, borrowed));
}

test "decodeAndValidate rejects unsafe filesystem forms" {
    const unsafe = [_][]const u8{
        "../secret",
        "images/../secret",
        "/etc/passwd",
        "C:/Windows/system.ini",
        "images\\secret",
        "images/\x00secret",
        "%2e%2e/secret",
        "images/%2E%2E/secret",
        "%2fetc/passwd",
        "images%5csecret",
        "images/%00secret",
        "%43%3a/Windows/system.ini",
        "images%2flogo.svg",
        "%252e%252e/secret",
        "%252fetc/passwd",
    };

    for (unsafe) |path| {
        try std.testing.expectError(
            error.UnsafePath,
            decodeAndValidate(std.testing.allocator, path),
        );
    }
}

test "decodeAndValidate rejects malformed percent escapes" {
    const malformed = [_][]const u8{ "%", "%2", "%GG", "image%2X.png" };

    for (malformed) |path| {
        try std.testing.expectError(
            error.MalformedEscape,
            decodeAndValidate(std.testing.allocator, path),
        );
    }
}

test "decodeAndValidate permits dots outside traversal segments" {
    const allocator = std.testing.allocator;
    const decoded = try decodeAndValidate(allocator, ".hidden/file%2Ename");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(".hidden/file.name", decoded);
}
