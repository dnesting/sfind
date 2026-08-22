# sfind — Implementation Plan

## Context

`sfind` reimplements the `find` command backed by macOS Spotlight (MDQuery) instead of a
filesystem walk, for speed. Deliverables: the Swift implementation, the [SPEC.md](SPEC.md)
coverage ledger (a checkbox per find option with its MDQuery-vs-post-filter determination),
Apache-2.0 licensing, unit tests organized per option, `find`-parity fixture tests,
real-Spotlight integration tests, CI on push/PR, tag-triggered releases with
signing/notarization plumbing (ad-hoc now, Developer ID flip-on later), and `make install`.

Facts below marked "verified" were confirmed empirically against `/usr/bin/find` and the live
Spotlight index on macOS 26.5 (find man page dated December 2023).

## Design decisions

1. **Dialect**: BSD/macOS `find` semantics are ground truth; the parity oracle is
   `/usr/bin/find`. Conflict-free GNU spellings are adopted as extensions: `-perm /mode`
   (alias of BSD `+mode`), `-printf`, `-regextype`, `-readable`/`-writable`/`-executable`,
   `-daystart`. `-regex`/`-iregex` default to BSD BRE (ERE with `-E`); GNU `-regextype` is the
   explicit opt-in to other dialects. SPEC.md documents every BSD/GNU divergence per option.
2. **Coverage gap policy**: index-only. No filesystem-walk fallback in v1 (`--walk PATH` and
   conjunct-narrowed walking are SPEC.md "future work"). Two gap types, handled differently:
   - *Attributes Spotlight doesn't index* → always-on `lstat`-based post-filtering of
     candidates.
   - *Files Spotlight can't see* (dotfiles, symlinks, bundle contents, excluded/unindexed
     paths) → stderr **warnings**, both predicate-level (expression provably needs invisible
     files) and scope-level (search root appears unindexed).
3. **Actions**: full set, sequenced: `-print`/`-print0` → `-ls` → `-exec`/`-execdir`/`-ok`/
   `-okdir` → `-delete` (extra safety tests).
4. **Releases**: tag push → universal (arm64+x86_64) tarball; ad-hoc signed now, Developer ID
   + notarization dormant behind repo secrets.
5. **License**: Apache-2.0. Performance matters: batch and parallelize.

## Core architecture

**Principle: the index narrows, the post-filter decides.** The MDQuery is a recall-oriented
candidate generator (must produce a superset of true matches among indexed files); every
predicate is then re-verified authoritatively in the post-filter (fnmatch/lstat/regexec/…).
Correctness never depends on index precision; the index affects only completeness (a
documented gap) and speed. This also makes expression semantics fully testable without
Spotlight.

Pipeline:

```
argv → OptionParser → Options + Expression AST
    → Planner → Plan { mdqueryString, scopes, globals(maxdepth/mindepth/xdev/…), warnings }
    → CandidateSource (MDQuerySource | ArraySource for tests) → candidate paths
    → PostFilter (parallel, batched lstat + full AST evaluation) → matches
    → Actions (-print/-ls/-exec/-delete…) with find-compatible exit status
```

- SwiftPM package, swift-tools-version 6.0, platform macOS 13+. Targets: executable `sfind`
  (thin main) + library `SFindCore` (everything). Tests use Swift Testing (`@Test`,
  parameterized `arguments:` — ideal for per-option tables).
- **Custom argv parser** (find's grammar isn't flag-shaped; no swift-argument-parser).
  getopt-style option phase (`-H -L -P -E -X -d -s -x -f path`, bundling, first non-option
  ends options), then paths, then expression tokens.
- `CandidateSource` protocol is the testability seam: `MDQuerySource` in production;
  `ArraySource` lets parity tests feed a walked file list through the identical filter+action
  machinery with no index involved.

### Planner rules (from verified Spotlight probes)

Attribute map: name→`kMDItemFSName` (`c` modifier for `-iname`); size→`kMDItemFSSize`;
mtime→`kMDItemFSContentChangeDate`; birthtime→`kMDItemFSCreationDate`;
uid/gid→`kMDItemFSOwnerUserID`/`kMDItemFSOwnerGroupID`;
directory→`kMDItemContentTypeTree == "public.folder"`.

- **No index narrowing possible** (post-filter only): `-atime`/`-amin`
  (`kMDItemLastUsedDate` is LaunchServices "last opened", verified ≠ POSIX atime),
  `-ctime`/`-cmin` (no attribute), `-perm`, `-inum`, `-links`, `-flags`, `-acl`,
  `-xattr(name)`, `-fstype`, `-path`/`-ipath` (`kMDItemPath` is readable but NOT queryable —
  verified), `-regex`, `-samefile`, `-sparse`, `-nouser`/`-nogroup`.
- **Glob translation**: the Spotlight query language supports only `*` (no `?`, no `[...]` —
  verified). Patterns using `?`/`[...]`/escapes are widened to a `*`-superset (or contribute
  no narrowing); exact fnmatch happens in the post-filter regardless.
- **Match-all base query**: `(kMDItemContentTypeTree == "public.item" || kMDItemFSName ==
  "*")`. Verified: `kMDItemFSName == "*"` alone returns 0 in fully-indexed trees;
  `public.item` alone returns 0 in the reduced tier used for hidden-directory scopes.
- **Query syntax**: `== != < > <= >= && || ( ) !` (spell NOT as `!`; the word `NOT` fails);
  string modifiers `c`/`d`; dates via `$time.iso(…)`/`$time.now(-secs)`;
  `InRange(attr,min,max)` is valid (note: `mdfind` needs `-literal` for it — irrelevant to
  the C API, but it matters when using mdfind as a debugging oracle).
- **Negation soundness**: a narrowing N(p) satisfies N(p) ⊇ exact(p), so `¬N(p)` is NOT a
  valid narrowing of `¬p`. Translate `! p` into the query only when p's translation is exact
  on indexed values; otherwise the branch contributes match-all (no narrowing). Disjunctions:
  OR the branch narrowings; any untranslatable branch makes that branch match-all.
- **Index tiers**: dot-directory *contents* are queryable only when the scope root itself is
  the hidden directory (not a subdirectory of one), and only
  `{FSName, uid, gid, FSCreationDate, FSContentChangeDate, FSNodeCount}` are queryable there
  (verified). When a scope root is a hidden directory, the planner must restrict narrowing to
  that attribute set (content-type and size narrowings would silently drop results).
- **Globals** (`-maxdepth/-mindepth/-xdev/-depth/-follow`) apply regardless of expression
  position or reachability; the last `-maxdepth` wins (verified). Depth is computed in the
  post-filter as component count relative to the root; `-xdev` via `st_dev` comparison.
- `-prune`: post-processing stage — evaluate the prune condition on candidate directories,
  then exclude candidates having a pruned ancestor. Inert under `-d` (matches find).
- `-delete` forces children-before-parents ordering: sort matches by path depth descending
  before acting.

### Executor (performance)

- C API via `import CoreServices`: `MDQueryCreate` → `MDQuerySetSearchScope` (CFArray of
  paths; **union** semantics verified; tildes are NOT expanded — expand them first) →
  `MDQueryExecute(kMDQuerySynchronous)`, which blocks and needs no caller run loop
  (MDQuery.h). NOT NSMetadataQuery (async-only, requires a run-loop/notification dance).
- Attribute fetch: `MDQueryGetAttributeValueOfResultAtIndex` for streaming;
  `MDItemsCopyAttributes` (10.12+) for true cross-item batches. Avoid `valueListAttrs`
  (uniqued-list memory blowup, wrong tool). `MDItemCreate(path)` works for arbitrary existing
  paths (post-filter aid), but mode/inode/links/atime still require `lstat`.
- Post-filter parallelism: chunk candidates (~256) into a `TaskGroup`; lstat + AST evaluation
  per chunk; stream results to actions. Output order is unspecified (find's is
  traversal-dependent anyway; documented divergence). `-s` sorts lexicographically for
  determinism.
- **Path normalization**: results come back as `/System/Volumes/Data/...` or
  `/private/var/...` (verified). Re-map each result onto the user's literal root argument
  (compute the relative path against `realpath(root)`, re-prefix with the root as typed) so
  output matches find's (`./foo` style for relative roots).
- **Scope-level warning probe**: per root, check for `.metadata_never_index` / `*.noindex`
  ancestors and compare a shallow `readdir` sample against index membership; warn "root
  appears unindexed; results may be empty or incomplete".
- Known index gaps (document in SPEC.md): dotfiles are never returned; symlinks and
  app-bundle contents are absent entirely; `/usr /bin /etc /tmp` are empty; `$TMPDIR` is
  reduced-tier. Verified index coverage of a real home directory was ~3% of inodes.

### find behavioral subtleties the implementation and tests MUST honor (all verified)

- `-size` no-suffix: `st_size` rounded UP to 512-byte blocks, then compared. With
  `c/k/M/G/T/P`: exact bytes `n × scale`, NO rounding (differs from GNU). A 27034-byte file
  matches `-size 53` and `-size +26k`, NOT `-size 27k`.
- Times, no unit: days compare `floor(age/86400)` but minutes compare `ceil(age/60)`
  (measured empirically at the boundaries; the man page's "rounded up" wording is wrong
  for days). `-mtime -1` ≡ `-mtime 0`; `now` is fixed at startup. Unit suffixes (`smhdw`, combinable, e.g. `-1h30m`): raw seconds, no rounding.
  `-newerXY`: all 20 forms exist; `Y=t` accepts getdate-style strings, NOT `@epoch`.
- Implicit `-print` is suppressed by the lexical presence of
  `-print/-print0/-ls/-exec/-execdir/-ok/-okdir` **and `-delete`** (undocumented), NOT by
  `-quit`.
- `-perm`: bare = exact 07777 match; `-mode` = all bits; `+mode` = any bit (BSD); accept
  `/mode` as an any-bit alias (GNU; macOS rejects it). Symbolic modes ignore umask and may
  not start with `-`.
- `-exec … +`: `{}` must be the literal last argument before `+`; the batching form is always
  true; a nonzero child makes the overall exit status 1 (the `;` form only makes the
  predicate false).
- `-name '*'` matches dotfiles (no FNM_PERIOD); `-regex` is anchored at both ends over the
  whole path; `-path` treats `/` as an ordinary character.
- Exit status: 0 iff no traversal errors and no failed `-exec +` child; match count is
  irrelevant. A missing path operand is a usage error (no GNU default-`.`).
- `-print0`: NUL only, no newline. `-ls` = `ls -dgils` format printing `st_blocks` (which
  differs from `-size`'s computed blocks on APFS).
- `-type bcdflpsw` (`w` = whiteout, undocumented but accepted).
  `-user/-uid/-group/-gid` all accept names AND numbers.
- Symlink modes: `-P` lstat everywhere (default); `-H` stat for command-line operands only;
  `-L` stat with lstat fallback on broken links (so `-type l` under `-L` matches only broken
  links). There is no `-xtype` on macOS.
- Regex engine: POSIX `regcomp(3)`/`regexec(3)` (BRE default, `REG_EXTENDED` under `-E`);
  never NSRegularExpression (ICU dialect ≠ POSIX).

## Repo layout

```
Package.swift            LICENSE   SPEC.md   PLAN.md   README.md
.swift-format            Makefile
Sources/sfind/main.swift
Sources/SFindCore/
  CLI/Options.swift  CLI/OptionParser.swift
  Expression/AST.swift  Expression/ExpressionParser.swift
  Planner/Planner.swift  Planner/QueryBuilder.swift  Planner/Warnings.swift
  Execute/CandidateSource.swift  Execute/MDQuerySource.swift  Execute/PathNormalizer.swift
  Execute/PostFilter.swift  Execute/FileInfo.swift (lstat wrapper)
  Execute/Glob.swift (fnmatch)  Execute/PosixRegex.swift (regcomp)
  Actions/Print.swift  Actions/Ls.swift  Actions/Exec.swift  Actions/Delete.swift
  Actions/Printf.swift
Tests/SFindCoreTests/
  OptionParserTests.swift  ExpressionParserTests.swift
  Planner/  NameTests SizeTests TimeTests TypeTests PermTests PathTests OwnerTests
            OperatorTests GlobalsTests WarningTests
  PostFilter/ (same per-option split, against real temp files via lstat — no Spotlight)
  Actions/  PrintTests LsTests ExecTests DeleteTests PrintfTests
Tests/ParityTests/       # find-oracle tests via ArraySource (walk-fed; run anywhere incl. tmp)
  FixtureBuilder.swift   # builds a tree: sizes, touch -t times, perms, symlinks, dotfiles,
                         # glob-hostile names
  ParityRunner.swift     # runs /usr/bin/find vs the sfind machinery, compares sorted output,
                         # with expected-divergence annotations
  ParityCases.swift      # table of (expression, notes) per SPEC.md entry
Tests/IntegrationTests/  # real Spotlight index; gated by SFIND_INTEGRATION=1 + canary
  SpotlightCanary.swift  # fixture under $HOME (non-hidden), mdimport, poll ≤60s, skip if
                         # never indexed
  MDQuerySourceTests.swift  EndToEndParityTests.swift
.github/workflows/ci.yml  release.yml  .github/release.yml
scripts/build-universal.sh
```

Per-option test organization: planner tests assert `(argv expression) → exact expected
MDQuery string + post-filter plan + warnings`; post-filter tests assert predicate truth
against crafted temp files; parity tests assert find-identical output. One file per option
group in each layer, so per-option coverage is visible.

**Integration-test constraint (verified)**: `/tmp`, `$TMPDIR`, and dot-directories are
unindexed or reduced-tier — fixtures MUST live in a non-hidden directory directly under
`$HOME`, force-indexed with `mdimport`, polled with a timeout (never fixed sleeps), and
cleaned up in teardown. Unit and parity layers never touch the index. Live-index tests must
never assert exact global counts (the index drifts).

## CI (`.github/workflows/ci.yml`) — push to main + PRs

Spotlight IS enabled on GitHub-hosted macOS runners (GitHub disabled it in 2020, 2023, and
2025 and reverted every time — actions/runner-images PRs #1763 and #11930; Xcode discovery
via mdfind is load-bearing for their customers). Still gate on a runtime canary.

- Runner `macos-15` (arm64); pin the toolchain via a `DEVELOPER_DIR` env var; no setup-swift
  action (macOS-only package).
- Jobs: lint (`swift format lint --strict --recursive Sources Tests`); build + unit + parity
  (`swift test --enable-code-coverage` in **debug** — coverage in release is broken, SwiftPM
  issue #9197); an integration step gated on the canary probe's output (`mdimport` a `$HOME`
  probe file, poll `mdfind -onlyin`, ≤60s; on failure skip, don't fail).
- Cache `~/Library/Caches/org.swift.swiftpm` only (skip `.build` — dependency-light package).
  SHA-pin third-party actions; `persist-credentials: false` on checkout.

## Release (`.github/workflows/release.yml`) — on tag push

- Universal build: **not** `swift build --arch` (hidden flag, long-broken — SwiftPM issue
  #8013). Two builds with `--triple {x86_64,arm64}-apple-macosx -c release
  --disable-sandbox`, output dirs discovered via `swift build --show-bin-path <same flags>`
  (never hardcode `.build` paths), then `lipo -create`; verify with `lipo -info`.
- Sign AFTER lipo (lipo strips signatures). Default: ad-hoc `codesign -s -`. Dormant
  Developer ID path gated by job-level `env: HAS_SIGNING: ${{ secrets.MACOS_CERT_P12 != ''
  }}` (secrets are illegal in `if:`; compare `== 'true'` — it is a string):
  `apple-actions/import-codesign-certs@v3` → `codesign --force --timestamp --options
  runtime` → `ditto -c -k --keepParent` → `xcrun notarytool submit --wait` with App Store
  Connect API-key secrets (`APPSTORE_API_KEY_P8`, `APPSTORE_API_KEY_ID`,
  `APPSTORE_API_ISSUER_ID`). **No stapling** (impossible for bare CLI binaries; the ticket is
  served online). Never combine `--options runtime` with an ad-hoc identity. Enabling real
  signing later = add the secrets; zero workflow edits.
- Publish: `gh release create "$TAG" --generate-notes` + `gh release upload` (gh is
  preinstalled; no third-party release action). Artifacts:
  `sfind-<tag>-universal-apple-macosx.tar.gz` (sfind, LICENSE, README.md) plus a single
  `SHA256SUMS`. `.github/release.yml` categorizes notes. `permissions: contents: write`.

## Makefile

`PRODUCT_NAME=sfind`, `PREFIX ?= /usr/local`, `DESTDIR` support. Targets: `build` (release,
`--disable-sandbox`), `test`, `lint`, `format`, `install` (BSD `install -m 0755` from
`$(swift build --show-bin-path …)`), `uninstall`, `universal` (two-triple + lipo script),
`integration-test` (opt-in; creates and cleans `~/sfind-itest-*`).

## Milestones (each lands green on CI)

1. **Scaffolding**: Package.swift, LICENSE, .swift-format, Makefile, ci.yml, release.yml,
   SPEC.md with the full unchecked checklist + determinations, README expansion.
2. **Parser**: options + expression AST with all primaries/operators; per-option parser tests
   (argument shapes, the `-newerXY` matrix, `-exec` terminator rules, error cases). Includes
   `--expr STRING` (sfind extension): tokenizes one string into expression tokens so that
   parens and `!` need no shell escaping — whitespace splits; quotes/backslashes group;
   unquoted `(`/`)` self-delimit; unquoted `!` self-delimits only at token start (preserving
   `[!a]*` classes); spliced at the flag's position; repeatable and mixable with discrete
   tokens. See SPEC.md for the full rules.
3. **Planner**: MDQuery translation + warnings; per-option planner tests asserting exact
   query strings and post-filter plans (check off SPEC.md entries as they land).
4. **Post-filter + print actions**: FileInfo/lstat, fnmatch, POSIX regex, globals,
   `-print/-print0`, exit codes; ArraySource; the parity harness running against
   `/usr/bin/find` on walked fixtures (no index needed).
5. **MDQuery execution**: MDQuerySource, scoping, path normalization, scope probes/warnings;
   integration tests with canary gating; first genuinely useful binary.
6. **Remaining actions**: `-ls`, then `-exec/-execdir/-ok/-okdir`, then `-delete`
   (depth-descending ordering, `/`-refusal, symlink-follow incompatibility, safety tests),
   `-quit`, `-prune`.
7. **GNU extensions**: `-perm /mode`, `-printf` (directive table in SPEC.md), `-regextype`,
   `-readable/-writable/-executable`, `-daystart`.
8. **Release**: universal build exercised end-to-end; tag `v0.1.0`.

## Verification

- `swift test` green locally and in CI at every milestone; the parity suite green with
  divergence annotations only for documented gaps.
- `make integration-test` locally: real-index end-to-end vs `/usr/bin/find` on an indexed
  `$HOME` fixture.
- Manual smoke: `sfind ~/Documents -name '*.md' -mtime -7` vs `find` (timed); running sfind
  with a root under a `.metadata_never_index` tree must print the unindexed-root warning.
- Release dry-run: push a `v0.0.1-rc` tag, confirm tarball + SHA256SUMS + ad-hoc signature
  (`codesign -dv`, `lipo -info`).
