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

## Updates

The plugin updates itself from this repository's GitHub Releases through WordPress' own update check
(the header's `Update URI`), and installs its own updates automatically. The check reads
`https://github.com/puzzles-consulting/wp-site-reports/releases/latest/download/manifest.json`, which GitHub
resolves to the newest release that is **not** a pre-release. It runs only inside WordPress' update check (cron or
admin), never on a front-end request, and any failure leaves WordPress' own answer untouched.

Updates are signed. The manifest is `{ version, sha256, requires, requires_php, tested, signature }`: `signature` is an
Ed25519 signature by the release key of the five other fields joined by one newline each, in that order
(`<version>\n<sha256>\n<requires>\n<requires_php>\n<tested>`, no trailing newline). The plugin checks it against the
public key it carries (`PUZZLES_SR_UPDATE_PUBKEY`). The release key never lives in GitHub, so write access to the
repository alone cannot ship anything. `version` must be `X.Y.Z`, `sha256` lowercase hex, and the other three `X.Y` or
`X.Y.Z`; anything else is ignored. The offer's package is `puzzles-sr://X.Y.Z/<sha256>`, which WordPress cannot fetch
by itself: the plugin's download step turns it into `.../releases/download/vX.Y.Z/puzzles-site-reports.zip`, stores at
most 5 MB of it (within 60 seconds), and installs the download only if it hashes to `sha256`. If that step is not loaded, the update fails
instead of installing an unchecked zip. No filter can change the key or the URLs.

WordPress applies offers for an `Update URI` plugin only after its own check against api.wordpress.org succeeds. A
host that blocks wordpress.org never sees this plugin's update either; the portal's version-lag column shows it.

## Release

```bash
bash scripts/build.sh <version>   # dist/puzzles-site-reports.zip, byte-reproducible
bash tests/smoke.sh               # Docker smoke test against a throwaway WordPress
bash tests/promote-dry-run.sh     # the promotion against a throwaway origin, keys and a stand-in for gh
```

1. After `main`'s CI is green, tag `vX.Y.Z` (exactly three numbers) on it and push the tag.
   `.github/workflows/release.yml` lints PHP 7.4 to 8.4, builds the zip, runs the smoke test on it and publishes the
   zip alone as a **pre-release**. It has no manifest, so no site is offered it.
2. Install it on the canary site with WP-CLI and check it there (a functional check, not a review):
   `wp plugin install https://github.com/puzzles-consulting/wp-site-reports/releases/download/vX.Y.Z/puzzles-site-reports.zip --force`
3. Review the checkout yourself: a clean checkout of `main` that contains the tag. Then sign and promote it, which rolls
   it out to every site on its next update check, with the launcher (below) and the release key from the secret store
   in that one command's environment:
   `bash ~/bin/wp-sr-promote --repo <checkout> vX.Y.Z <tested>`. Type `<tested>` yourself (the release notes say
   `Tested with WordPress 6.8.1`); never paste a command from release notes. Before the key is used it prints, against
   your last promotion recorded on this machine, (1) `scripts/` and `.gitattributes`: the promotion code your NEXT
   promotion will run, and (2) every file the release ships, in full; then you type the version, on the terminal.
   Review both: that review is the control. The checks, the options and how the key is handled are in the header of
   [`scripts/promote.sh`](scripts/promote.sh).

The launcher. The code that holds the key and prints your review never comes from the checkout it reviews.
[`scripts/launcher.sh`](scripts/launcher.sh) is the one script you review by hand and install outside the repository,
from a commit you reviewed (its full sha):

```bash
git -C <checkout> show <sha>:scripts/launcher.sh | cat -v       # review it
mkdir -p ~/bin && git -C <checkout> show <sha>:scripts/launcher.sh >~/bin/wp-sr-promote
```

It runs `scripts/promote.sh`, `build.sh` and `php.sh` as they were in your last promotion recorded on this machine (a
local ref per promotion, `refs/puzzles-sr/promoted/vX.Y.Z`, written only by promote.sh: never push it or fetch into
it). So a release's change to them runs only on the promotion after the one whose review (1) showed it. When (1) shows
a change to `scripts/launcher.sh`, reinstall it after reviewing that change:
`git -C <checkout> show <sha>:scripts/launcher.sh | diff ~/bin/wp-sr-promote - | cat -v`.

- First promotion on a machine (a new or second machine has no record): the launcher refuses until you pass
  `--trust-checkout <sha>`, the full sha of a commit whose `scripts/promote.sh`, `build.sh` and `php.sh` you reviewed
  by hand (`git -C <checkout> show <sha>:scripts/promote.sh | cat -v`, and the other two). The review shows everything
  as new; the record on that machine starts there.
- A release whose `build.sh` changes the zip: the recorded `build.sh` cannot rebuild it, so the run stops after your
  review. Once review (1) showed you that `build.sh`, run again with `--trust-checkout <the tag's commit sha>`.
- Bad release: `gh release edit vX.Y.Z --prerelease` stops the spread, and GitHub's latest falls back to an earlier
  release you recorded, which the next promotion accepts. Sites already on it are fixed only by rolling forward to
  `X.Y.Z+1`, promoted as usual.
- Interrupted promotion (stopped after the release went live, before it was recorded): the next run finds that GitHub's
  latest is the promotion it left pending, checks its manifest with your key against its zip and asks you to type its
  version to record it. Then run again.

Branch protection on `main` and restricting who can create `v*` tags on GitHub are still recommended: they are
repository settings, the owner's decision.

The release key is created with `bash scripts/keygen.sh`: the public key goes into `PUZZLES_SR_UPDATE_PUBKEY`, the
secret key goes from file descriptor 3 straight into the secret store (the script's header shows how).

Rotating the key: sites trust only the key in the version they run, so the new key ships in a release signed with the
old one.

1. `bash scripts/keygen.sh` a new pair into the secret store (keep the old one), put the new public key in
   `PUZZLES_SR_UPDATE_PUBKEY`, and release it as `vX.Y.Z` as above.
2. Promote it with the **old** key in `PUZZLES_SR_SIGNING_KEY`, the **new** secret key in `PUZZLES_SR_NEW_SIGNING_KEY`
   (the proof that it is yours) and `--rotate`: `bash ~/bin/wp-sr-promote --repo <checkout> vX.Y.Z <tested> --rotate`.
3. Promote the next release, with the new key, only once the portal shows every site on `X.Y.Z` or later: a site still
   on an older version accepts only the old key and would never reach `X.Y.Z` once a newer release is latest. Then
   retire the old key.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
