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

Updates are signed. The manifest is `{ version, sha256, requires, requires_php, tested, signature }`: `signature` is an
Ed25519 signature of the exact bytes `<version>\n<sha256>` (one newline between) by the release key, which the plugin
checks against the public key it carries (`PUZZLES_SR_UPDATE_PUBKEY`). The release key never lives in GitHub, so write access to the repository alone cannot
ship anything. `version` must be `X.Y.Z` and `sha256` lowercase hex; the package URL is derived from the version
(`.../releases/download/vX.Y.Z/puzzles-site-reports.zip`), and the download is installed only if it hashes to `sha256`.
Anything else is ignored.

WordPress applies offers for an `Update URI` plugin only after its own check against api.wordpress.org succeeds. A
host that blocks wordpress.org never sees this plugin's update either; the portal's version-lag column shows it.

## Release

```bash
bash scripts/build.sh <version>   # dist/puzzles-site-reports.zip
bash tests/smoke.sh               # Docker smoke test against a throwaway WordPress
```

1. After `main`'s CI is green, tag `vX.Y.Z` (exactly three numbers) on it and push the tag.
   `.github/workflows/release.yml` lints PHP 7.4 to 8.4, builds the zip, runs the smoke test on it and publishes the
   zip alone as a **pre-release**. It has no manifest, so no site is offered it.
2. Install it on the canary site with WP-CLI and check it there:
   `wp plugin install https://github.com/puzzles-consulting/wp-site-reports/releases/download/vX.Y.Z/puzzles-site-reports.zip --force`
3. Sign and promote it, which rolls it out to every site on its next update check. On the owner's machine, with the
   release key in `PUZZLES_SR_SIGNING_KEY` (from the secret store, never on disk):
   `bash scripts/promote.sh vX.Y.Z <tested>`. It downloads the release's zip, writes and signs `manifest.json`, uploads
   it and marks the release latest. `<tested>` is the WordPress the smoke test ran on (the release notes say which):
   it becomes the manifest's `tested`. `bash scripts/promote.sh vX.Y.Z <tested> --dry-run <zip>` signs a local zip and
   prints the manifest without touching GitHub.

The release key is created once with `bash scripts/keygen.sh`: the public key goes into `PUZZLES_SR_UPDATE_PUBKEY`, the
secret key goes from file descriptor 3 straight into the secret store (the script's header shows how). Until that
constant is set, every manifest is rejected.

Bad release: `gh release edit vX.Y.Z --prerelease` stops the spread, but sites already on it are fixed only by rolling
forward to `X.Y.Z+1`.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
