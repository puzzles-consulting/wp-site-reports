# Puzzles Site Reports

A read-only WordPress plugin that exposes a site's status and SEO data to Puzzles' client reports
through two `GET` routes under `/wp-json/puzzles-reports/v1/`. It stores only the hash of its
access token and installs its own updates; nothing else is written. It runs nothing on front-end requests.

Requires WordPress 5.8+ and PHP 7.4+.

## Install

Upload `puzzles-site-reports.zip` in **Plugins > Add New > Upload Plugin**, or with WP-CLI:

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
most 5 MB of it (within 60 seconds), and installs the download only if it hashes to `sha256`. If that step is not loaded, the update fails
instead of installing an unchecked zip. No filter can change the key or the URLs.

WordPress applies offers for an `Update URI` plugin only after its own check against api.wordpress.org succeeds. A
host that blocks wordpress.org never sees this plugin's update either; the portal's version-lag column shows it.

## Release

What a developer and CI run (never in the promotion account, below):

```bash
bash scripts/build.sh <version>   # dist/puzzles-site-reports.zip, byte-reproducible
bash tests/smoke.sh               # Docker smoke test against a throwaway WordPress
bash tests/promote-dry-run.sh     # the promoter against a throwaway origin, keys and a stand-in for gh
```

1. After `main`'s CI is green, tag `vX.Y.Z` (exactly three numbers) on it and push the tag.
   `.github/workflows/release.yml` lints PHP 7.4 to 8.4, builds the zip, runs the smoke test on it and publishes the
   zip alone as a **pre-release**. It has no manifest, so no site is offered it.
2. Check it on the canary, a remote site with no secrets, never from the promotion machine (`wp --ssh=<canary>` or
   on its host):
   `wp plugin install https://github.com/puzzles-consulting/wp-site-reports/releases/download/vX.Y.Z/puzzles-site-reports.zip --force`
3. Promote it, which rolls it out to every site on its next update check, with the release key from the secret store
   in that one command's environment: `bash ~/bin/wp-sr-promote --repo <your promotion clone> vX.Y.Z <tested>`. Type
   `<tested>` yourself (the release notes say `Tested with WordPress 6.8.1`); never paste a command from release notes.
   Review what it prints before you type the version: that review is the control.

The promoter. No code from this repository ever runs in the promotion account: not `scripts/build.sh`, not the tests,
nothing under `scripts/` or `tests/`. [`scripts/wp-sr-promote`](scripts/wp-sr-promote) is the whole promoter and key
generator; its header says what it checks and what it needs. Review it by hand and install it outside the repository,
from a commit you reviewed:

```bash
git -C <clone> show <sha>:scripts/wp-sr-promote | cat -v      # review it, all of it
mkdir -p ~/bin && git -C <clone> show <sha>:scripts/wp-sr-promote >~/bin/wp-sr-promote
```

Re-installing a reviewed copy is the only way promotion changes: when a change to `scripts/wp-sr-promote` lands, review
`git -C <clone> show <sha>:scripts/wp-sr-promote | diff ~/bin/wp-sr-promote - | cat -v` and install it again. A change
to `scripts/build.sh` that changes the zip's bytes needs the same change in the promoter: until it is re-installed, it
refuses those releases.

The record. Each promotion prints the tag's commit and the zip's sha256 (keep both) and writes them to a local ref in
the clone it ran in, `refs/puzzles-sr/promoted/vX.Y.Z`: your statement of what you signed. GitHub's latest release must
be one you recorded, with that sha256, and the highest record is the baseline of the next review. Never push the
records, and never configure a refspec that writes them. Keep one promotion clone (`--repo` is its top folder) and always promote from it;
`git -C <clone> fetch origin` is all it needs. Dry runs go in throwaway clones: the promoter refuses a dry run in a
clone with a real record, and a real run in a clone with dry-run records.

- Another clone or machine: copy the records from the clone that has them:
  `git -C <new clone> fetch <old clone> 'refs/puzzles-sr/*:refs/puzzles-sr/*'` (a one-off command: it copies the
  records, any pending one and the commits they hold).
  If the old clone is lost, record GitHub's latest release (and your highest promotion, if it is another one) with the
  values its promotion printed: `bash ~/bin/wp-sr-promote record --repo <clone> vX.Y.Z <commit> <zip sha256>`. It
  checks that GitHub's zip has that sha256 and holds that commit's files.
- Bad release: `gh release edit vX.Y.Z --prerelease` stops the spread, and GitHub's latest falls back to an earlier
  release you recorded. Sites already on it are fixed only by rolling forward to `X.Y.Z+1`, promoted as usual. Never
  mark a key-rotation release pre-release (sites on it trust only the new key): fix forward with the new key. If your
  first promotion is the bad one, nothing is latest any more; the next promotion takes its key from your record.
  After an interrupted run, the promoter tells you what to do.

Branch protection on `main` and restricting who can create `v*` tags on GitHub are still recommended: they are
repository settings, the owner's decision.

The release key is created by the promoter: `bash ~/bin/wp-sr-promote keygen 3>&1 1>&2 | <store-secret-from-stdin>`.
The public key (on the terminal) goes into `PUZZLES_SR_UPDATE_PUBKEY`; the secret key goes from file descriptor 3
straight into the secret store, never through a file or an argument.

Rotating the key: sites trust only the key in the version they run, so the new key ships in a release signed with the
old one.

1. `bash ~/bin/wp-sr-promote keygen` a new pair into the secret store (keep the old one), put the new public key in
   `PUZZLES_SR_UPDATE_PUBKEY`, and release it as `vX.Y.Z` as above.
2. Promote it with the **old** key in `PUZZLES_SR_SIGNING_KEY`, the **new** secret key in `PUZZLES_SR_NEW_SIGNING_KEY`
   (the proof that it is yours) and `--rotate`: `bash ~/bin/wp-sr-promote --repo <clone> vX.Y.Z <tested> --rotate`.
3. Promote the next release, with the new key, only once the portal shows every site on `X.Y.Z` or later: a site still
   on an older version accepts only the old key and would never reach `X.Y.Z` once a newer release is latest. Then
   retire the old key.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
