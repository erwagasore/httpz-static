# Plan — First working static-file middleware

Deliver the first working `httpz-static` release with secure mount resolution, static-file responses, and full Zig 0.16.0 test coverage.

## How to use

1. Pick the next unblocked task.
2. Create a dedicated branch and merge the task through a PR.
3. Tick the task when merged.

## Phase 1 — Foundation

- [x] **chore(build): scaffold the Zig package**

  Add `build.zig`, `build.zig.zon`, and `src/root.zig`; pin httpz; and provide formatting, compile-check, test, and local CI build steps. Follow the testing contract and initial source layout in `SPEC.md:157` and `SPEC.md:180`.

  *Done when:* Zig 0.16.0 can fetch dependencies, format the package, compile the root module, and run the initial test suite through the documented local CI step.

- [x] **feat(path): implement secure mount resolution**

  Add mount-prefix validation and normalization, duplicate detection support, longest-prefix matching with segment boundaries, and secure relative-path validation in `src/path.zig`, with focused unit tests. Validate raw `req.url.path`, percent-decode exactly once into the request arena, then validate the decoded path before filesystem access, following `SPEC.md:89` and `SPEC.md:116`.

  *Done when:* Tests cover malformed and duplicate normalized prefixes, overlapping mounts, segment boundaries, and rejection of plain, encoded, and double-encoded traversal; malformed escapes; encoded separators; absolute paths; backslashes; and NUL bytes before filesystem access.

- [ ] **feat(mime): add content type detection**

  Add a compact static extension-to-MIME table and public `MimeMapping` override type in `src/mime.zig`, with ASCII case-insensitive matching, user-override precedence and validation, conventional UTF-8 charsets for textual types, and the required unknown-extension fallback. Follow `SPEC.md:103`, `SPEC.md:137`, and `SPEC.md:180` without adding a generated or runtime-allocated MIME registry.

  *Done when:* Unit tests verify representative binary and textual extensions, mixed-case extensions, charset values, custom additions, built-in overrides, safe media-type validation, arena-backed MIME-resolver ownership and allocation-failure cleanup, duplicate rejection, and `application/octet-stream` for unknown or absent extensions.

## Phase 2 — Middleware

- [ ] **feat(middleware): manage configured mount roots**

  Implement `Mount`, `Config`, `init`, and `deinit` in `src/root.zig` using httpz's middleware arena/allocator lifecycle; initialize the MIME resolver with `MiddlewareConfig.allocator` rather than its arena; open configured directories once relative to the working directory with no-follow behavior where supported; reject invalid configuration; and clean up all owned handles and allocations, including partial initialization failures. Follow `SPEC.md:40`, `SPEC.md:89`, and `SPEC.md:149`.

  *Done when:* Tests verify valid multi-mount and MIME-resolver initialization, malformed and duplicate-prefix rejection, retained root handles, deterministic teardown, and cleanup after initialization or allocation failure.

- [ ] **feat(middleware): serve static file requests**

  Implement `execute` in `src/root.zig` for direct relative lookup beneath the selected retained root, regular-file `GET`, and bodyless `HEAD`; stat before allocation, enforce `Config.max_file_size`, set accurate headers, and use `executor.next()` for method or configured missing-file fallthrough. Follow `SPEC.md:103` and `SPEC.md:137`.

  *Done when:* Middleware tests verify successful `GET` and allocation-free `HEAD` with matching headers, MIME fallback, configured size limits, methods outside the contract, missing and non-regular files, both missing-file policies, no per-request mount-tree walk, and propagation of unexpected filesystem failures.

## Phase 3 — Verification and documentation

- [ ] **test(integration): verify middleware behavior with httpz**

  Add real-server integration tests under `tests/` and complete security-sensitive coverage for raw-path handling, single decoding, symlink confinement, filesystem errors, size limits, and allocation-failure cleanliness. Satisfy the path-security and testing contracts in `SPEC.md:116` and `SPEC.md:157`.

  *Done when:* The package passes its local CI gate on Zig 0.16.0, including a real httpz request/response test, encoded and double-encoded attack cases, allocation-free `HEAD`, and all specified confinement and cleanup cases.

- [ ] **docs(api): document the finalized middleware API**

  Update `SPEC.md` first, then synchronize `README.md`, `docs/index.md`, and `CHANGELOG.md` with the implemented API, configuration, behavior, security posture, and local validation commands. Resolve the implementation-spike caveat in `SPEC.md:40` and preserve the documented structure from `SPEC.md:180`.

  *Done when:* Public examples compile against the finalized API, all user-facing behavior matches the implementation, and the changelog records the release-facing changes.

## Ordering and parallelism

- Task 1 precedes all implementation work.
- Tasks 2 and 3 can proceed in parallel after Task 1.
- Task 4 depends on Tasks 1 and 2.
- Task 5 depends on Tasks 2, 3, and 4.
- Task 6 depends on Tasks 4 and 5.
- Task 7 follows implementation and verification so it documents the finalized behavior.
