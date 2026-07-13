# httpz-static Documentation

- [README](../README.md) — installation, finalized API usage, configuration, behavior, and validation commands
- [Runnable example](../examples/basic.zig) — minimal httpz server serving `examples/public/`
- [Specification](../SPEC.md) — normative middleware contract, architecture, security model, and boundaries
- [Changelog](../CHANGELOG.md) — release-facing changes
- [Repository rules](../AGENTS.md) — workflow and contribution contract
- [Licence](../LICENSE) — MIT licence

## Quick validation

With Zig 0.16.0:

```sh
zig build ci
zig build example
```

Use `zig build run-example` to start the example on `http://localhost:8080`.
