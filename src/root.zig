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
pub const default_max_file_size: u64 = 64 * 1024 * 1024;

pub const Config = struct {
    /// Borrowed I/O implementation that must outlive the middleware.
    io: std.Io,
    /// Borrowed only while `init` opens mount roots; the caller retains ownership.
    cwd: std.Io.Dir = .cwd(),
    /// Borrowed only during initialization; all retained values and handles are owned.
    mounts: []const Mount,
    /// Continue the httpz chain when a matched file is unavailable or unsafe.
    fallthrough: bool = true,
    /// Maximum served file size in bytes. Set to `null` only for trusted,
    /// externally bounded asset trees when unlimited request memory is acceptable.
    max_file_size: ?u64 = default_max_file_size,
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
/// Parallel arrays: each prefix and root at the same index describe one mount.
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
    std.debug.assert(self.roots.len == self.prefixes.len);
    std.Io.Dir.closeMany(self.io, self.roots);
    self.mime_resolver.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// Serves a matching request. `GET` buffers the complete file in `res.arena`,
/// so peak request memory is approximately the served file size.
pub fn execute(
    self: *Static,
    req: *httpz.Request,
    res: *httpz.Response,
    executor: anytype,
) !void {
    if (req.method != .GET and req.method != .HEAD) return executor.next();

    std.debug.assert(self.roots.len == self.prefixes.len);
    const match = path.longestMatch(req.url.path, self.prefixes) orelse
        return executor.next();
    const relative_path = path.decodeAndValidate(req.arena, match.relative_path) catch |err| switch (err) {
        error.MalformedEscape, error.UnsafePath => return self.unavailable(res, executor),
        else => return err,
    };
    if (relative_path.len == 0) return self.unavailable(res, executor);

    const opened = openConfinedFile(self.roots[match.index], self.io, relative_path) catch |err| {
        if (isUnavailableOpenError(err)) return self.unavailable(res, executor);
        return err;
    };
    defer opened.file.close(self.io);

    if (self.max_file_size) |limit| {
        if (opened.stat.size > limit) return self.unavailable(res, executor);
    }
    const size = std.math.cast(usize, opened.stat.size) orelse return error.FileTooBig;

    var allocated_body: ?[]u8 = null;
    errdefer if (allocated_body) |body| res.arena.free(body);
    if (req.method == .GET) {
        const body = try res.arena.alloc(u8, size);
        allocated_body = body;
        const bytes_read = try opened.file.readPositionalAll(self.io, body, 0);
        if (bytes_read != size) return error.UnexpectedEndOfFile;
    }

    const content_length = if (req.method == .HEAD)
        try std.fmt.allocPrint(res.arena, "{d}", .{opened.stat.size})
    else
        null;
    res.status = 200;
    res.header("Content-Type", self.mime_resolver.fromPath(relative_path));
    if (content_length) |value| res.header("Content-Length", value);
    res.body = allocated_body orelse "";
}

fn unavailable(self: *Static, res: *httpz.Response, executor: anytype) !void {
    if (self.fallthrough) return executor.next();
    res.status = 404;
    res.body = "Not Found";
}

const OpenedFile = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

fn openConfinedFile(root: std.Io.Dir, io: std.Io, relative_path: []const u8) !OpenedFile {
    var segments = std.mem.splitScalar(u8, relative_path, '/');
    var component = segments.next() orelse return error.IsDir;
    var current = root;
    var owned_current: ?std.Io.Dir = null;
    defer if (owned_current) |dir| dir.close(io);

    while (segments.next()) |next| {
        const child = try current.openDir(io, component, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        if (owned_current) |dir| dir.close(io);
        owned_current = child;
        current = child;
        component = next;
    }

    const path_stat = try current.statFile(io, component, .{ .follow_symlinks = false });
    if (path_stat.kind != .file) return error.NotRegularFile;

    const file = try current.openFile(io, component, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    return .{ .file = file, .stat = stat };
}

fn isUnavailableOpenError(err: anyerror) bool {
    return switch (err) {
        error.BadPathName,
        error.FileNotFound,
        error.IsDir,
        error.NameTooLong,
        error.NotDir,
        error.NotRegularFile,
        error.SymLinkLoop,
        => true,
        else => false,
    };
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

test "execute serves GET from the longest matching mount" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try tmp.dir.createDir(io, "icons", .default_dir);
    try writeTestFile(tmp.dir, io, "assets/logo.txt", "general");
    try writeTestFile(tmp.dir, io, "icons/logo.txt", "specific");

    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{
            .{ .url_prefix = "/assets", .directory_path = "assets" },
            .{ .url_prefix = "/assets/icons", .directory_path = "icons" },
        },
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/assets/icons/logo.txt");
    var executor: TestExecutor = .{};
    try static.execute(ht.req, ht.res, &executor);

    try std.testing.expect(!executor.next_called);
    try std.testing.expectEqual(@as(?u64, default_max_file_size), static.max_file_size);
    const response = try ht.parseResponse();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("specific", response.body);
    try std.testing.expectEqualStrings(
        "text/plain; charset=utf-8",
        response.headers.get("Content-Type").?,
    );
    try std.testing.expectEqualStrings("8", response.headers.get("Content-Length").?);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, response.raw, "\r\nContent-Length:"),
    );

    _ = httpz.Middleware(void).init(&static);
}

test "execute serves HEAD headers without reading or allocating a body" {
    const inner_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(inner_io, "assets", .default_dir);
    try writeTestFile(tmp.dir, inner_io, "assets/site.css", "body { color: black; }");

    var counting_io = CountingIo.init(inner_io);
    const io = counting_io.io();
    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.req.method = .HEAD;
    ht.url("/assets/site.css");
    var executor: TestExecutor = .{};
    try static.execute(ht.req, ht.res, &executor);

    try std.testing.expect(!executor.next_called);
    const response = try ht.parseResponse();
    try std.testing.expectEqualStrings("", response.body);
    try std.testing.expectEqualStrings(
        "text/css; charset=utf-8",
        response.headers.get("Content-Type").?,
    );
    try std.testing.expectEqualStrings("22", response.headers.get("Content-Length").?);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, response.raw, "\r\nContent-Length:"),
    );
    try std.testing.expectEqual(@as(usize, 0), counting_io.file_read_count);
    try std.testing.expectEqual(@as(usize, 1), counting_io.closed_file_count);
}

test "execute falls through for methods, unmatched paths, missing files, and unsafe paths" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try writeTestFile(tmp.dir, io, "assets/app.js", "alert('ok');");

    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    try expectNext(&static, .POST, "/assets/app.js");
    try expectNext(&static, .GET, "/other/app.js");
    try expectNext(&static, .GET, "/assets/missing.js");
    try expectNext(&static, .GET, "/assets/%2e%2e/secret.txt");
}

test "execute returns indistinguishable strict not-found responses" {
    const inner_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(inner_io, "assets", .default_dir);
    try tmp.dir.createDir(inner_io, "assets/subdir", .default_dir);
    try writeTestFile(tmp.dir, inner_io, "assets/large.bin", "12345");

    var counting_io = CountingIo.init(inner_io);
    const io = counting_io.io();
    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
        .fallthrough = false,
        .max_file_size = 4,
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    try expectNotFound(&static, .GET, "/assets/missing.bin");
    try expectNotFound(&static, .GET, "/assets/subdir");
    try expectNotFound(&static, .GET, "/assets/%2e%2e/secret.txt");
    try expectNotFound(&static, .GET, "/assets/large.bin");
    try expectNotFound(&static, .HEAD, "/assets/large.bin");
    try std.testing.expectEqual(@as(usize, 0), counting_io.file_read_count);
}

test "execute refuses final and intermediate symlinks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try tmp.dir.createDir(io, "assets/real", .default_dir);
    try writeTestFile(tmp.dir, io, "assets/real/file.txt", "safe");
    tmp.dir.symLink(io, "real", "assets/linked", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.SkipZigTest,
        else => return err,
    };
    try tmp.dir.symLink(io, "real/file.txt", "assets/file-link", .{});

    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
        .fallthrough = false,
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    try expectNotFound(&static, .GET, "/assets/linked/file.txt");
    try expectNotFound(&static, .GET, "/assets/file-link");
    try expectContentType(&static, "/assets/real/file.txt", "text/plain; charset=utf-8");
}

test "execute propagates unexpected file read failures" {
    const inner_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(inner_io, "assets", .default_dir);
    try writeTestFile(tmp.dir, inner_io, "assets/file.txt", "contents");

    var counting_io = CountingIo.init(inner_io);
    counting_io.fail_file_reads = true;
    const io = counting_io.io();
    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/assets/file.txt");
    var executor: TestExecutor = .{};
    try std.testing.expectError(
        error.InputOutput,
        static.execute(ht.req, ht.res, &executor),
    );
    try std.testing.expect(!executor.next_called);
    try std.testing.expectEqualStrings("", ht.res.body);
    try std.testing.expectEqual(@as(usize, 0), ht.res.headers.len);
    try std.testing.expectEqual(@as(usize, 1), counting_io.closed_file_count);

    counting_io.fail_file_reads = false;
    counting_io.short_file_reads = true;
    var short_ht = httpz.testing.init(.{});
    defer short_ht.deinit();
    short_ht.url("/assets/file.txt");
    var tracked_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    short_ht.res.arena = tracked_allocator.allocator();
    var short_executor: TestExecutor = .{};
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        static.execute(short_ht.req, short_ht.res, &short_executor),
    );
    try std.testing.expectEqual(
        tracked_allocator.allocated_bytes,
        tracked_allocator.freed_bytes,
    );
    try std.testing.expectEqual(@as(usize, 2), counting_io.closed_file_count);
}

test "execute propagates request and response allocation failures" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try writeTestFile(tmp.dir, io, "assets/file.txt", "contents");
    try writeTestFile(tmp.dir, io, "assets/hello world.txt", "hello");

    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/assets/file.txt");
        ht.res.arena = std.testing.failing_allocator;
        var executor: TestExecutor = .{};
        try std.testing.expectError(
            error.OutOfMemory,
            static.execute(ht.req, ht.res, &executor),
        );
    }
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.req.method = .HEAD;
        ht.url("/assets/file.txt");
        ht.res.arena = std.testing.failing_allocator;
        var executor: TestExecutor = .{};
        try std.testing.expectError(
            error.OutOfMemory,
            static.execute(ht.req, ht.res, &executor),
        );
    }
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/assets/hello%20world.txt");
        ht.req.arena = std.testing.failing_allocator;
        var executor: TestExecutor = .{};
        try std.testing.expectError(
            error.OutOfMemory,
            static.execute(ht.req, ht.res, &executor),
        );
    }
}

test "execute applies custom MIME mappings and binary fallback" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);
    try writeTestFile(tmp.dir, io, "assets/events.jsonl", "{}\n");
    try writeTestFile(tmp.dir, io, "assets/blob.future", "data");

    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
        .mime_overrides = &.{.{
            .extension = ".jsonl",
            .content_type = "application/x-ndjson",
        }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    try expectContentType(&static, "/assets/events.jsonl", "application/x-ndjson");
    try expectContentType(&static, "/assets/blob.future", "application/octet-stream");
}

test "registers through server.middleware" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);

    var server = try httpz.Server(void).init(io, std.testing.allocator, .{}, {});
    defer server.deinit();
    _ = try server.middleware(Static, .{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
    });
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

test "init closes earlier roots after a later root fails to open" {
    const inner_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(inner_io, "present", .default_dir);

    var counting_io = CountingIo.init(inner_io);
    const io = counting_io.io();
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
    try std.testing.expectEqual(@as(usize, 1), counting_io.closed_dir_count);
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

test "init opens trusted parent-relative directory paths" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "base", .default_dir);
    try tmp.dir.createDir(io, "shared", .default_dir);
    const base = try tmp.dir.openDir(io, "base", .{});
    defer base.close(io);

    var static = try Static.init(.{
        .io = io,
        .cwd = base,
        .mounts = &.{.{ .url_prefix = "/shared", .directory_path = "../shared" }},
    }, middlewareConfig(std.testing.allocator));
    defer static.deinit();

    _ = try static.roots[0].stat(io);
}

test "init uses MiddlewareConfig.allocator for owned state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "assets", .default_dir);

    var static = try Static.init(.{
        .io = io,
        .cwd = tmp.dir,
        .mounts = &.{.{ .url_prefix = "/assets", .directory_path = "assets" }},
    }, .{
        .arena = std.testing.failing_allocator,
        .allocator = std.testing.allocator,
    });
    defer static.deinit();
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

fn expectNext(static: *Static, method: httpz.Method, url: []const u8) !void {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.req.method = method;
    ht.url(url);
    var executor: TestExecutor = .{};

    try static.execute(ht.req, ht.res, &executor);
    try std.testing.expect(executor.next_called);
    try std.testing.expectEqualStrings("", ht.res.body);
    try std.testing.expectEqual(@as(usize, 0), ht.res.headers.len);
}

fn expectNotFound(static: *Static, method: httpz.Method, url: []const u8) !void {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.req.method = method;
    ht.url(url);
    var executor: TestExecutor = .{};

    try static.execute(ht.req, ht.res, &executor);
    try std.testing.expect(!executor.next_called);
    try std.testing.expectEqual(@as(u16, 404), ht.res.status);
    try std.testing.expectEqualStrings("Not Found", ht.res.body);
    try std.testing.expectEqual(@as(usize, 0), ht.res.headers.len);
}

fn expectContentType(static: *Static, url: []const u8, expected: []const u8) !void {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url(url);
    var executor: TestExecutor = .{};

    try static.execute(ht.req, ht.res, &executor);
    try std.testing.expect(!executor.next_called);
    const response = try ht.parseResponse();
    try std.testing.expectEqualStrings(expected, response.headers.get("Content-Type").?);
}

const TestExecutor = struct {
    next_called: bool = false,

    fn next(self: *TestExecutor) !void {
        self.next_called = true;
    }
};

fn writeTestFile(dir: std.Io.Dir, io: std.Io, file_path: []const u8, contents: []const u8) !void {
    const file = try dir.createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

const CountingIo = struct {
    inner: std.Io,
    vtable: std.Io.VTable,
    closed_dir_count: usize = 0,
    closed_file_count: usize = 0,
    file_read_count: usize = 0,
    fail_file_reads: bool = false,
    short_file_reads: bool = false,

    fn init(inner: std.Io) CountingIo {
        var result: CountingIo = .{
            .inner = inner,
            .vtable = inner.vtable.*,
        };
        result.vtable.dirOpenDir = openDir;
        result.vtable.dirOpenFile = openFile;
        result.vtable.dirStatFile = statPath;
        result.vtable.dirClose = closeDirs;
        result.vtable.fileStat = statFile;
        result.vtable.fileClose = closeFiles;
        result.vtable.fileReadPositional = readFilePositional;
        return result;
    }

    fn io(self: *CountingIo) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn get(userdata: ?*anyopaque) *CountingIo {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn openDir(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        sub_path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        const self = get(userdata);
        return self.inner.vtable.dirOpenDir(self.inner.userdata, dir, sub_path, options);
    }

    fn openFile(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        sub_path: []const u8,
        options: std.Io.Dir.OpenFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const self = get(userdata);
        return self.inner.vtable.dirOpenFile(self.inner.userdata, dir, sub_path, options);
    }

    fn statPath(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        sub_path: []const u8,
        options: std.Io.Dir.StatFileOptions,
    ) std.Io.Dir.StatFileError!std.Io.File.Stat {
        const self = get(userdata);
        return self.inner.vtable.dirStatFile(self.inner.userdata, dir, sub_path, options);
    }

    fn closeDirs(userdata: ?*anyopaque, dirs: []const std.Io.Dir) void {
        const self = get(userdata);
        self.closed_dir_count += dirs.len;
        self.inner.vtable.dirClose(self.inner.userdata, dirs);
    }

    fn statFile(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const self = get(userdata);
        return self.inner.vtable.fileStat(self.inner.userdata, file);
    }

    fn closeFiles(userdata: ?*anyopaque, files: []const std.Io.File) void {
        const self = get(userdata);
        self.closed_file_count += files.len;
        self.inner.vtable.fileClose(self.inner.userdata, files);
    }

    fn readFilePositional(
        userdata: ?*anyopaque,
        file: std.Io.File,
        data: []const []u8,
        offset: u64,
    ) std.Io.File.ReadPositionalError!usize {
        const self = get(userdata);
        self.file_read_count += 1;
        if (self.fail_file_reads) return error.InputOutput;
        if (self.short_file_reads) return 0;
        return self.inner.vtable.fileReadPositional(self.inner.userdata, file, data, offset);
    }
};

fn middlewareConfig(allocator: std.mem.Allocator) httpz.MiddlewareConfig {
    return .{ .arena = allocator, .allocator = allocator };
}
