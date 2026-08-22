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

- [ ] `-H` — follow symlinks for command-line path operands only.
  Index: none. Post: `stat` for roots (fallback `lstat` on dangling), `lstat` below.
- [ ] `-L` — follow all symlinks (`stat`, `lstat` fallback for broken links).
  Index: none; symlinks are absent from the index (warning). Post: stat-mode evaluation;
  `-type l` matches only broken links, matching find.
- [ ] `-P` — never follow symlinks (default). Post: `lstat` everywhere.
- [ ] `-E` — `-regex`/`-iregex` patterns are extended REs (ERE) instead of BRE.
- [ ] `-X` — skip filenames containing `' " \ space tab newline`, diagnostic to stderr.
  Output-time filter.
- [ ] `-d` — depth-first (post-order). Affects output/action ordering; makes `-prune` inert.
- [ ] `-f path` — add `path` to the roots (allows roots beginning with `!`, `(`, `-`).
- [ ] `-s` — lexicographic result order. sfind: sort the final result set (this is also the
  recommended flag for deterministic output, since Spotlight's natural order is unspecified).
- [ ] `-x` — do not cross device boundaries. Post: compare `st_dev` against the root's.

Option parsing is getopt-style: options may bundle (`-EXdsx`), and the first non-option
argument ends option parsing.

## sfind-specific options

`find` never uses double-dash options, so `--*` is sfind's conflict-free namespace.

- [ ] `--expr STRING` — supply expression tokens as a single string instead of discrete
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

## Primaries — time

Numeric arguments accept `+n` / `-n` / `n` (more than / less than / exactly). No-unit values
compare `ceil((now − t)/86400)` days (`ceil(../60)` minutes for the `*min` forms); unit
suffixes `s m h d w` (combinable, e.g. `-1h30m`) compare raw seconds with no rounding. `now`
is fixed at startup.

- [ ] `-mtime [-+]n[smhdw]` — modification time.
  Index: range on `kMDItemFSContentChangeDate` via `$time.now(-secs)`, widened to the
  rounding boundary. Post: `lstat` `st_mtimespec`.
- [ ] `-mmin [-+]n` — as `-mtime`, minutes. Index: same attribute. Post: same.
- [ ] `-atime [-+]n[smhdw]` — access time.
  Index: **none** — `kMDItemLastUsedDate` is LaunchServices "last opened", not POSIX atime
  (verified). Post: `lstat` `st_atimespec`.
- [ ] `-amin [-+]n` — as `-atime`, minutes. Index: none. Post: `lstat`.
- [ ] `-ctime [-+]n[smhdw]` — inode change time. Index: **none** (no Spotlight attribute).
  Post: `lstat` `st_ctimespec`.
- [ ] `-cmin [-+]n` — as `-ctime`, minutes. Index: none. Post: `lstat`.
- [ ] `-Btime [-+]n[smhdw]` — birth time. Index: range on `kMDItemFSCreationDate`.
  Post: `lstat` `st_birthtimespec`. BSD-only (GNU has no `-Btime`).
- [ ] `-Bmin [-+]n` — as `-Btime`, minutes. Index: `kMDItemFSCreationDate`. Post: `lstat`.
- [ ] `-newer file` — mtime strictly newer than `file`'s mtime (≡ `-newermm`).
  Index: `kMDItemFSContentChangeDate > $time.iso(...)` of the reference. Post: `lstat`.
- [ ] `-mnewer file` — BSD alias of `-newer`.
- [ ] `-anewer file` — atime newer than `file`'s mtime (≡ `-neweram`). Index: none. Post: `lstat`.
- [ ] `-cnewer file` — ctime newer than `file`'s mtime (≡ `-newercm`). Index: none. Post: `lstat`.
- [ ] `-Bnewer file` — birthtime newer than `file`'s mtime (≡ `-newerBm`). Index:
  `kMDItemFSCreationDate`. Post: `lstat`. BSD-only.
- [ ] `-newerXY file` — X ∈ {a,B,c,m} attribute of candidate, Y ∈ {a,B,c,m,t} attribute of
  `file` (`t`: `file` is a date string). All 20 forms.
  Index: narrowing only when X ∈ {m, B}; none for X ∈ {a, c}. Post: `lstat`.
  Dialect: `Y=t` accepts getdate-style strings (`yesterday`, `Jan 1 2020`, ISO); GNU's
  `@epoch` form is **not** accepted by macOS find (sfind may add it later as an extension).

## Primaries — name and path

- [ ] `-name pattern` — `fnmatch` glob on the last path component. `-name '*'` matches
  dotfiles (no `FNM_PERIOD`).
  Index: `kMDItemFSName == "<pattern>"` when the pattern uses only `*` and literals; patterns
  containing `?`, `[...]`, or escapes are widened to a `*`-only superset (the query language
  supports only `*` — verified). Patterns that can only match dot-names (e.g. `.*`)
  trigger the invisible-files warning. Post: `fnmatch(3)`.
- [ ] `-iname pattern` — case-insensitive `-name`.
  Index: same with the `c` modifier (`== "..."c`). Post: `fnmatch` with `FNM_CASEFOLD`.
- [ ] `-path pattern` — glob over the whole path as constructed from the root; `/` is an
  ordinary character.
  Index: **none** — `kMDItemPath` is readable but not queryable (verified). Post: `fnmatch`.
- [ ] `-ipath pattern` — case-insensitive `-path`. Index: none. Post: `fnmatch` + casefold.
- [ ] `-wholename` / `-iwholename` — GNU-compat aliases of `-path`/`-ipath`.
- [ ] `-lname pattern` / `-ilname pattern` — glob on symlink target contents.
  Index: none + **warning** (symlinks are not indexed at all). Post: `readlink` + `fnmatch`.
- [ ] `-regex pattern` / `-iregex pattern` — whole path must match entirely (anchored both
  ends). BRE by default, ERE under `-E`, other dialects via `-regextype`.
  Index: none. Post: POSIX `regcomp`/`regexec`.
  Dialect: GNU defaults to emacs regex here — the one silent BSD/GNU divergence; sfind
  follows BSD.

## Primaries — ownership

- [ ] `-user uname` — owner matches (name, or numeric UID if no such user).
  Index: `kMDItemFSOwnerUserID == uid` (name resolved first). Post: `lstat` `st_uid`.
- [ ] `-uid n` — alias of `-user` (macOS accepts names here too, unlike GNU).
- [ ] `-group gname` — group matches. Index: `kMDItemFSOwnerGroupID`. Post: `lstat` `st_gid`.
- [ ] `-gid n` — alias of `-group`.
- [ ] `-nouser` — owner has no passwd entry. Index: none. Post: `getpwuid` miss.
- [ ] `-nogroup` — group has no group entry. Index: none. Post: `getgrgid` miss.

## Primaries — stat metadata

- [ ] `-type t` — `t` ∈ `b c d f l p s w` (`w` = whiteout, undocumented but accepted by
  macOS find).
  Index: `d` → `kMDItemContentTypeTree == "public.folder"`; `f` → no narrowing (a `!=
  "public.folder"` clause is unsound for items missing the attribute); `l s p b c w` → no
  narrowing possible + **warning** (these file kinds are not indexed at all).
  Post: `lstat` `st_mode` (or `stat` under `-L`/`-H` per symlink rules).
  Dialect: GNU's `-type f,d` comma lists are not supported (matches macOS).
- [ ] `-size n[ckMGTP]` — no suffix: `st_size` rounded UP to 512-byte blocks, then compared.
  With `c`/`k`/`M`/`G`/`T`/`P`: compared against exact bytes `n × scale`, NO rounding
  (verified; differs from GNU, which rounds scaled units up).
  Index: range on `kMDItemFSSize`, widened to cover the rounding boundary. Post: `lstat`
  `st_size` with the exact rule.
  Dialect: GNU suffixes `b` and `w` are rejected (matches macOS).
- [ ] `-empty` — regular file of size 0, or directory with no entries.
  Index: `kMDItemFSSize == 0 || kMDItemContentTypeTree == "public.folder"`.
  Post: `st_size == 0` for files; empty `readdir` for directories.
- [ ] `-perm [-+/]mode` — bare: exact match of bits 07777; `-mode`: all listed bits set;
  `+mode` (BSD) and `/mode` (GNU extension adopted by sfind; macOS find rejects it): any
  listed bit set. Symbolic modes per `chmod(1)`, umask ignored, may not start with `-`.
  Index: **none** (no permissions attribute). Post: `lstat` `st_mode`.
- [ ] `-links n` — hard link count. Index: none. Post: `lstat` `st_nlink`.
- [ ] `-inum n` — inode number. Index: none. Post: `lstat` `st_ino`.
- [ ] `-samefile name` — hard link to `name` (under `-L`, also symlinks resolving to it).
  Index: none. Post: `st_dev`/`st_ino` equality with the reference.
- [ ] `-sparse` — fewer blocks allocated than size implies. Index: none. Post:
  `st_blocks * 512 < st_size`.
- [ ] `-flags [-+]flags,notflags` — `chflags(1)` file flags. Index: none. Post: `lstat`
  `st_flags`. macOS/BSD-only.
- [ ] `-acl` — file has an extended ACL. Index: none. Post: `acl_get_file`. macOS-only.
- [ ] `-xattr` — file has any extended attribute. Index: none. Post: `listxattr`. macOS-only.
- [ ] `-xattrname name` — file has the named xattr. Index: none. Post: `listxattr`.
  macOS-only.
- [ ] `-fstype type` — filesystem type (plus pseudo-types `local`, `rdonly`).
  Index: none. Post: `statfs`.

## Primaries — actions

All actions run in the post stage, after filtering.

- [ ] `-print` — path + newline. Always true.
- [ ] `-print0` — path + NUL (no newline; verified byte-exact).
- [ ] `-ls` — `ls -dgils`-format line (inode, 512-byte `st_blocks`, mode, nlink, owner,
  group, size, mtime, path; `-> target` for symlinks; device numbers for b/c files). Always
  true. Note: prints allocated `st_blocks`, which differs from `-size`'s rounded-up
  computation on APFS.
- [ ] `-exec utility [args] ;` — one invocation per file, `{}` replaced anywhere in any arg
  (including mid-string). True iff exit status 0.
- [ ] `-exec utility [args] {} +` — xargs-style batching; `{}` must be the literal last
  argument before `+`. Always true; any nonzero child makes sfind's overall exit status
  nonzero.
- [ ] `-execdir …` (`;` and `+` forms) — as `-exec` but runs from the file's directory with
  the unqualified filename.
- [ ] `-ok utility [args] ;` — `-exec` with a terminal prompt; non-affirmative → not run,
  primary is false.
- [ ] `-okdir utility [args] ;` — `-execdir` with the prompt.
- [ ] `-delete` — delete the file/directory. Always true. Forces children-before-parents
  ordering (sfind sorts matches by depth descending); refuses paths that would traverse `/`;
  incompatible with symlink following; fails on non-empty directories. Suppresses the
  implicit `-print` (undocumented macOS behavior, verified).
- [ ] `-quit` — terminate immediately with exit 0. Does NOT suppress the implicit `-print`
  (verified).

**Implicit `-print`**: if none of `-exec`, `-execdir`, `-ok`, `-okdir`, `-ls`, `-print`,
`-print0`, `-delete` appears anywhere in the expression (lexically — evaluation doesn't
matter), the expression is wrapped as `( expr ) -print`.

## Primaries — traversal control / globals

`find` treats these as always-true primaries that mutate global state; they apply even from
expression branches that are never evaluated, and the last occurrence wins (verified for
`-maxdepth`). sfind's planner hoists them out of the AST.

- [ ] `-maxdepth n` — at most n levels below the roots. Post: component-count check relative
  to the root.
- [ ] `-mindepth n` — at least n levels. Post: component-count check.
- [ ] `-depth` — post-order (act on contents before the directory). Ordering directive, same
  as `-d`.
- [ ] `-depth n` — true if depth relative to the root is n (BSD primary, distinct from bare
  `-depth`; disambiguated by a numeric next token). Post: component count.
- [ ] `-prune` — do not descend below the current file; no effect under `-d`.
  Post-processing: evaluate the prune condition on candidate directories, then exclude
  candidates with a pruned ancestor.
- [ ] `-xdev` — deprecated primary form of `-x`. `-mount` — GNU-compat alias.
- [ ] `-follow` — deprecated primary form of `-L`.
- [ ] `-ignore_readdir_race` / `-noignore_readdir_race` — suppress errors for files deleted
  mid-run. Relevant to sfind: index results can be stale; with the flag set, `ENOENT` on a
  candidate is silently dropped; without it, it is a diagnostic + exit 1 (find behavior).
- [ ] `-noleaf` — accepted, ignored (GNU-compat no-op, matches macOS).

## Operators

Decreasing precedence; all tokens are separate argv elements.

- [ ] `( expression )` — grouping.
- [ ] `! expression` / `-not expression` — NOT.
- [ ] `-true` / `-false` — constant primaries.
- [ ] `expr -and expr` / `expr -a expr` / juxtaposition — AND, short-circuits.
- [ ] `expr -or expr` / `expr -o expr` — OR, short-circuits.

Planner note: for `! p`, the narrowing `¬N(p)` is only sound when `N(p)` is exact on indexed
values; otherwise the branch contributes match-all. For disjunctions, branch narrowings are
OR-ed; an untranslatable branch makes that branch match-all.

## GNU extensions adopted

- [ ] `-perm /mode` — any-bit form (see `-perm` above).
- [ ] `-printf format` — GNU directive set (`%p %f %h %P %H %l %s %b %k %S %y %Y %m %M %n %i
  %d %D %F %u %U %g %G`, time forms `%a %c %t %B` + `%A<k> %C<k> %T<k> %B<k>` + `@` epoch,
  escapes `\n \t \0 \\ \NNN` and `\c`). Post: formatted from `lstat` + path data. macOS find
  has no `-printf`, so no conflict.
- [ ] `-regextype type` — regex dialect selection for `-regex`/`-iregex` (at minimum:
  `posix-basic`, `posix-extended`; emacs deferred). Overrides `-E`.
- [ ] `-readable` / `-writable` / `-executable` — `access(2)` checks. Index: none. Post:
  `access`.
- [ ] `-daystart` — measure `-atime/-ctime/-mtime/-Btime` day boundaries from the start of
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
   `.metadata_never_index` marker or `*.noindex` directory. sfind emits a stderr warning when
   (a) a predicate provably requires such files (`-type l/s/p/b/c/w`, `-lname`, dot-anchored
   `-name` patterns), or (b) a search root appears to be unindexed (probe: exclusion markers
   on ancestor paths + a shallow readdir-vs-index comparison).
2. **Result ordering** is unspecified (find's is traversal order). Use `-s` for deterministic
   lexicographic order. `-delete` still guarantees children-before-parents.
3. **Hidden-directory scopes** are reachable only when the root itself is the hidden
   directory, and only filename/owner/date metadata is queryable there; sfind restricts its
   query narrowing accordingly.
4. `-ls` prints allocated blocks (`st_blocks`); on APFS (sparse/compressed files) this can
   differ from classic HFS expectations — identical to real find, listed here only because
   parity tests must not conflate it with `-size` rounding.

## Future work

- Add a mechanism for users to allow for a filesystem walk to complete a search expression
  for files not indexed by Spotlight. This could look like an implicit walk for any uindexable predicate,
  or an explicit walk (so that e.g. `sfind -name foo` matches even entries in unindexed trees or symlinks).
- Conjunct-narrowed walking: when an unindexable predicate is conjoined with an indexable
  location-shaped one (e.g. `-path '*/node_modules/*' -type l`), use the index to find the
  candidate subtrees and walk only those.
- Small-scope shortcut: MDQuery has a ~200ms IPC floor; for tiny/shallow scopes a plain walk
  is faster. Could auto-select once `--walk` machinery exists. Users should have control if their intent is to query Spotlight versus find something.
- `mdfind`-style free-text/content predicate (`kMDItemTextContent` is queryable) — a
  content-grep primary find can't offer.
