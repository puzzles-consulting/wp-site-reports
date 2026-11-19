# Contract

Two routes under `puzzles-reports/v1`, `GET /status` and `GET /seo`, share the authentication below.

## Authentication

Every route under `/wp-json/puzzles-reports/v1/` (or `?rest_route=/puzzles-reports/v1/...`) is GET only and answers with `Cache-Control: no-store`. The routes and the namespace are not listed in the public REST index (`/wp-json/`), but a direct request still reveals that the plugin is installed: without a valid token, `GET /puzzles-reports/v1` (the namespace itself) gets the same 401 as the routes, where a site without the plugin answers 404.

- Header: `X-Puzzles-Reports-Token: <64 hex characters>`.
- Refusal: HTTP 401, `{"code": "puzzles_reports_unauthorized", "message": "Not authorized."}`, the same for a missing token, a wrong token and a site with no connection.
- Any unexpected failure while building a report: HTTP 500, code `puzzles_reports_failed`, message `The report could not be built.`
- Connection string: `pzr1.` + base64url, no padding, of `{"site": "<home_url>", "token": "<64 hex>"}`. Creating a connection (Tools > Site Reports, or `wp puzzles-site-reports connect --porcelain`) rotates the token: the previous one stops working at once. The site stores only the SHA-256 hash and the creation time in the option `puzzles_site_reports_token`. Deactivating the plugin deletes it (the connection is revoked; a new one is needed after reactivating; a network deactivation deletes every site's of that network, an uninstall every site's); WordPress' own updates of the plugin do not.
- `wp puzzles-site-reports status` prints the version and whether a connection exists; it never prints the token.
- The routes answer to the token alone, even when another plugin or snippet refuses unauthenticated REST requests through `rest_authentication_errors`: for a request to this namespace the plugin's own filter (priority 999) passes a valid token and answers the fixed `puzzles_reports_unauthorized` 401 to a missing or wrong one, whatever an earlier filter returned. So a different refusal means the site blocks REST in a way this plugin does not override: a `rest_authentication_errors` filter running after priority 999, or a block before WordPress (web server, firewall, security plugin exiting early).

## GET /status

Reads what WordPress already knows. It never triggers an update check or a Wordfence scan, and it does not depend on who the current user is.

```json
{
  "companion": { "version": "1.0.0" },
  "wordpress": { "version": "6.7.1", "update": "6.8", "updatesCheckedAt": "2026-11-18T03:12:00Z" },
  "php": { "version": "8.2.12" },
  "plugins": [
    { "file": "wordfence/wordfence.php", "name": "Wordfence Security", "version": "8.0.1",
      "active": true, "update": "8.0.3", "autoUpdate": false }
  ],
  "mustUse": [ { "file": "lighthouse.php", "name": "...", "version": "..." } ],
  "themes": [ { "stylesheet": "astra-child", "name": "Astra Child", "version": "1.0", "active": true,
                "parent": "astra", "update": null } ],
  "wordfence": { "version": "8.0.1", "active": true, "lastScanAt": "2026-11-17T09:00:00Z",
                 "issues": [ { "type": "wfPluginUpgrade", "severity": 75, "shortMsg": "...", "firstSeenAt": "2026-11-16T09:00:00Z" } ],
                 "ignored": 3 },
  "comments": { "defaultStatus": "closed" }
}
```

- `update` (core, plugins, themes) is the version WordPress' own update data offers, or `null` for none.
- `updatesCheckedAt` is the oldest of the last checks of WordPress' three update transients (core, plugins, themes), in UTC (`...Z`). It is `null` when any of the three never ran; then every `update` means "unknown", never "up to date". The plugin never triggers an update check.
- `active` is a boolean; a network-active plugin counts as active. `autoUpdate` is true when the plugin is in WordPress' auto-update list, and only that: this plugin always installs its own updates, even when its own entry reads `false`.
- `mustUse` carries only `file`, `name` and `version`. A theme's `parent` is its parent's stylesheet, `null` when it has none; `active` is the stylesheet in use.
- `wordfence` is `null` when Wordfence is not installed, and also when it is active but cannot be read (its classes or the shape of its answers changed). When it is installed but inactive, `active` is `false`, `issues` is `[]`, `ignored` is `0` and `lastScanAt` is `null`: its classes are not loaded. Otherwise `issues` are Wordfence's open (status `new`) scan results through its own `wfIssues` class, at most 200, ordered as Wordfence orders them (severity, highest first). `severity` is the integer Wordfence stores (100 critical, 75 high, 50 medium, 25 low). `shortMsg` is plain text (each tag replaced by a space, entities decoded, every absolute server path removed: the content directory becomes `wp-content`, the install root and its parent disappear, any other Unix or Windows absolute path that does not continue a word, a relative path or a URL is dropped), cut to 300 characters. `firstSeenAt` is when Wordfence first stored the issue. Wordfence's per-issue `data` is never returned. `ignored` counts the ignored issues. `lastScanAt` is Wordfence's own last-scan time, `null` if it never scanned. The plugin never starts a scan. When `wordfence` is `null` but `plugins[]` contains `wordfence/wordfence.php`, the plugin is installed but could not be read (a Wordfence change); the portal shows "Wordfence could not be read", not "not installed".
- `comments.defaultStatus` is the site's `default_comment_status` (`open` or `closed`).
- No server path, database name, table prefix or token appears in the response.

## GET /seo

Reads Rank Math's own post meta. It derives nothing, never resolves Rank Math's defaults, and does not depend on who the current user is.

```json
{
  "plugin": { "name": "rank_math", "version": "1.0.230" },
  "types": { "page": { "items": 42, "truncated": false }, "post": { "items": 500, "truncated": true } },
  "items": [
    { "id": 12, "type": "page", "url": "https://acme.com/about/", "title": "About",
      "focusKeywords": ["roofing miami"], "seoScore": 81,
      "metaTitle": null, "metaDescription": "...", "noindex": null }
  ]
}
```

- `plugin` is `null`, `types` is `{}` and `items` is `[]` when Rank Math is not active (network-active counts). No other SEO plugin is read.
- Published `page` and `post`, and `product` when that post type exists, at most 500 per type. `types.<type>.items` is how many are returned and `truncated` is `true` when more than 500 exist.
- `title`, `focusKeywords`, `metaTitle` and `metaDescription` are plain text: markup stripped, entities decoded, trimmed. `focusKeywords` is Rank Math's comma list with empties dropped; `[]` when unset or blank.
- `seoScore` is Rank Math's stored score as an integer, or `null`.
- `metaTitle` and `metaDescription` are the post's own Rank Math values, or `null` when empty (the post uses Rank Math's template).
- `noindex` is `true` or `false` when the post sets its own robots in Rank Math (`rank_math_robots` holds a non-empty list; `true` when it contains `noindex`). It is `null` when the post has none, i.e. it follows Rank Math's defaults for its type (not resolved here).
- `title` is the post's own title (no "Protected:" or "Private:" prefix); `url` is its permalink, or `null` when WordPress cannot build one. Order within a type is newest first, ties by id descending.
- `plugin.version` is `null` if Rank Math does not expose its version constant.
- Only Rank Math's own meta keys are read (never the rest of a post's meta), so a page-builder site's large posts are not loaded.
