# sfind

Implements the `find` command backed by macOS Spotlight (MDQuery) instead of a filesystem
walk. On indexed trees, queries that would walk millions of inodes return in milliseconds.

## Status

Scaffolding. Nothing usable yet.

See [SPEC.md](SPEC.md) for the list of `find` options and how each maps onto the Spotlight
query vs. post-filtering, and [PLAN.md](PLAN.md) for the implementation plan.

## Design in one paragraph

sfind parses the BSD `find` command line, translates as much of the expression as possible
into one MDQuery (a recall-oriented over-approximation), then re-verifies every predicate
exactly with `lstat`/`fnmatch`/`regexec` before running actions — *the index narrows, the
post-filter decides*. Predicates Spotlight can't help with (permissions, inode, atime, …)
are handled entirely by the post-filter. Files Spotlight can't see at all (dotfiles,
symlinks, excluded trees) are a documented gap: sfind warns when your expression or search
root provably depends on them.

## Building

```sh
make build          # release build
make test           # unit + parity tests (no Spotlight needed)
make integration-test  # opt-in tests against the real Spotlight index (fixtures under $HOME)
make install        # install to /usr/local/bin (PREFIX=~/.local for a user install)
```

## Developing

**Xcode**: `open Package.swift` (or `xed .`). The shared `sfind` scheme builds the CLI, and
⌘U runs the unit and parity suites with coverage enabled; the Spotlight integration suite is
wired to the scheme's `SFIND_INTEGRATION` environment variable, which ships disabled — flip
it on in Product → Scheme → Edit Scheme → Test when you want the real-index tests.

**VS Code**: open the folder and accept the recommended extensions (the official Swift
extension provides build/test/debug and format-on-save using the repo's `.swift-format`
config). `.vscode/tasks.json` exposes build/test/lint/format/integration-test, and
`.vscode/launch.json` has a ready debug configuration for the CLI.

Formatting is enforced in CI via `swift format lint --strict` (`make lint`); `make format`
or format-on-save keeps you clean. `.editorconfig` covers both editors.

## Compatibility

BSD/macOS `find` semantics are ground truth; the test suite uses `/usr/bin/find` as its
parity oracle. Conflict-free GNU extensions (`-perm /mode`, `-printf`, `-regextype`, …) are
supported. See [SPEC.md](SPEC.md) for per-option dialect notes and the known divergences
inherent to an index-backed design.

## License

Apache-2.0. See [LICENSE](LICENSE).
