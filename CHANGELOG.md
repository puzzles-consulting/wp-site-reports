# Changelog

All notable changes to this plugin are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.3] - 2026-11-20

### Fixed

- `updatesCheckedAt` and `wordpress.updatesCheckedAt` stayed `null` on sites whose host answers WordPress' update checks
  from a mirror through `pre_http_request` (WP Engine): a mirror's answer handed to WordPress' own check now counts when
  it is the response of the mirror's real request; a canned answer (an update disabler's) does not, even one that
  replaces a mirror's answer.
- A request another plugin makes from inside WordPress' update check no longer counts as the check's answer, whatever
  HTTP wrapper it uses.
- `/status` reports `autoUpdate: true` for this plugin's own row when WordPress' automatic updater can run: it installs
  its own signed updates.
- An update offered with a leading `v` (`v2.1`) is no longer hidden, nor outranked by a lower snapshot; it is reported as
  offered.

## [1.0.2] - 2026-11-20

No change in behaviour: a release to confirm that sites on 1.0.1 update automatically.

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
