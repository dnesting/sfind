# sfind Specification

`sfind` implements the `find` command backed by macOS Spotlight (MDQuery). This document is
the coverage ledger: one checkbox per `find` option, primary, and operator, with its
determination — how it maps onto the MDQuery translation, the post-filter, or both.

**Execution model**: *the index narrows, the post-filter decides.* The MDQuery generated for
an invocation is a recall-oriented over-approximation — it must return a superset of the true
matches among indexed files. Every predicate is then re-verified authoritatively in a
post-filter (`fnmatch(3)`, `lstat(2)`, `regexec(3)`, …) before any action runs. The **Index**
line for each entry describes the narrowing contributed to the MDQuery (or "none"); the
**Post** line describes the authoritative check. Correctness never depends on index
precision; the index affects only completeness (see [Known divergences](#known-divergences))
and speed.

Dialect policy: BSD/macOS `find` semantics are ground truth. GNU spellings are supported
where they don't conflict; divergences are noted per entry. The one silent BSD/GNU conflict
is `-regex`/`-iregex` (BRE vs emacs regex): sfind follows BSD, with GNU `-regextype` as the
explicit opt-in.

Checkbox legend: `[ ]` planned, `[x]` implemented with per-option tests.

## Command-line options

- [x] `-H` — follow symlinks for command-line path operands only.
  Index: none. Post: `stat` for roots (fallback `lstat` on dangling), `lstat` below.
- [x] `-L` — follow all symlinks (`stat`, `lstat` fallback for broken links).
  Index: none; symlinks are absent from the index (warning). Post: stat-mode evaluation;
  `-type l` matches only broken links, matching find.
- [x] `-P` — never follow symlinks (default). Post: `lstat` everywhere.
- [x] `-E` — `-regex`/`-iregex` patterns are extended REs (ERE) instead of BRE.
- [x] `-X` — skip filenames containing `' " \ space tab newline`, diagnostic to stderr.
  Output-time filter.
- [x] `-d` — depth-first (post-order). Affects output/action ordering; makes `-prune` inert.
- [x] `-f path` — add `path` to the roots (allows roots beginning with `!`, `(`, `-`).
- [x] `-s` — find-compatible sorted order: lexicographic over path components, which
  reproduces find's per-directory traversal sort (a directory's contents precede its
  later siblings — plain string sort differs at the `.` < `/` boundary). Verified
  order-sensitively against find. Also the recommended flag for deterministic output,
  since Spotlight's natural order is unspecified.
- [x] `-x` — do not cross device boundaries. Post: compare `st_dev` against the root's.

Option parsing is getopt-style: options may bundle (`-EXdsx`), and the first non-option
argument ends option parsing.

## sfind-specific options

`find` never uses double-dash options, so `--*` is sfind's conflict-free namespace.

- [x] `--expr STRING` — supply expression tokens as a single string instead of discrete
  arguments. The motivating property is that expression metacharacters need **no shell
  escaping** inside the (shell-quoted) string — parentheses and `!` are ordinary characters
  to your shell and token delimiters to sfind:

  ```sh
  sfind ~/Documents --expr '(-name "*.md" -o -name "*.txt") -mtime -7'
  ```

  Tokenization rules (deliberately NOT full sh syntax — no operators, expansion, globbing,
  or substitution):
  - Whitespace separates tokens.
  - Single quotes, double quotes, and backslashes group/escape, so patterns keep their
    glob characters: `-name "*.md"`.
  - Unquoted `(` and `)` are self-delimiting tokens — no surrounding spaces required
    (`(-name` splits into `(`, `-name`).
  - Unquoted `!` is self-delimiting only where a new token would start, so negated fnmatch
    classes like `-name "[!a]*"` survive intact even unquoted mid-token.
  - Inside quotes, all of the above are literal (`-name "(odd) file*"` works).

  The resulting tokens are spliced into the expression at the position where `--expr`
  appears. Repeatable, and freely mixable with discrete expression arguments. Parser-level
  feature: after tokenization the result is indistinguishable from discrete arguments (same
  AST, same MDQuery translation, same post-filter).

- [x] `--mdfind` — print the equivalent `mdfind` invocation (`mdfind -onlyin <root> …
  -literal '<query>'`) instead of running the search. Expression terms the query language
  cannot express are noted on stderr, since the printed query returns a superset of the
  expression's matches. Exits 1 when the expression can only match unindexed files.
- [x] `--walk[=MODE]` — supplement (or replace) the index with a filesystem walk. MODE is
  `off` (the default), `gaps` (the default for a bare `--walk`), or `only`. Accepted before
  the paths or among the expression tokens.
  - `gaps`: the walk covers exactly what Spotlight does not index, so the index still does
    the bulk of the work and sfind stays faster than a plain `find`. Phases, each streaming
    to the post-filter: (1) an exhaustive walk of the roots under a small budget (8192
    candidates or 150 ms) — small scopes finish here and never pay MDQuery's ~200 ms IPC
    floor; (2) otherwise, per root, an authoritative probe of whether the index holds
    anything under it (roots carrying an exclusion marker, or with nothing indexed, are
    walked exhaustively instead); (3) the planned MDQuery over the covered roots, streaming
    as usual; (4) one synchronous query listing every directory the index holds under
    those roots (`kMDItemContentTypeTree == "public.folder"`; skipped when a root is a
    hidden directory, since the reduced tier does not serve content type — about 1–2 s for
    the ~25k folders of a home directory); (5) a gap walk of those roots yielding only what
    the index does not hold: names starting with a dot, anything that is not a regular
    file or directory (symlinks, FIFOs, sockets, devices, whiteouts), any directory absent
    from the folder list (yielded itself, then walked exhaustively — this catches the
    exclusions name rules cannot see: Spotlight privacy entries, unindexed volumes mounted
    below the root, and system policy such as most of `~/Library`), and everything under a
    gap subtree — a dot directory, a `*.noindex` directory, a directory containing
    `.metadata_never_index`, or a package/bundle directory. Paths delivered by the budgeted
    walk are excluded from the later phases. Regular files in indexed directories cost the
    walk no `lstat` at all (`readdir` `d_type`), which is what keeps it cheaper than find,
    which stats every entry.
  - `only`: a plain walk; the index is never consulted. Equivalent to `find`, for when the
    intent is "find something" rather than "query Spotlight". `-content` matches nothing
    here (a warning says so).

  Under either walk mode the predicate-level completeness warnings (`-type l`, `-lname`,
  dot-name patterns) are suppressed, since the walk covers those files, and the
  root-not-indexed diagnostic is not emitted. The walk honors `-H`/`-L`/`-P` (a symlink
  cycle under `-L` is reported as a diagnostic and not descended), `-x`, `-d` (post-order),
  `-maxdepth` (deeper directories are never read), and `-prune`: when the expression has no
  `-exec` family primary, a side-effect-free dry-run evaluation decides whether to descend,
  so pruned trees are never read; with `-exec` present the walk descends and the usual
  post-processing excludes the contents. Limitations: items 6 and 7 under
  [Known divergences](#known-divergences).
- [x] `--progress` — a status line on stderr. On a terminal it is redrawn in place
  (cleared before any other output goes out, then redrawn); otherwise `sfind: …` lines are
  emitted about once a second. Shows a bar with a best-effort completion estimate (walk
  phases: a hierarchical estimate from the traversal position, assuming equal work per
  directory; the index phases: an indeterminate marker, since MDQuery reports no total),
  the phase name (`walking`, `querying index`, `listing indexed folders`), and counters:
  candidates received from the query, candidates produced by the walk, entries the walk
  scanned, candidates the post-filter rejected (`filtered`), matches, and elapsed time.
  Ends with a final summary line.
- [x] `--help` / `-?` — usage and option summary. `--version` — version. (Recognized as
  the first argument.)

## Primaries — time

Numeric arguments accept `+n` / `-n` / `n` (more than / less than / exactly). No-unit day
values compare `floor(age/86400)`; the `*min` forms compare `ceil(age/60)` (both measured
empirically at the boundaries — the man page says "rounded up" for both, which is wrong for
days). Unit suffixes `s m h d w` (combinable, e.g. `-1h30m`) compare raw seconds with no
rounding. `now` is fixed at startup.

- [x] `-mtime [-+]n[smhdw]` — modification time.
  Index: range on `kMDItemFSContentChangeDate` via `$time.now(-secs)`, widened to the
  rounding boundary. Post: `lstat` `st_mtimespec`.
- [x] `-mmin [-+]n` — as `-mtime`, minutes. Index: same attribute. Post: same.
- [x] `-atime [-+]n[smhdw]` — access time.
  Index: **none** — `kMDItemLastUsedDate` is LaunchServices "last opened", not POSIX atime
  (verified). Post: `lstat` `st_atimespec`.
- [x] `-amin [-+]n` — as `-atime`, minutes. Index: none. Post: `lstat`.
- [x] `-ctime [-+]n[smhdw]` — inode change time. Index: **none** (no Spotlight attribute).
  Post: `lstat` `st_ctimespec`.
- [x] `-cmin [-+]n` — as `-ctime`, minutes. Index: none. Post: `lstat`.
- [x] `-Btime [-+]n[smhdw]` — birth time. Index: range on `kMDItemFSCreationDate`.
  Post: `lstat` `st_birthtimespec`. BSD-only (GNU has no `-Btime`).
- [x] `-Bmin [-+]n` — as `-Btime`, minutes. Index: `kMDItemFSCreationDate`. Post: `lstat`.
- [x] `-newer file` — mtime strictly newer than `file`'s mtime (≡ `-newermm`).
  Index: `kMDItemFSContentChangeDate > $time.iso(...)` of the reference. Post: `lstat`.
- [x] `-mnewer file` — BSD alias of `-newer`.
- [x] `-anewer file` — atime newer than `file`'s mtime (≡ `-neweram`). Index: none. Post: `lstat`.
- [x] `-cnewer file` — ctime newer than `file`'s mtime (≡ `-newercm`). Index: none. Post: `lstat`.
- [x] `-Bnewer file` — birthtime newer than `file`'s mtime (≡ `-newerBm`). Index:
  `kMDItemFSCreationDate`. Post: `lstat`. BSD-only.
- [x] `-newerXY file` — X ∈ {a,B,c,m} attribute of candidate, Y ∈ {a,B,c,m,t} attribute of
  `file` (`t`: `file` is a date string). All 20 forms.
  Index: narrowing only when X ∈ {m, B}; none for X ∈ {a, c}. Post: `lstat`.
  Dialect: `Y=t` accepts getdate-style strings (`yesterday`, `Jan 1 2020`, ISO); GNU's
  `@epoch` form is **not** accepted by macOS find (sfind may add it later as an extension).

## Primaries — name and path

- [x] `-name pattern` — `fnmatch` glob on the last path component. `-name '*'` matches
  dotfiles (no `FNM_PERIOD`).
  Index: `kMDItemFSName == "<pattern>"` when the pattern uses only `*` and literals; patterns
  containing `?`, `[...]`, or escapes are widened to a `*`-only superset (the query language
  supports only `*` — verified). Patterns that can only match dot-names (e.g. `.*`)
  trigger the invisible-files warning. Post: `fnmatch(3)`.
- [x] `-iname pattern` — case-insensitive `-name`.
  Index: same with the `c` modifier (`== "..."c`). Post: `fnmatch` with `FNM_CASEFOLD`.
- [x] `-path pattern` — glob over the whole path as constructed from the root; `/` is an
  ordinary character.
  Index: **none** — `kMDItemPath` is readable but not queryable (verified). Post: `fnmatch`.
- [x] `-ipath pattern` — case-insensitive `-path`. Index: none. Post: `fnmatch` + casefold.
- [x] `-wholename` / `-iwholename` — GNU-compat aliases of `-path`/`-ipath`.
- [x] `-lname pattern` / `-ilname pattern` — glob on symlink target contents.
  Index: none + **warning** (symlinks are not indexed at all). Post: `readlink` + `fnmatch`.
- [x] `-regex pattern` / `-iregex pattern` — whole path must match entirely (anchored both
  ends). BRE by default, ERE under `-E`, other dialects via `-regextype`.
  Index: none. Post: POSIX `regcomp`/`regexec`.
  Dialect: GNU defaults to emacs regex here — the one silent BSD/GNU divergence; sfind
  follows BSD.

## Primaries — ownership

- [x] `-user uname` — owner matches (name, or numeric UID if no such user).
  Index: `kMDItemFSOwnerUserID == uid` (name resolved first). Post: `lstat` `st_uid`.
- [x] `-uid n` — alias of `-user` (macOS accepts names here too, unlike GNU).
- [x] `-group gname` — group matches. Index: `kMDItemFSOwnerGroupID`. Post: `lstat` `st_gid`.
- [x] `-gid n` — alias of `-group`.
- [x] `-nouser` — owner has no passwd entry. Index: none. Post: `getpwuid` miss.
- [x] `-nogroup` — group has no group entry. Index: none. Post: `getgrgid` miss.

## Primaries — stat metadata

- [x] `-type t` — `t` ∈ `b c d f l p s w` (`w` = whiteout, undocumented but accepted by
  macOS find).
  Index: `d` → `kMDItemContentTypeTree == "public.folder"`; `f` → no narrowing (a `!=
  "public.folder"` clause is unsound for items missing the attribute); `l s p b c w` → no
  narrowing possible + **warning** (these file kinds are not indexed at all; the warning is
  suppressed under `--walk`, whose gap walk yields them).
  Post: `lstat` `st_mode` (or `stat` under `-L`/`-H` per symlink rules).
  Dialect: GNU's `-type f,d` comma lists are not supported (matches macOS).
- [x] `-size n[ckMGTP]` — no suffix: `st_size` rounded UP to 512-byte blocks, then compared.
  With `c`/`k`/`M`/`G`/`T`/`P`: compared against exact bytes `n × scale`, NO rounding
  (verified; differs from GNU, which rounds scaled units up).
  Index: range on `kMDItemFSSize`, widened to cover the rounding boundary. Post: `lstat`
  `st_size` with the exact rule.
  Dialect: GNU suffixes `b` and `w` are rejected (matches macOS).
- [x] `-empty` — regular file of size 0, or directory with no entries.
  Index: `kMDItemFSSize == 0 || kMDItemContentTypeTree == "public.folder"`.
  Post: `st_size == 0` for files; empty `readdir` for directories.
- [x] `-perm [-+/]mode` — bare: exact match of bits 07777; `-mode`: all listed bits set;
  `+mode` (BSD) and `/mode` (GNU extension adopted by sfind; macOS find rejects it): any
  listed bit set. Symbolic modes per `chmod(1)`, umask ignored, may not start with `-`.
  Index: **none** (no permissions attribute). Post: `lstat` `st_mode`.
- [x] `-links n` — hard link count. Index: none. Post: `lstat` `st_nlink`.
- [x] `-inum n` — inode number. Index: none. Post: `lstat` `st_ino`.
- [x] `-samefile name` — hard link to `name` (under `-L`, also symlinks resolving to it).
  Index: none. Post: `st_dev`/`st_ino` equality with the reference.
- [x] `-sparse` — fewer blocks allocated than size implies. Index: none. Post:
  `st_blocks * 512 < st_size`.
- [x] `-flags [-+]flags,notflags` — `chflags(1)` file flags. Index: none. Post: `lstat`
  `st_flags`. macOS/BSD-only.
- [x] `-acl` — file has an extended ACL. Index: none. Post: `acl_get_file`. macOS-only.
- [x] `-xattr` — file has any extended attribute. Index: none. Post: `listxattr`. macOS-only.
- [x] `-xattrname name` — file has the named xattr. Index: none. Post: `listxattr`.
  macOS-only.
- [x] `-fstype type` — filesystem type (plus pseudo-types `local`, `rdonly`).
  Index: none. Post: `statfs`.

## Primaries — content

sfind extension; `find` has no equivalent, and only the index can answer it.

- [x] `-content words` — the file's Spotlight-indexed text contains every
  whitespace-separated word. Each word becomes `kMDItemTextContent == "word"cd` (case- and
  diacritic-insensitive), AND-ed. Verified: a bare word matches whole words only; `*`
  extends it to prefix/suffix/substring matches; phrases do not match as a unit (hence one
  clause per word). An empty word list is a usage error.
  Index: that clause. No narrowing in the reduced (hidden-root) tier, which serves no text
  content. Post: index membership. In index-only mode, a term that is a top-level conjunct
  of the query was satisfied by every index result, so it is true iff the candidate came
  from the index; any other term (under `!` or `-o`, or in the reduced tier) gets a
  dedicated synchronous query over the typed roots before the search runs, and the
  post-filter consults that membership set. Under `--walk` every term gets the membership
  query, because a small scope may finish inside the budgeted walk without any index query
  and walked candidates carry no index evidence. Files the index does not hold never
  match; `--walk=only` warns that `-content` matches nothing. `--mdfind` prints the clause.

## Primaries — actions

All actions run in the post stage, after filtering.

- [x] `-print` — path + newline. Always true.
- [x] `-print0` — path + NUL (no newline; verified byte-exact).
- [x] `-ls` — `ls -dgils`-format line (inode, 512-byte `st_blocks`, mode, nlink, owner,
  group, size, mtime, path; `-> target` for symlinks; device numbers for b/c files). Always
  true. Note: prints allocated `st_blocks`, which differs from `-size`'s rounded-up
  computation on APFS.
- [x] `-exec utility [args] ;` — one invocation per file, `{}` replaced anywhere in any arg
  (including mid-string). True iff exit status 0.
- [x] `-exec utility [args] {} +` — xargs-style batching; `{}` must be the literal last
  argument before `+`. Always true; any nonzero child makes sfind's overall exit status
  nonzero.
- [x] `-execdir …` (`;` and `+` forms) — as `-exec` but runs from the file's directory with
  the unqualified filename.
- [x] `-ok utility [args] ;` — `-exec` with a terminal prompt; non-affirmative → not run,
  primary is false.
- [x] `-okdir utility [args] ;` — `-execdir` with the prompt.
- [x] `-delete` — delete the file/directory. Always true. Forces children-before-parents
  ordering (sfind sorts matches by depth descending); refuses paths that would traverse `/`;
  incompatible with symlink following; fails on non-empty directories. Suppresses the
  implicit `-print` (undocumented macOS behavior, verified).
- [x] `-quit` — terminate immediately with exit 0. Does NOT suppress the implicit `-print`
  (verified).

**Implicit `-print`**: if none of `-exec`, `-execdir`, `-ok`, `-okdir`, `-ls`, `-print`,
`-print0`, `-delete` appears anywhere in the expression (lexically — evaluation doesn't
matter), the expression is wrapped as `( expr ) -print`.

## Primaries — traversal control / globals

`find` treats these as always-true primaries that mutate global state; they apply even from
expression branches that are never evaluated, and the last occurrence wins (verified for
`-maxdepth`). sfind's planner hoists them out of the AST.

- [x] `-maxdepth n` — at most n levels below the roots. Post: component-count check relative
  to the root.
- [x] `-mindepth n` — at least n levels. Post: component-count check.
- [x] `-depth` — post-order (act on contents before the directory). Ordering directive, same
  as `-d`.
- [x] `-depth n` — true if depth relative to the root is n (BSD primary, distinct from bare
  `-depth`; disambiguated by a numeric next token). Post: component count.
- [x] `-prune` — do not descend below the current file; no effect under `-d`.
  Post-processing: evaluate the prune condition on candidate directories, then exclude
  candidates with a pruned ancestor.
- [x] `-xdev` — deprecated primary form of `-x`. `-mount` — GNU-compat alias.
- [x] `-follow` — deprecated primary form of `-L`.
- [x] `-ignore_readdir_race` / `-noignore_readdir_race` — suppress errors for files deleted
  mid-run. Relevant to sfind: index results can be stale; with the flag set, `ENOENT` on a
  candidate is silently dropped; without it, it is a diagnostic + exit 1 (find behavior).
- [x] `-noleaf` — accepted, ignored (GNU-compat no-op, matches macOS).

## Operators

Decreasing precedence; all tokens are separate argv elements.

- [x] `( expression )` — grouping.
- [x] `! expression` / `-not expression` — NOT.
- [x] `-true` / `-false` — constant primaries.
- [x] `expr -and expr` / `expr -a expr` / juxtaposition — AND, short-circuits.
- [x] `expr -or expr` / `expr -o expr` — OR, short-circuits.

Planner note: for `! p`, the narrowing `¬N(p)` is only sound when `N(p)` is exact on indexed
values; otherwise the branch contributes match-all. For disjunctions, branch narrowings are
OR-ed; an untranslatable branch makes that branch match-all.

## GNU extensions adopted

- [x] `-perm /mode` — any-bit form (see `-perm` above).
- [x] `-printf format` — GNU directive set (`%p %f %h %P %H %l %s %b %k %S %y %Y %m %M %n %i
  %d %D %F %u %U %g %G`, time forms `%a %c %t %B` + `%A<k> %C<k> %T<k> %B<k>` + `@` epoch,
  escapes `\n \t \0 \\ \NNN` and `\c`). Post: formatted from `lstat` + path data. macOS find
  has no `-printf`, so no conflict.
- [x] `-regextype type` — regex dialect selection for `-regex`/`-iregex` (at minimum:
  `posix-basic`, `posix-extended`; emacs deferred). Overrides `-E`.
- [x] `-readable` / `-writable` / `-executable` — `access(2)` checks. Index: none. Post:
  `access`.
- [x] `-daystart` — measure `-atime/-ctime/-mtime/-Btime` day boundaries from the start of
  today instead of 24h-from-now.

## GNU features deferred (documented, not planned for v1)

`-fprintf/-fprint/-fprint0/-fls` (output-to-file variants), `-xtype`, `-used`,
`-files0-from`, `-type f,d` comma lists, `@epoch` dates in `-newerXt`, `-D`/`-O` debug and
optimizer flags, `--help`/`--version` GNU-style long options.

## Known divergences from /usr/bin/find

These are inherent to the index-backed design and are documented behavior, not bugs:

1. **Invisible files.** Spotlight does not index: dotfiles (never returned by any query),
   symlinks, sockets, FIFOs, device nodes, whiteouts, app-bundle contents, `/usr`, `/bin`,
   `/etc`, `/tmp`, `$TMPDIR` (reduced), volumes with indexing disabled, and any tree under a
   `.metadata_never_index` marker or `*.noindex` directory. By default (`--walk=off`) these
   are simply absent from results; [`--walk`](#sfind-specific-options) fills them in with a
   walk restricted to exactly those gaps, and `--walk=only` walks everything. Warning
   policy without a walk: sfind warns eagerly only when an expression term provably
   requires such files (`-type l/s/p/b/c/w`, `-lname`, dot-anchored `-name` patterns).
   Scope-level diagnostics are deferred: they print only when the index returned nothing,
   after an authoritative probe of whether anything under the root is indexed, with the
   likely cause (an exclusion marker on an ancestor — detected by an O(path-depth) stat
   walk, not a directory scan — or a root inside a hidden directory) as an explanation of
   the emptiness. Warning paths are rendered relative to the working directory when the
   root was typed relative. Under a walk mode neither kind of warning is printed.
2. **Result ordering** is unspecified (find's is traversal order). Use `-s` for deterministic
   lexicographic order. `-delete` still guarantees children-before-parents.
3. **Hidden-directory scopes** are reachable only when the root itself is the hidden
   directory, and only filename/owner/date metadata is queryable there; sfind restricts its
   query narrowing accordingly (and `-content` has nothing to match against).
4. **Streaming and memory.** The query runs asynchronously and results stream to the
   post-filter (and stdout) in batches as the index delivers them, so output flows like
   find's and a closed pipe (e.g. `| head`) terminates the search early. The MDQuery API
   itself retains all gathered result references in the query object for the run's
   duration, so peak memory still grows with the result count; sfind adds only the batch
   being processed. `-s`, `-prune`, and `-delete` require the full set before acting and
   therefore collect first.
5. `-ls` prints allocated blocks (`st_blocks`); on APFS (sparse/compressed files) this can
   differ from classic HFS expectations — identical to real find, listed here only because
   parity tests must not conflate it with `-size` rounding.
6. **Gap walk coverage.** In `--walk=gaps` mode the walk decides what to yield from names
   and file types (dot names, non-regular non-directory types, gap subtrees as listed
   under `--walk`) plus the index's own list of the directories it holds: a directory
   missing from that list is yielded and walked exhaustively, which catches exclusions the
   name rules cannot see (`*.noindex` and marker-carrying directories themselves are
   yielded this way, since the index normally lacks them). What remains invisible is an
   individual regular file the index lacks inside a directory it does hold — a stale
   index; `--walk=only` is the escape hatch. A root that is itself a hidden directory is
   treated as index-covered for its non-dot contents, matching the reduced tier, and no
   folder list is consulted for it. A root the index holds nothing for is walked
   exhaustively, so a wholly unindexed root is complete.
7. **Path anchors.** When a top-level positive `-path`/`-ipath`/`-regex`/`-iregex` conjunct
   contains a literal `/component/` run (no glob or regex metacharacters in the run;
   nothing is derived past a `[` or `\`; regex patterns using grouping, alternation, or
   intervals yield nothing; a quantifier after the closing slash disqualifies the run),
   every match must have a directory of that name as an ancestor (case-insensitively for
   the `-i` forms). If no root's own path already satisfies the anchor, and either a walk
   is enabled or the query would otherwise return the whole scope (match-all), sfind first
   asks the index for directories of that name under the roots and makes them the new
   roots — nested ones collapsed into their ancestors, depths still relative to the typed
   root — so both the index query and the walk cover only those subtrees. If the index
   knows no such directory, nothing is searched. Consequence: in `gaps` mode, anchor
   directories the index cannot see (inside hidden or excluded trees) are not walked.

## Future work

- Run the index query and the gap walk concurrently instead of as sequential phases; today
  both stream on the main thread and the walk waits for the index to finish.
- Volume-level index status (`mdutil -s`) as a cheaper signal than the indexed-folder
  list for unindexed volumes mounted below a root, which today cost a full folder
  enumeration to detect.
- `--walk=all`: an exhaustive walk merged with the index (deduplicated by path), for the
  cases gap classification cannot model (a stale index) while still streaming index
  results first.
