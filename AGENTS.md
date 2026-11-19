# Puzzles Site Reports (agent instructions)

A small WordPress plugin: **read-only** reports of a WordPress site (status, updates, Wordfence,
SEO) over two REST routes in the namespace `puzzles-reports/v1`, consumed by Puzzles' client
reports. Public repo (GPL-2.0-or-later). Code, docs and commits are English.

## Gate

```bash
bash scripts/build.sh <version> && bash tests/smoke.sh   # one at a time: both are heavy
bash tests/promote-dry-run.sh                             # this worktree's promoter on the committed HEAD's trees
```

`build.sh` writes a byte-reproducible `dist/puzzles-site-reports.zip`; `smoke.sh` boots WordPress in Docker, installs
that zip and runs every `case_*` function (the update cases on a test build, `build.sh --test-overrides`). It tears
the stack down on exit (`docker compose down -v`), also on failure: never leave containers running. On Windows Git
Bash `smoke.sh` exports `MSYS_NO_PATHCONV=1`. `promote-dry-run.sh` runs the promoter, `scripts/wp-sr-promote`, against
a throwaway origin, keys and a stand-in for `gh`, and checks that its zip is byte for byte `build.sh`'s; its real-path
section needs `script(1)` for a terminal, so it is skipped in Git Bash and runs in CI (with `$CI` set, a missing
`script(1)` fails the test). CI (`.github/workflows/ci.yml`) runs `php -l` on 7.4 to 8.4 plus both tests.

## Hard rules

1. **PHP 7.4 syntax only**: no enums, `match`, named arguments, `readonly`, union types or `?->`.
2. **Read-only: never add a write route.** Routes are `GET` only, `show_in_index => false`, with
   `Cache-Control: no-store`.
3. Loading the main file only adds hooks. Nothing runs on a front-end request, no cron, no option
   other than `puzzles_site_reports_token` (SHA-256 hex of the token, autoload off).
4. Responses never contain server paths, database names, table prefixes, the token or Wordfence's
   per-issue `data`. One fixed 401 (`puzzles_reports_unauthorized`) for every auth failure.
5. A new behaviour gets a `case_*` function in `tests/smoke.sh` first; cases run in the order of the
   `CASES` list at the bottom of that file (a defined case missing from it, or a listed one that is
   undefined, fails the run).
6. Every shipped file (the main file, `uninstall.php`, `includes/`, README, CHANGELOG, LICENSE) is plain ASCII (TAB,
   LF, printable), and only PHP files hold `<?`. In the main file, nothing but the header comment, blank lines, `//`
   comments, the ABSPATH guard and literal `define( 'NAME', 'value' );` lines comes before the one-line
   `define( 'PUZZLES_SR_UPDATE_PUBKEY', '...' );`. The promoter refuses a release that breaks either.

## Pointers

- The route contract lives in [`docs/contract.md`](./docs/contract.md); update it in the same commit
  as any route change, plus `CHANGELOG.md` under `[Unreleased]`.
- Zip top folder is `puzzles-site-reports/`; `build.sh` rewrites the main file's one ` * Version: X.Y.Z` line and its
  one `define( 'PUZZLES_SITE_REPORTS_VERSION', 'X.Y.Z' );` line to its argument (keep both exactly in that form).
- Signed updates, promotion and key rotation: README, Updates and Release; the checks are in the header of
  `scripts/wp-sr-promote` (the signing key never goes into GitHub). It is self-contained and installed by hand: it must
  never source, run or eval anything from the repository or from git objects. It carries its own copy of `build.sh`'s
  version rewrite and zip writer: a change to the zip's bytes goes into both, in one commit (the test compares them).
- Commits are authored as `Puzzles Internal <internal@puzzles.consulting>`; the why goes in the body.
- Pushing waits for the owner's OK.
