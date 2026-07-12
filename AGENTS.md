# AGENTS — httpz-static

Operating rules for humans and AI.

## Workflow

- Never commit to `main`/`master` outside the documented bootstrap exception.
- Always start implementation work on a new branch.
- Only push after the user approves.
- Merge via PR.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).

- fix → patch
- feat → minor
- feat! / BREAKING CHANGE → major
- chore, docs, refactor, test, ci, style, perf → no version change

## Releases

- Semantic versioning.
- Versions derived from Conventional Commits.
- Release locally via `/create-release`.
- The Zig package manifest is the source of truth once it exists.
- Tags use `vX.Y.Z`.

## Repo map

- `SPEC.md` — normative middleware contract, boundaries, security rules, and implementation decisions.
- `README.md` — project overview and intended public API.
- `CHANGELOG.md` — user-facing release history.
- `docs/` — documentation index and future guides.
- `LICENSE` — MIT licence.
- `.gitignore` — Zig build/cache and local OS exclusions.

## Document precedence and sync

Normative sources:

1. `SPEC.md` — implementation and package contract.
2. `AGENTS.md` — workflow and repository operating contract.

When behavior or structure changes, update `SPEC.md` first, then this repo map, the user-facing README, and the documentation index when applicable.

## Merge strategy

- Prefer squash merge.
- PR titles must be valid Conventional Commits.

## Definition of done

- Works locally with Zig 0.16.0.
- Tests cover behavior and security-sensitive path handling.
- CHANGELOG updated for user-facing changes.
- Documentation matches the public API.
- No secrets committed.

## Orientation

- **Entry point**: Start with `SPEC.md` for the contract; implementation will live under `src/` once scaffolded.
- **Domain**: Narrow, composable static-file serving middleware for httpz.
- **Tech stack**: Zig 0.16.0, std.Io, httpz, and the Zig build system.
