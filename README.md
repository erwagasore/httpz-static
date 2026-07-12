# httpz-static

Focused static-file middleware for [httpz](https://github.com/karlseguin/http.zig).

`httpz-static` maps explicit URL prefixes to filesystem directories and serves matching files. It deliberately does not watch files, reload browsers, compress responses, or implement unrelated response policy; those concerns belong to other middleware.

## Status

Initial specification. Implementation has not landed yet.

## Intended usage

```zig
const Static = @import("httpz-static");

const static = try server.middleware(Static, .{
    .io = init.io,
    .mounts = &.{
        .{ .url_prefix = "/assets", .directory_path = "static/assets" },
        .{ .url_prefix = "/images", .directory_path = "content/images" },
    },
});

var router = try server.router(.{ .middlewares = &.{static} });
```

The exact API remains subject to the implementation spike described in [SPEC.md](SPEC.md).

## Scope

The first release targets:

- Multiple explicit directory mounts
- Secure path resolution beneath each mount
- `GET` and `HEAD`
- MIME type detection
- `Content-Length`
- Configurable missing-file fallthrough or `404`

See [SPEC.md](SPEC.md) for the full contract and non-goals.

## Structure

See [AGENTS.md](AGENTS.md#repo-map) for repository orientation.

## License

MIT
