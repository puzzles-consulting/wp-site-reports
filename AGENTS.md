# Puzzles Site Reports (agent instructions)

A small WordPress plugin: **read-only** reports of a WordPress site (status, updates, Wordfence,
SEO) over two REST routes in the namespace `puzzles-reports/v1`, consumed by Puzzles' client
reports. Public repo (GPL-2.0-or-later). Code, docs and commits are English.

## Gate

```bash
bash scripts/build.sh <version> && bash tests/smoke.sh   # one at a time: both are heavy
bash tests/promote.sh                                     # promotions need script(1): skipped in Git Bash
```

`smoke.sh` tears its Docker stack down on exit, also on failure: never leave containers running. CI runs `php -l` on
7.4 and 8.4 plus both tests, and the smoke on a WordPress/PHP matrix (`smoke-matrix`: 5.8/7.4 to 7.1/8.4,
weekly too; GitHub turns a schedule off after 60 days without repository activity). It fails on any PHP warning,
notice or deprecation the plugin's files log (`tests/out/debug.log`).
`main` is protected (PR with the CI checks required, no force-push), so CI runs on every PR, docs-only ones included
(why: `ci.yml`).

## Hard rules

1. **PHP 7.4 syntax only**: no enums, `match`, named arguments, `readonly`, union types or `?->`.
2. **Read-only: never add a write route.** Routes are `GET` only, `show_in_index => false`,
   `Cache-Control: no-store`, never page-cached.
3. Loading the main file only adds hooks. Nothing runs on a front-end request, no cron, no option
   other than `puzzles_site_reports_token` (SHA-256 hex of the token, autoload off).
4. Responses never contain server paths, database names, table prefixes, the token or Wordfence's
   per-issue `data`. One fixed 401 (`puzzles_reports_unauthorized`) for every auth failure.
5. A new behaviour gets a `case_*` function in `tests/smoke.sh` first.
6. Every shipped file must pass the promoter's checks (its header, step 2): plain ASCII, `<?` only in PHP, and only
   the allowed lines before the one-line `define( 'PUZZLES_SR_UPDATE_PUBKEY', '...' );`.

## Pointers

- The route contract lives in [`docs/contract.md`](./docs/contract.md); update it in the same commit
  as any route change, plus `CHANGELOG.md` under `[Unreleased]`.
- `build.sh` rewrites the main file's one ` * Version: X.Y.Z` line and one `PUZZLES_SITE_REPORTS_VERSION` define (keep
  both exactly in that form). Its zip builder is copied word for word into the promoter, which refuses any other zip:
  a format change goes into both in one commit (`tests/promote.sh` compares them), and the owner re-installs it.
- Signed updates and promotion: README, Updates and Release. `scripts/wp-sr-promote` is installed by hand and runs
  nothing from the repository.
- Commits are authored as `Puzzles Internal <internal@puzzles.consulting>`; the why goes in the body.
- Pushing waits for the owner's OK.
