# Contract

The routes (`puzzles-reports/v1`) are documented here as the tasks that add them land.

## Authentication

Every route under `/wp-json/puzzles-reports/v1/` (or `?rest_route=/puzzles-reports/v1/...`) is GET only and answers with `Cache-Control: no-store`. The routes and the namespace are not listed in the public REST index (`/wp-json/`), but a direct request still reveals that the plugin is installed: core answers `GET /puzzles-reports/v1` itself.

- Header: `X-Puzzles-Reports-Token: <64 hex characters>`.
- Refusal: HTTP 401, `{"code": "puzzles_reports_unauthorized", "message": "Not authorized."}`, the same for a missing token, a wrong token and a site with no connection.
- Any unexpected failure while building a report: HTTP 500, code `puzzles_reports_failed`, message `The report could not be built.`
- Connection string: `pzr1.` + base64url, no padding, of `{"site": "<home_url>", "token": "<64 hex>"}`. Creating a connection (Tools > Site Reports, or `wp puzzles-site-reports connect --porcelain`) rotates the token: the previous one stops working at once. The site stores only the SHA-256 hash and the creation time in the option `puzzles_site_reports_token`.
- `wp puzzles-site-reports status` prints the version and whether a connection exists; it never prints the token.
- The routes answer to the token alone, even when another plugin or snippet refuses every unauthenticated REST request: the plugin lets a request through that check only when it is for this namespace and carries a valid token.
