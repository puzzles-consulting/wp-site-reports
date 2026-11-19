# Puzzles Site Reports (agent instructions)

A small WordPress plugin: **read-only** reports of a WordPress site (status, updates, Wordfence,
SEO) over two REST routes in the namespace `puzzles-reports/v1`, consumed by Puzzles' client
reports. Public repo (GPL-2.0-or-later). Code, docs and commits are English.

## Gate

```bash
bash scripts/build.sh <version> && bash tests/smoke.sh   # one at a time: both are heavy
bash tests/promote-dry-run.sh                             # tests the committed HEAD: commit first
```

`build.sh` writes a byte-reproducible `dist/puzzles-site-reports.zip`; `smoke.sh` boots WordPress in Docker, installs
that zip and runs every `case_*` function (the update cases on a test build, `build.sh --test-overrides`). It tears
the stack down on exit (`docker compose down -v`), also on failure: never leave containers running. On Windows Git
Bash `smoke.sh` exports `MSYS_NO_PATHCONV=1`. `promote-dry-run.sh` runs `scripts/promote.sh --dry-run` against a
throwaway origin and keys. CI (`.github/workflows/ci.yml`) runs `php -l` on 7.4 to 8.4 plus both tests.

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

## Pointers

- The route contract lives in [`docs/contract.md`](./docs/contract.md); update it in the same commit
  as any route change, plus `CHANGELOG.md` under `[Unreleased]`.
- Zip top folder is `puzzles-site-reports/`; `build.sh` rewrites `Version:` and
  `PUZZLES_SITE_REPORTS_VERSION` to its argument.
- Signed updates, promotion and key rotation: README, Updates and Release; the checks themselves are in the headers of
  `scripts/build.sh` and `scripts/promote.sh` (the signing key never goes into GitHub). A change to `build.sh`'s output
  makes `promote.sh` refuse every release tagged before it (their zips no longer match its build).
- Commits are authored as `Puzzles Internal <internal@puzzles.consulting>`; the why goes in the body.
- Pushing waits for the owner's OK.
