# Puzzles Site Reports

A read-only WordPress plugin that exposes a site's status and SEO data to Puzzles' client reports
through two `GET` routes under `/wp-json/puzzles-reports/v1/`. It writes nothing, runs nothing on
front-end requests and stores only the hash of its access token.

Requires WordPress 5.8+ and PHP 7.4+.

## Install

Upload `puzzles-site-reports.zip` in **Plugins → Add New → Upload Plugin**, or with WP-CLI:

```bash
wp plugin install puzzles-site-reports.zip --activate
```

## Connect

Connection (token generation and the connection string) is documented in
[`docs/contract.md`](docs/contract.md) as the routes land.

## Updates

The plugin updates itself from this repository's GitHub Releases through WordPress' own update check
(the header's `Update URI`), and installs its own updates automatically. The check reads
`https://github.com/puzzles-consulting/wp-site-reports/releases/latest/download/manifest.json`, which GitHub
resolves to the newest release that is **not** a pre-release. It runs only inside WordPress' update check (cron or
admin), never on a front-end request, and any failure leaves WordPress' own answer untouched.

The offered `package` must start with
`https://github.com/puzzles-consulting/wp-site-reports/releases/download/`, or the update is ignored. The filters
`puzzles_site_reports_manifest_url` and `puzzles_site_reports_package_prefix` change the manifest URL and that prefix;
they exist so the smoke test can point at a local manifest, and a site has no reason to use them.

## Release

```bash
bash scripts/build.sh <version>      # dist/puzzles-site-reports.zip
bash scripts/manifest.sh <version>   # dist/manifest.json (`tested` = the WordPress the smoke ran on, default 6.9)
bash tests/smoke.sh                  # Docker smoke test against a throwaway WordPress
```

1. Tag `vX.Y.Z` on `main` and push the tag. `.github/workflows/release.yml` builds the zip, runs the smoke test on it
   and publishes `puzzles-site-reports.zip` and `manifest.json` as a **pre-release**. No site is offered it yet.
2. Install it on the canary site with WP-CLI and check it there:
   `wp plugin install https://github.com/puzzles-consulting/wp-site-reports/releases/download/vX.Y.Z/puzzles-site-reports.zip --force`
3. Promote it, which rolls it out to every site on its next update check:
   `gh release edit vX.Y.Z --prerelease=false --latest`

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
