# Changelog

All notable changes to this plugin are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

1.0.1, the first release to be promoted (1.0.0 was a pre-release only, never offered to sites).

### Added

- `GET /status` under `puzzles-reports/v1`: WordPress, PHP, plugins, themes, must-use plugins, available updates,
  Wordfence findings and the comment default.
- `GET /seo`: Rank Math focus keywords, scores, titles, descriptions and noindex of each published page and post.
- A token connection from Tools > Site Reports or `wp puzzles-site-reports connect`, stored only as its SHA-256 hash.
- Signed self-update from this repository's GitHub Releases, installed only when the download matches the SHA-256 that
  the release key (never in GitHub) signed.
- Wordfence messages in `/status` carry no server path: absolute paths and every URL but an http(s) one are dropped
  (http(s) URLs stay).
- Page caches never keep a report: the routes define `DONOTCACHEPAGE` and tell LiteSpeed Cache not to cache.
- Edge caches cannot serve a report to others: every request must carry a fresh `_` (32 hex), or it gets the 401.
- Wordfence issues that would name a user (easy passwords, suspicious admin users) are reported with a fixed text.
- Only this plugin's own signed update is offered, auto-installed and downloaded for it; another source's is dropped.
- No auto-update email when a run updated only this plugin.
- `updatesCheckedAt` is right on WordPress 6.4 and older, where a successful check leaves `checked` empty.
- `/seo` primes posts 20 at a time, so page-builder content stays within memory.
