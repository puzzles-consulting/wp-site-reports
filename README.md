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

In wp-admin, open **Tools → Site Reports → Create connection** (on a multisite, a network admin only), or run
`wp puzzles-site-reports connect --porcelain`. Paste the string it prints into the portal's Report setup. It is shown
once, and creating a new connection stops the previous one at once. The routes and the authentication are in
[`docs/contract.md`](https://github.com/puzzles-consulting/wp-site-reports/blob/main/docs/contract.md).
Deactivating the plugin deletes the connection; after reactivating, create a new one.

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
3. Sign and promote it, which rolls it out to every site on its next update check. On the owner's machine, from a
   checkout of `main`, with the release key in `PUZZLES_SR_SIGNING_KEY` (from the secret store, never on disk):
   `bash scripts/promote.sh vX.Y.Z <tested>`. Type `<tested>` yourself: it is the WordPress version the release notes
   say the smoke test ran on (`Tested with WordPress 6.8.1`), and it becomes the manifest's `tested`. Never paste a
   command from release notes: anyone with write access can edit them.

   Before signing, `promote.sh` checks that the tag is the same commit locally and on GitHub and is on `main`, builds the
   zip itself from that commit, and aborts unless the release's zip has exactly the same files and bytes. It signs the
   sha256 of the release's zip only after that, and only with the key sites trust now (the one in the latest promoted
   release; for the first release, the one in this zip). Then it uploads `manifest.json` and marks the release latest.
   The key is read once and removed from the environment, and reaches PHP on stdin only (no `php` on PATH: a pinned
   Docker image, with no container log).

   `bash scripts/promote.sh vX.Y.Z <tested> --dry-run <zip>` runs the same checks with a local zip in place of the
   release's and prints the manifest without touching GitHub. It refuses any key the plugin ever trusted: dry runs use a
   throwaway key from `scripts/keygen.sh`.

The release key is created with `bash scripts/keygen.sh`: the public key goes into `PUZZLES_SR_UPDATE_PUBKEY`, the
secret key goes from file descriptor 3 straight into the secret store (the script's header shows how).

Rotating the key: sites trust only the key in the version they run, so the new key ships in a release signed with the
old one.

1. `bash scripts/keygen.sh` a new pair into the secret store (keep the old one), put the new public key in
   `PUZZLES_SR_UPDATE_PUBKEY`, and release it as `vX.Y.Z` as above.
2. Promote it with the **old** key and `--rotate` (without it, `promote.sh` refuses a zip that changes the key):
   `bash scripts/promote.sh vX.Y.Z <tested> --rotate`.
3. Promote the next release, with the new key, only once the portal shows every site on `X.Y.Z` or later: a site still
   on an older version accepts only the old key and would never reach `X.Y.Z` once a newer release is latest. Then
   retire the old key.

Bad release: `gh release edit vX.Y.Z --prerelease` stops the spread, but sites already on it are fixed only by rolling
forward to `X.Y.Z+1`.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
