const std = @import("std");
const httpz = @import("httpz");
const mime = @import("mime.zig");
const path = @import("path.zig");

const Static = @This();

pub const Mount = struct {
    /// Public URL namespace. Initialization validates and copies this value.
    url_prefix: []const u8,
    /// Non-empty path resolved relative to `Config.cwd` during initialization.
    /// Trusted `.` and `..` segments are allowed.
    directory_path: []const u8,
};

pub const MimeMapping = mime.MimeMapping;

pub const Config = struct {
    io: std.Io,
    /// Borrowed base directory; the middleware never closes it.
    cwd: std.Io.Dir = .cwd(),
    /// Borrowed for initialization; all retained values and handles are owned.
    mounts: []const Mount,
    /// Continue the httpz chain when a matched file is unavailable or unsafe.
    fallthrough: bool = true,
    /// Maximum served file size in bytes, or `null` for no configured limit.
    max_file_size: ?u64 = null,
    /// Borrowed for initialization and deep-copied by the MIME resolver.
    mime_overrides: []const MimeMapping = &.{},
};

pub const InitError = error{
    NoMounts,
    InvalidDirectoryPath,
} || path.NormalizeError ||
    path.DuplicateError ||
    mime.MimeMappingError ||
    std.mem.Allocator.Error ||
    std.Io.Dir.OpenError;

io: std.Io,
arena: std.heap.ArenaAllocator,
roots: []std.Io.Dir,
prefixes: []const []const u8,
mime_resolver: mime.MimeResolver,
fallthrough: bool,
max_file_size: ?u64,

/// Validates configuration, owns normalized prefixes and MIME overrides, and
/// opens every configured root without following a final directory symlink.
///
/// The returned middleware owns directory handles and allocation arenas: call
/// `deinit` exactly once and do not copy it after initialization.
pub fn init(config: Config, mc: httpz.MiddlewareConfig) InitError!Static {
    if (config.mounts.len == 0) return error.NoMounts;
    for (config.mounts) |mount| {
        if (!isRelativeDirectoryPath(mount.directory_path)) {
            return error.InvalidDirectoryPath;
        }
    }

    var arena = std.heap.ArenaAllocator.init(mc.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const prefixes = try allocator.alloc([]const u8, config.mounts.len);
    for (config.mounts, prefixes) |mount, *prefix| {
        prefix.* = try path.normalizePrefix(allocator, mount.url_prefix);
    }
    try path.ensureUniquePrefixes(prefixes);

    var mime_resolver = try mime.MimeResolver.init(mc.allocator, config.mime_overrides);
    errdefer mime_resolver.deinit();

    const roots = try allocator.alloc(std.Io.Dir, config.mounts.len);
    var opened: usize = 0;
    errdefer std.Io.Dir.closeMany(config.io, roots[0..opened]);
    for (config.mounts, roots) |mount, *root| {
        root.* = try config.cwd.openDir(config.io, mount.directory_path, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        opened += 1;
    }

    return .{
        .io = config.io,
        .arena = arena,
        .roots = roots,
        .prefixes = prefixes,
        .mime_resolver = mime_resolver,
        .fallthrough = config.fallthrough,
        .max_file_size = config.max_file_size,
    };
}

pub fn deinit(self: *Static) void {
    std.Io.Dir.closeMany(self.io, self.roots);
    self.mime_resolver.deinit();
    self.arena.deinit();
    self.* = undefined;
}

fn isRelativeDirectoryPath(directory_path: []const u8) bool {
    if (directory_path.len == 0 or
        std.fs.path.isAbsolute(directory_path) or
        directory_path[0] == '\\' or
        (directory_path.len >= 2 and
            std.ascii.isAlphabetic(directory_path[0]) and
            directory_path[1] == ':'))
    {
        return false;
    }
    return std.mem.indexOfScalar(u8, directory_path, 0) == null;
}

test "init retains normalized mounts and MIME overrides" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try tmp.dir.createDir(io, "images", .default_dir);

    var assets_prefix = "/assets/".*;
    var custom_extension = ".jsonl".*;
    var custom_content_type = "application/x-ndjson".*;
    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{
            .{ .url_prefix = &assets_prefix, .directory_path = "assets" },
            .{ .url_prefix = "/images", .directory_path = "images" },
        },
        .fallthrough = false,
        .max_file_size = 4096,
        .mime_overrides = &.{.{
            .extension = &custom_extension,
            .content_type = &custom_content_type,
        }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    assets_prefix[1] = 'x';
    custom_extension[1] = 'x';
    custom_content_type[0] = 'X';

    try std.testing.expectEqual(@as(usize, 2), static.roots.len);
    try std.testing.expectEqualStrings("/assets", static.prefixes[0]);
    try std.testing.expectEqualStrings("/images", static.prefixes[1]);
    try std.testing.expectEqualStrings(
        "application/x-ndjson",
        static.mime_resolver.fromPath("events.jsonl"),
    );
    try std.testing.expect(!static.fallthrough);
    try std.testing.expectEqual(@as(?u64, 4096), static.max_file_size);
    _ = try static.roots[0].stat(io);
    _ = try static.roots[1].stat(io);
}

test "init rejects empty and malformed configuration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);

    try std.testing.expectError(
        error.NoMounts,
        Static.init(.{ .io = io, .cwd = tmp.dir, .mounts = &.{} }, middlewareConfig(std.testing.allocator)),
    );
    for ([_][]const u8{ "", "/absolute", "C:/absolute", "\\\\server", "bad\x00path" }) |directory_path| {
        try std.testing.expectError(
            error.InvalidDirectoryPath,
            Static.init(.{
                .io = io,
                .cwd = tmp.dir,
                .mounts = &.{.{
                    .url_prefix = "/assets",
                    .directory_path = directory_path,
                }},
            }, middlewareConfig(std.testing.allocator)),
        );
    }
    try std.testing.expectError(
        error.InvalidPrefix,
        Static.init(.{
            .io = io,
            .cwd = tmp.dir,
            .mounts = &.{.{ .url_prefix = "assets", .directory_path = "assets" }},
        }, middlewareConfig(std.testing.allocator)),
    );
    try std.testing.expectError(
        error.DuplicatePrefix,
        Static.init(.{
            .io = io,
            .cwd = tmp.dir,
            .mounts = &.{
                .{ .url_prefix = "/assets", .directory_path = "assets" },
                .{ .url_prefix = "/assets/", .directory_path = "assets" },
            },
        }, middlewareConfig(std.testing.allocator)),
    );
    try std.testing.expectError(
        error.InvalidContentType,
        Static.init(.{
            .io = io,
            .cwd = tmp.dir,
            .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
            .mime_overrides = &.{.{
                .extension = ".unsafe",
                .content_type = "text/plain\r\nX-Injected: true",
            }},
        }, middlewareConfig(std.testing.allocator)),
    );
}

test "init propagates root opening failures after closing earlier roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "present", .default_dir);

    try std.testing.expectError(
        error.FileNotFound,
        Static.init(.{
            .io = io,
            .cwd = tmp.dir,
            .mounts = &.{
                .{ .url_prefix = "/present", .directory_path = "present" },
                .{ .url_prefix = "/missing", .directory_path = "missing" },
            },
        }, middlewareConfig(std.testing.allocator)),
    );

    try tmp.dir.deleteDir(io, "present");
}

test "init does not follow a symlink used as a mount root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "target", .default_dir);
    tmp.dir.symLink(io, "target", "linked-root", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.SkipZigTest,
        else => return err,
    };

    if (Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "linked-root" }},
    }, middlewareConfig(std.testing.allocator))) |result| {
        var static = result;
        static.deinit();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.FileNotFound, error.SymLinkLoop, error.NotDir => {},
        else => return err,
    }
}

test "directory paths allow trusted relative parent segments" {
    try std.testing.expect(isRelativeDirectoryPath("../shared/assets"));
    try std.testing.expect(isRelativeDirectoryPath("./assets"));
}

test "init cleans up every allocation failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try tmp.dir.createDir(io, "images", .default_dir);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initWithAllocationFailures,
        .{ io, tmp.dir },
    );
}

fn initWithAllocationFailures(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
) !void {
    var static = try Static.init(.{
        .io = io,
        .cwd = cwd,
        .mounts = &.{
            .{ .url_prefix = "/assets", .directory_path = "assets" },
            .{ .url_prefix = "/images", .directory_path = "images" },
        },
        .mime_overrides = &.{.{
            .extension = ".jsonl",
            .content_type = "application/x-ndjson",
        }},
    }, middlewareConfig(allocator));
    defer static.deinit();
}

fn middlewareConfig(allocator: std.mem.Allocator) httpz.MiddlewareConfig {
    return .{ .arena = allocator, .allocator = allocator };
}
