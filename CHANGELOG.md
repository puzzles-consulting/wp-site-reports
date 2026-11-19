# Changelog

All notable changes to this plugin are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

The first release, 1.0.0, once it is promoted.

### Added

- `GET /status` under `puzzles-reports/v1`: WordPress, PHP, plugins, themes, must-use plugins, available updates,
  Wordfence findings and the comment default.
- `GET /seo`: Rank Math focus keywords, scores, titles, descriptions and noindex of each published page and post.
- A token connection from Tools > Site Reports or `wp puzzles-site-reports connect`, stored only as its SHA-256 hash.
- Signed self-update from this repository's GitHub Releases, installed only when the download matches the SHA-256 that
  the release key (never in GitHub) signed. The download is capped at 5 MB and 60 seconds.
- Wordfence messages in `/status` carry no server path: absolute paths and every URL but an http(s) one are dropped
  (http(s) URLs stay).
- Page caches never keep a report: the routes define `DONOTCACHEPAGE` and tell LiteSpeed Cache not to cache.
