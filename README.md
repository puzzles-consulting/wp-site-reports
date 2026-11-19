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

## Release

```bash
bash scripts/build.sh <version>   # dist/puzzles-site-reports.zip
bash tests/smoke.sh               # Docker smoke test against a throwaway WordPress
```

Attach the zip to a GitHub release tagged `v<version>`.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
