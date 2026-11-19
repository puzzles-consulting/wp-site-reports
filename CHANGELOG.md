# Changelog

All notable changes to this plugin are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-11-18

### Added

- Read-only status and SEO reports of the site for Puzzles' client reports: `GET /status` (WordPress, PHP, plugins,
  themes, must-use plugins, available updates, Wordfence findings, comment default) and `GET /seo` (Rank Math focus
  keywords, scores, titles, descriptions and noindex per published page and post), under `puzzles-reports/v1`.
- Token connection: Tools > Site Reports or `wp puzzles-site-reports connect` creates a connection string; the site
  stores only the token's SHA-256 hash, and creating a new connection revokes the old one at once.
- Signed self-update from this repository's GitHub Releases through WordPress' own update check, installed
  automatically. A release is offered only once its manifest carries an Ed25519 signature by the release key (which
  never lives in GitHub) and the downloaded zip matches the signed SHA-256; a pre-release reaches no site.
