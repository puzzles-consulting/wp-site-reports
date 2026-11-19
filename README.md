# Puzzles Site Reports

A read-only WordPress plugin that exposes a site's status and SEO data to Puzzles' client reports
through two `GET` routes under `/wp-json/puzzles-reports/v1/`. It stores only the hash of its
access token and installs its own updates; nothing else is written. It runs nothing on front-end requests.

Requires WordPress 5.8+ and PHP 7.4+.

## Install

Client sites get only promoted releases. The portal's connect script installs the plugin and checks the release's
signed manifest first. By hand: download `puzzles-site-reports.zip` from the latest release, check it with the key
the sites trust, `bash ~/bin/wp-sr-promote verify vX.Y.Z puzzles-site-reports.zip <public key>` (Release, below),
then install it:

```bash
wp plugin install puzzles-site-reports.zip --activate
```

## Connect

In wp-admin, open **Tools > Site Reports > Create connection** (on a multisite, a network admin only), or run
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
most 5 MB of it (within 60 seconds), and installs the download only if it hashes to `sha256`. If that step is not
loaded, the update fails instead of installing an unchecked zip. No filter can change the key or the URLs. At most
4 KB of the manifest is read.

WordPress applies offers for an `Update URI` plugin only after its own check against api.wordpress.org succeeds. A
host that blocks wordpress.org never sees this plugin's update either; the portal's version-lag column shows it.

## Release

What a developer and CI run (never in the promotion account):

```bash
bash scripts/build.sh <version>   # dist/puzzles-site-reports.zip, byte-reproducible; README and CHANGELOG do not ship
bash tests/smoke.sh               # Docker smoke test against a throwaway WordPress
bash tests/promote.sh             # the promoter against a stand-in for gh, with throwaway keys
```

Before a release: the portal accepts the new report shape and is deployed (a promotion reaches every site within
hours).

1. After `main`'s CI is green, tag `vX.Y.Z` on it and push the tag. `.github/workflows/release.yml` builds the zip,
   smoke-tests it and publishes it as a **pre-release**, with no manifest, so no site is offered it. That workflow only
   ever makes pre-releases.
2. Check it on the canary, a remote site with no secrets, never from the promotion machine (`wp --ssh=<canary>` or
   on its host): `wp plugin install <the pre-release's zip URL> --force`. Before the first rollout, also show that a
   no-op release reaches the canary by auto-update on WP Engine: that is the gate for every site.
3. Promote it: `bash ~/bin/wp-sr-promote vX.Y.Z <tested>` (`--first` the very first time), with the signing key from
   the secret store in that one command's environment. Type `<tested>` yourself (the release notes say
   `Tested with WordPress 6.8.1`); never paste a command from release notes. Review what it prints before you type
   the version: that review is the control.

The promoter. [`scripts/wp-sr-promote`](scripts/wp-sr-promote) is the whole promoter and key generator; no other code
from this repository runs in the promotion account. Its header says what it checks and needs. Review it by hand and
install it outside the repository, from a commit you reviewed; re-install it only after reviewing its diff:

```bash
git -C <clone> show <sha>:scripts/wp-sr-promote | cat -v      # review it, all of it
mkdir -p ~/bin && git -C <clone> show <sha>:scripts/wp-sr-promote >~/bin/wp-sr-promote
```

It keeps no state: the baseline of each review is GitHub's latest release, accepted only on its `owner.sig` (your key
over its manifest), so any machine with the promoter and the key can promote. A promotion uploads `manifest.json`
(signed with the key the sites trust) and `owner.sig`, and marks the release latest; a rerun finishes an interrupted
one.

The signing key lives in the secret store (Bitwarden) plus one offline copy. Losing it means reinstalling the plugin
on every site over SSH, since sites accept updates only from it. It is created by the promoter:
`bash ~/bin/wp-sr-promote keygen 3>&1 1>&2 | <store-secret-from-stdin>`. The public key goes into
`PUZZLES_SR_UPDATE_PUBKEY`; the secret key goes from file descriptor 3 straight into the store.

- Bad release: `gh release edit vX.Y.Z --prerelease` and delete its `manifest.json` asset: GitHub's latest falls back
  to the previous release, and no site is offered the bad one. Sites already on it are fixed only by rolling forward
  to `X.Y.Z+1`, promptly: anyone who can edit releases can mark it latest again while its old signed manifest exists
  somewhere (manifests do not expire; that is a known, parked limit).
- Rotating the key: sites trust only the key in the version they run, so the new key ships in a release signed with
  the old one. Put the new public key in `PUZZLES_SR_UPDATE_PUBKEY`, release it, and promote it with `--rotate`, the
  old key in `PUZZLES_SR_SIGNING_KEY` and the new one in `PUZZLES_SR_NEW_SIGNING_KEY`; from then on promote with the
  new key. Promote the next release only once the portal shows every site on the rotation release. Never mark a
  rotation release pre-release; if it was, the next promotion needs `--baseline-key <old public key>` once.

Branch protection on `main` and restricting who can create `v*` tags on GitHub are still recommended.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
