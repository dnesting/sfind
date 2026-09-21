# sfind

Implements the `find` command backed by macOS Spotlight (MDQuery) instead of a filesystem
walk. On indexed trees, queries that would walk millions of inodes return in milliseconds.

## Status

Early but functional: every option, primary, and operator in [SPEC.md](SPEC.md) is
implemented with per-option tests, a `/usr/bin/find` parity suite (~80 expressions
compared byte-for-byte), and live-index integration tests. Not yet battle-tested;
expect rough edges. No releases yet.

See [SPEC.md](SPEC.md) for how each `find` feature maps onto the Spotlight query vs.
post-filtering (and the known divergences of an index-backed design), and
[PLAN.md](PLAN.md) for the implementation plan.

## Design in one paragraph

sfind parses the BSD `find` command line, translates as much of the expression as possible
into one MDQuery (a recall-oriented over-approximation), then re-verifies every predicate
exactly with `lstat`/`fnmatch`/`regexec` before running actions — *the index narrows, the
post-filter decides*. Predicates Spotlight can't help with (permissions, inode, atime, …)
are handled entirely by the post-filter. Files Spotlight can't see at all (dotfiles,
symlinks, excluded trees) are a documented gap: by default sfind warns when your
expression or search root provably depends on them, and `--walk` fills the gap with a
filesystem walk that visits only what the index cannot hold.

## Walking the gaps

`--walk` supplements the index rather than replacing it: the index still answers for
everything it holds, and a walk covers only dot entries, symlinks and special files,
`.noindex` / `.metadata_never_index` / bundle subtrees, directories missing from the
index's own folder list (privacy exclusions, most of `~/Library`), and roots the index
has nothing for. Regular files in indexed directories cost the walk no `stat`, so the
combination stays well ahead of a plain `find`. Small scopes are walked outright, skipping
the index's startup cost.

```sh
sfind ~ --walk -name '*.env'              # dotfiles included; the index still narrows
sfind ~ --walk --progress -type l         # symlinks (never indexed), with a status line
sfind ~/Documents -content invoice        # sfind extension: Spotlight full-text search
sfind ~/Projects --debug -name '*.env'    # explain where it looked and what it saw
```

`--walk=only` never consults the index (equivalent to `find`), for when the index is stale
or the intent is "find something" rather than "query Spotlight". See the `--walk` entry
and known divergences in [SPEC.md](SPEC.md) for what the gap walk can and cannot see.

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
