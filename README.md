# Puzzles Site Reports

A read-only WordPress plugin that exposes a site's status and SEO data to Puzzles' client reports
through two `GET` routes under `/wp-json/puzzles-reports/v1/`. It stores only the hash of its
access token and installs its own updates; nothing else is written. It runs nothing on front-end requests.

Requires WordPress 5.8+ and PHP 7.4+.

## Install

Upload `puzzles-site-reports.zip` in **Plugins → Add New → Upload Plugin**, or with WP-CLI:

```bash
wp plugin install puzzles-site-reports.zip --activate
```

## Connect

In wp-admin, open **Tools → Site Reports → Create connection**, or run
`wp puzzles-site-reports connect --porcelain`. Paste the string it prints into the portal's Report setup. It is shown
once, and creating a new connection stops the previous one at once. The routes and the authentication are in
[`docs/contract.md`](docs/contract.md).

## Updates

The plugin updates itself from this repository's GitHub Releases through WordPress' own update check
(the header's `Update URI`), and installs its own updates automatically. The check reads
`https://github.com/puzzles-consulting/wp-site-reports/releases/latest/download/manifest.json`, which GitHub
resolves to the newest release that is **not** a pre-release. It runs only inside WordPress' update check (cron or
admin), never on a front-end request, and any failure leaves WordPress' own answer untouched.

The manifest's `version` must be `X.Y.Z` and its `package` must be exactly
`https://github.com/puzzles-consulting/wp-site-reports/releases/download/vX.Y.Z/puzzles-site-reports.zip` for that
version, or the update is ignored. The filters `puzzles_site_reports_manifest_url` and `puzzles_site_reports_package_prefix`
(the part before `vX.Y.Z/`) exist so the smoke test can point at a local manifest; a site has no reason to use them.

WordPress applies offers for an `Update URI` plugin only after its own check against api.wordpress.org succeeds. A
host that blocks wordpress.org never sees this plugin's update either; the portal's version-lag column shows it.

## Release

```bash
bash scripts/build.sh <version>      # dist/puzzles-site-reports.zip
bash scripts/manifest.sh <version>   # dist/manifest.json
bash tests/smoke.sh                  # Docker smoke test against a throwaway WordPress
```

`manifest.sh` reads `requires` and `requires_php` from the plugin header. `tested` is the WordPress version
the smoke test ran on: `tests/smoke.sh` writes it to `tests/out/wp-version.txt` and the release workflow passes it as
`bash scripts/manifest.sh <version> <tested>`. Locally, without that argument, `scripts/manifest.sh` uses its `6.9` default.

1. After `main`'s CI is green, tag `vX.Y.Z` (exactly three numbers) on it and push the tag.
   `.github/workflows/release.yml` lints PHP 7.4 to 8.4, builds the zip, runs the smoke test on it and publishes
   `puzzles-site-reports.zip` and `manifest.json` as a **pre-release**. No site is offered it yet.
2. Install it on the canary site with WP-CLI and check it there:
   `wp plugin install https://github.com/puzzles-consulting/wp-site-reports/releases/download/vX.Y.Z/puzzles-site-reports.zip --force`
3. Promote it, which rolls it out to every site on its next update check:
   `gh release edit vX.Y.Z --prerelease=false --latest`

Bad release: `gh release edit vX.Y.Z --prerelease` stops the spread, but sites already on it are fixed only by rolling
forward to `X.Y.Z+1`.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
