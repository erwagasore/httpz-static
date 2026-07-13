# Changelog

## [Unreleased]

### Added

- Zig 0.16.0 package and build steps for formatting, compile checks, tests, CI, and the runnable example.
- httpz middleware registration with multiple explicit URL-prefix mounts and longest-prefix routing.
- Static `GET` and bodyless `HEAD` responses with MIME detection, custom MIME overrides, and accurate wire-level `Content-Length` headers.
- Configurable missing-file fallthrough or strict `404 Not Found` behavior.
- A 64 MiB default file-size limit with configurable bounds and explicit unlimited opt-in.
- Unit tests and a real-server httpz integration suite.
- A runnable basic server under `examples/`.

### Security

- Validate raw paths, decode percent escapes exactly once, and reject traversal, ambiguous encoding, encoded separators, backslashes, NUL bytes, and platform-rooted paths.
- Resolve request paths component by component beneath retained mount handles without following root, intermediate, or final symlinks.
- Serve only regular files and return indistinguishable unavailable-file responses under strict mode.
