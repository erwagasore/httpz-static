# SPEC — httpz-static

Architecture, public contract, boundaries, and structural decisions.

## Purpose

`httpz-static` is a focused middleware for serving files through httpz. An application supplies one or more explicit mappings from URL prefixes to filesystem directories. The middleware handles matching safe file requests and otherwise yields to the remaining middleware/route chain according to its configured missing-file policy.

The package follows Zig 0.16.0 and the current httpz middleware API.

## Responsibility boundary

The package owns only behavior intrinsic to static-file serving:

- ordered configuration of multiple directory mounts,
- URL-prefix matching,
- secure root-confined path resolution,
- opening and serving regular files,
- `GET` and `HEAD` semantics,
- MIME type selection,
- `Content-Length`,
- configurable fallthrough or `404` for missing files,
- filesystem handle and allocation teardown.

The package does not own:

- filesystem watching or browser reload,
- rebuilding or process supervision,
- response compression,
- general cache policy,
- authentication or authorization,
- request logging,
- rate limiting,
- directory listings,
- SPA fallback,
- asset compilation or transformation.

Watching belongs to development tooling such as a separate `httpz-livereload` watcher API. Compression and other response-wide behavior belong to independent middleware that can also apply to HTML and API responses.

## Intended public API

The initial API target is:

```zig
const Static = @import("httpz-static");

const static = try server.middleware(Static, .{
    .io = init.io,
    .cwd = .cwd(),
    .mounts = &.{
        .{
            .url_prefix = "/assets",
            .directory_path = "static/assets",
        },
        .{
            .url_prefix = "/images",
            .directory_path = "content/images",
        },
    },
    .fallthrough = true,
    .mime_overrides = &.{
        .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
    },
});
```

The implementation spike may adjust field spelling to fit Zig and std.Io conventions, but not the responsibility boundary. `Config.max_file_size` is optional and defaults to unlimited; applications can set it to bound per-request file-body allocation.

The root module exposes the normal httpz middleware contract:

```zig
pub const Mount = struct { ... };
pub const MimeMapping = struct {
    extension: []const u8,
    content_type: []const u8,
};
pub const Config = struct { ... };

pub fn init(config: Config, mc: httpz.MiddlewareConfig) !Static;
pub fn deinit(self: *Static) void;
pub fn execute(
    self: *Static,
    req: *httpz.Request,
    res: *httpz.Response,
    executor: anytype,
) !void;
```

## Mount semantics

Each mount maps exactly one URL prefix to one directory. This gives every filesystem root an explicit public namespace and avoids implicit search-path behavior.

- Prefixes must begin with `/` and must not contain empty interior segments, `.` or `..` segments, backslashes, percent escapes, NUL bytes, or query/fragment markers.
- Prefixes are normalized without a trailing slash, except `/` itself.
- Matching respects segment boundaries: `/assets` matches `/assets/logo.svg` but not `/assets-old/logo.svg`.
- When prefixes overlap, the longest matching prefix wins regardless of declaration order.
- Duplicate normalized prefixes are rejected during initialization.
- Directory paths must be non-empty filesystem paths resolved relative to the configured working directory. Trusted `.` and `..` segments are allowed, while absolute, drive-qualified, NUL-containing, and platform-rooted forms are rejected.
- The middleware opens configured roots during initialization without following a final directory symlink and closes owned handles during teardown.

Overlay/search-path directories under one prefix are outside the first release. They can be added later only with explicit precedence semantics.

## Request behavior

- Requests outside every configured prefix call `executor.next()`.
- Matching `GET` requests serve the selected regular file.
- Matching `HEAD` requests return the same status and headers as `GET` without a body.
- Other methods call `executor.next()` so another application handler can decide their semantics.
- Directories are not listed or served as implicit index files in the first release.
- Non-regular filesystem entries are treated as missing.
- When a matched file is missing, `fallthrough = true` calls `executor.next()` and `fallthrough = false` returns `404`.
- Unexpected filesystem failures propagate as server errors rather than being disguised as missing files.

Successful responses include an extension-derived `Content-Type` and accurate `Content-Length`. Extension matching is ASCII case-insensitive. Textual types include an appropriate UTF-8 charset where conventional, and unknown extensions use `application/octet-stream`. `Config.mime_overrides` defaults to an empty slice; configured mappings are checked before the built-in table, allowing applications to add new extensions or replace built-in content types.

## Path security

Root confinement is a correctness requirement, not an optional feature.

Before opening a file, the middleware must reject paths containing or resolving through:

- `..` traversal segments,
- absolute filesystem paths,
- backslash-based traversal,
- NUL bytes,
- percent-encoded traversal or separator ambiguity,
- platform-specific path forms that escape the selected root.

The pinned httpz version exposes `req.url.path` as the raw request path with the query removed but without percent-decoding. The middleware first validates that raw representation, rejecting malformed escapes and encoded traversal or separator ambiguity. It then percent-decodes exactly once into the request arena and validates the decoded relative path again before any filesystem access. A decoded path that still contains any syntactically valid percent escape is rejected as ambiguous rather than decoded a second time.

Configured root directories are opened once during initialization. Request lookup opens the validated relative path directly beneath the selected root; it must not scan or walk the entire mount tree per request.

Symlink behavior must be tested and documented before the first release. The default posture is deny escape through symlinks; if Zig's portable std.Io surface cannot guarantee that policy, initialization or lookup must fail safely rather than claim confinement it does not provide.

Unsafe paths are not passed to filesystem APIs. They receive `404` or fall through according to the same non-disclosure policy as missing files.

## Response and allocation model

The implementation spike must choose the most direct httpz response path supported by the pinned dependency. Files must not be retained across requests. Any per-request path or body allocation uses the shared request/response arena and dies after the response is transmitted.

File metadata is obtained before body allocation. `HEAD` follows the same validation, lookup, regular-file, size-limit, and header path as `GET`, then returns without allocating or reading a file body.

`Config.max_file_size` is `?u64` and defaults to `null` (unlimited). When configured, a regular file larger than the limit is treated as unavailable and follows the configured fallthrough or strict `404` policy. The limit is checked from file metadata before converting the size to `usize` or allocating a body.

The middleware uses a compact, static MIME table with ASCII case-insensitive extension matching and an optional, linearly searched slice of user overrides; it does not generate or allocate a runtime MIME registry. Override extensions and the media `type/subtype` are validated during initialization, duplicate override extensions are rejected case-insensitively, and optional parameter bytes are treated as opaque printable ASCII so they cannot inject response headers. The internal MIME resolver deep-copies the override slice and both strings in every mapping into a dedicated arena backed by `httpz.MiddlewareConfig.allocator`, never `MiddlewareConfig.arena`, and releases its arena during teardown. This provides deterministic rollback and cleanup, and callers do not need to retain configuration memory.

The middleware does not add cache-control, ETag, compression, range, `X-Content-Type-Options`, or transformation behavior. Such features remain independently composable.

## Errors and diagnostics

- Invalid static configuration, including an empty mount list, malformed mount paths, and malformed or duplicate MIME overrides, fails middleware initialization.
- Configuration errors use a closed package error set where practical.
- Missing files and unsafe paths are ordinary request outcomes, not logged server failures.
- Permission, I/O, allocation, and unexpected filesystem errors propagate.
- The middleware does not write process output or initialize a logging backend.

## Testing contract

Tests are colocated with implementation where practical and use temporary directories. The first release covers:

- multiple independent mounts,
- longest-prefix selection,
- prefix segment boundaries,
- empty-mount, duplicate and malformed-prefix, and malformed-directory-path rejection,
- successful `GET`,
- bodyless `HEAD` with matching headers,
- case-insensitive MIME detection, textual charsets, user-override precedence and validation, and unknown-extension fallback,
- fallthrough and strict `404`,
- configured file-size limits for `GET` and `HEAD` without body allocation,
- missing files and non-regular entries,
- traversal through plain, encoded, and double-encoded forms,
- malformed percent escapes, encoded separators, backslash, NUL, and absolute-path rejection,
- symlink confinement,
- initialization cleanup after partial failure,
- allocation-failure cleanliness,
- a real httpz server integration test.

The local CI gate will run formatting, compile checks, and tests under Zig 0.16.0.

## Initial source layout

```text
build.zig              # build graph and fmt/check/test/ci steps
build.zig.zon          # package metadata, version, Zig minimum, pinned httpz
src/root.zig           # public middleware contract and orchestration
src/path.zig           # prefix matching and secure relative-path validation
src/mime.zig           # extension-to-content-type mapping
tests/                 # real-server integration fixtures/tests when needed
README.md              # overview and public usage
SPEC.md                # normative implementation contract
AGENTS.md               # operating contract and repo map
CHANGELOG.md            # release history
docs/index.md           # documentation index
LICENSE                 # MIT
```

The final source split should remain small. Do not create abstractions until a module has a distinct testable responsibility.
