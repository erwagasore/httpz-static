# httpz-static

Focused static-file middleware for [httpz](https://github.com/karlseguin/http.zig), built for Zig 0.16.0.

`httpz-static` maps explicit URL prefixes to filesystem directories, securely resolves request paths beneath retained directory handles, and serves regular files for `GET` and `HEAD`. Watching, browser reload, compression, cache policy, authentication, directory listings, and SPA fallback remain separate concerns.

## Add the module

Add `httpz-static` and its compatible pinned httpz revision to your application's `build.zig.zon`:

```sh
zig fetch --save=httpz_static git+https://github.com/erwagasore/httpz-static.git
zig fetch --save=httpz https://github.com/karlseguin/http.zig/archive/01dc09453ae50b82cc74ac2f90e9cd57e0b38500.tar.gz
```

Expose both modules to your executable:

```zig
const static_dep = b.dependency("httpz_static", .{
    .target = target,
    .optimize = optimize,
});
const httpz_dep = b.dependency("httpz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpz-static", static_dep.module("httpz-static"));
exe.root_module.addImport("httpz", httpz_dep.module("httpz"));
```

The httpz revision must match the one pinned by `httpz-static`; this keeps the framework types used by the application and middleware identical.

## Usage

Register the middleware with httpz and attach it to the router:

```zig
const Static = @import("httpz-static");

const static = try server.middleware(Static, .{
    .io = init.io,
    .mounts = &.{
        .{ .url_prefix = "/assets", .directory_path = "static/assets" },
        .{ .url_prefix = "/images", .directory_path = "content/images" },
    },
    .mime_overrides = &.{
        .{ .extension = ".jsonl", .content_type = "application/x-ndjson" },
    },
});

_ = try server.router(.{ .middlewares = &.{static} });
```

See [`examples/basic.zig`](examples/basic.zig) for a complete runnable server.

## Configuration

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `io` | `std.Io` | required | I/O implementation; it must outlive the middleware. |
| `cwd` | `std.Io.Dir` | `.cwd()` | Directory against which mount paths are opened during initialization. |
| `mounts` | `[]const Static.Mount` | required | URL-prefix to directory-path mappings; at least one is required. |
| `fallthrough` | `bool` | `true` | Continue the httpz chain when a matched file is unavailable or unsafe; `false` returns `404 Not Found`. |
| `max_file_size` | `?u64` | 64 MiB | Maximum served file size. Set `null` only when unlimited request buffering is acceptable. |
| `mime_overrides` | `[]const Static.MimeMapping` | empty | Validated, case-insensitive additions or replacements for MIME types. |

Mounts, prefixes, and MIME overrides are borrowed only during initialization; retained values are copied into middleware-owned storage. `cwd` is borrowed while roots are opened and is never closed by the middleware. `server.middleware` owns the initialized middleware and releases its directory handles and allocations during server teardown. Callers using `Static.init` directly must call `deinit` exactly once and must not copy the owning value.

URL prefixes are normalized, matched on segment boundaries, and resolved by longest matching prefix. Directory paths are trusted configuration and must be relative; `.` and `..` components are allowed, but absolute, drive-qualified, platform-rooted, NUL-containing, and empty paths are rejected.

## Request behavior

- Matching regular files are served for `GET` and `HEAD`.
- `HEAD` returns the same status and headers as `GET`, without reading or allocating a file body.
- Other methods and paths outside all mounts continue through the httpz chain.
- Missing, unsafe, oversized, directory, and non-regular paths either fall through or receive the same strict `404`, according to `fallthrough`.
- MIME matching is ASCII case-insensitive; unknown extensions use `application/octet-stream`.
- Unexpected permission, allocation, and filesystem failures propagate to httpz.

`GET` buffers the complete file in the response arena. Peak per-request response-body memory is therefore approximately the served file size. The default 64 MiB limit bounds this allocation.

## Security model

Request paths are validated in their raw form, percent-decoded exactly once into the request arena, and validated again. Traversal segments, malformed or ambiguous escapes, encoded separators, backslashes, NUL bytes, absolute paths, and platform-specific escape forms are rejected before filesystem access.

Lookup proceeds component by component relative to the selected retained root handle. Root, intermediate, and final symlinks are denied, and only regular files are served. Mounted trees are expected not to be adversarially replaced while requests are in flight because portable `std.Io` cannot make metadata checking and file opening one atomic operation.

See [`SPEC.md`](SPEC.md) for the normative contract and complete boundaries.

## Example

Build the example without running it:

```sh
zig build example
```

Run it from the repository root:

```sh
zig build run-example
curl -i http://localhost:8080/assets/hello.txt
curl -I http://localhost:8080/assets/hello.txt
```

## Development

The local CI gate requires Zig 0.16.0:

```sh
zig build fmt
zig build check
zig build test
zig build ci
```

## License

MIT
