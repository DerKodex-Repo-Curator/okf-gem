# Changelog

## [Unreleased]

## [0.1.0] - 2026-07-24

The read surface: an MCP server over the okf kernel, judged by the kernel's own
contracts.

### Added

- Ten read-only tools mapped straight onto the kernel's library API:
  `list_bundles`, `dirs`, `index`, `search`, `read_concept`, `catalog`, `log`,
  `validate`, `lint`, `graph`. Every list output is bounded with a visible
  `total`; annotations are honest (`readOnlyHint` on all ten); domain failures
  surface as tool errors carrying the kernel's own sentences.
- Bundle identity delegated to the kernel registry: every `bundle` argument is
  a registry slug — the identity `@slug` resolves at the CLI and `/b/<slug>/`
  mounts on the hub. Argv roots are the allowlist (refs and plain dirs mix,
  registered slugs reserved before basenames are deduped); no argv serves the
  active registry, project-local discovery and `OKF_NO_DISCOVERY` included.
  Groups fan out for `search` and are refused by every single-bundle tool;
  `"*"` tolerates a vanished directory (`skipped` named in the payload) while
  naming one demands it.
- The residency layer: one parsed bundle per root, re-read only when the
  on-disk fingerprint moves, so bodies are always live and canonical. Index
  queries hold one shared corpus per served set — federated BM25 scores are
  comparable by construction — built on first use and dropped when any member
  changes.
- The engine doctrine, the CLI's exactly: raw-text scan by default,
  `engine: "index"` opt-in for BM25+/page parity, `fuzzy` implying the index,
  `regexp` staying on the scan, incompatible pairs refused with the fix named.
- Four prompts serving the okf skill's playbooks (`okf-consume`, `okf-search`,
  `okf-maintain`, `okf-curate`), read live from the installed kernel's canonical
  skill tree.
- Two transports over one server definition: stdio (default) and `--http` —
  Streamable HTTP in stateless JSON mode on WEBrick, with non-loopback binds
  allowlisted so the SDK's DNS-rebinding protection stays on.
- The `okf-sqlite3` seam: `Backend.detect` soft-requires the engine and duck
  types it; a missing or broken build degrades to memory silently except in
  the boot line and `list_bundles.backend`.

[Unreleased]: https://github.com/serradura/okf-gem/compare/okf-mcp/v0.1.0...HEAD
[0.1.0]: https://github.com/serradura/okf-gem/releases/tag/okf-mcp%2Fv0.1.0
