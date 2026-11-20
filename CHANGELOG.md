# Changelog

All notable changes to this plugin are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.1]

The first release offered to sites. 1.0.0 was a pre-release only, never offered; its entries are under Added.

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

### Changed

- Every request must carry `_`, 32 lowercase hex characters fresh per request, or it gets the 401 (edge caches).
- Wordfence issues that would name a user (easy passwords, suspicious admin users) are reported with a fixed text.
- No auto-update email when a run only updated this plugin, successfully.

### Fixed

- Another source's update package for this plugin is refused at download and never forced to auto-install.
- `updatesCheckedAt` on WordPress 6.4 and older, where a successful check leaves `checked` empty, and next to
  third-party updaters that add their own offers to a failed check.
- `/seo` primes posts 20 at a time, so page-builder content stays within memory.
- A theme in a numeric folder is no longer reported as its own parent (WordPress 5.8).
