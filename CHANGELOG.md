# Changelog

All notable changes to this plugin are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.1] - 2026-11-20

The first release offered to sites (1.0.0 was a pre-release only).

### Added

- `GET /status` under `puzzles-reports/v1`: WordPress, PHP, plugins, themes, must-use plugins, available updates and
  when WordPress' update checks last got a real answer, Wordfence findings and the comment default.
- `GET /seo`: Rank Math focus keywords, scores, titles, descriptions and noindex of each published page and post,
  read 20 posts at a time so page-builder content stays within memory.
- A token connection from Tools > Site Reports or `wp puzzles-site-reports connect`, stored only as its SHA-256 hash.
  Every request also carries `_`, 32 lowercase hex fresh per request, so no cache can serve a report to another.
- Signed self-update from this repository's GitHub Releases, installed only when the download matches the SHA-256 that
  the release key (never in GitHub) signed; any other update package for this plugin is refused at download (an admin can still install over it by hand). No email when
  an automatic run only updated this plugin, successfully.
- Wordfence messages in `/status` carry no server path (absolute paths and every URL but an http(s) one are dropped),
  and issues that would name a user (easy passwords, suspicious admin users) carry a fixed text.
- Page caches never keep a report: the routes define `DONOTCACHEPAGE` and tell LiteSpeed Cache not to cache.
