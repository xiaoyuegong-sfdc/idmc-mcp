---
name: refresh-idmc-token
description: >-
  Refresh IDMC tokens. Two separate kinds: (a) the MCP server token in
  ~/.claude.json (cdgcsearchmetadata, usermanagement, catalog-*, claire-*,
  data-marketplace-order-management) and (b) the REST API
  token file ~/.idmc/api-token.json used by direct IDMC/CDGC REST calls and
  idmc-segment.mjs. TRIGGER when an IDMC MCP server fails to connect or returns
  401 / "Exception encountered while processing JWT" / AUTH_HEADER_REJECTED,
  when a REST call or idmc-segment.mjs reports an expired/missing token, or when
  the user asks to refresh / renew the IDMC token or access token.
---

# Refresh IDMC tokens

There are **two separate tokens, stored in two separate places — never mix them**:

| Purpose | Script | Stored in |
|---|---|---|
| **MCP servers** | `refresh-token-mcp-oauth20.ps1` (OAuth 2.0 client-credentials) — the ONLY one | `~/.claude.json` → `projects["<project folder, forward slashes>"].mcpServers.<name>.headers.Authorization` |
| **REST APIs** (v3 admin, CDGC, `idmc-segment.mjs`) | `refresh-token-api-native.ps1` (password) or `refresh-token-api-browser.ps1` (SSO/browser) | `%USERPROFILE%\.idmc\api-token.json` (override `IDMC_API_TOKEN_FILE`) |

`refresh-token-api-native.ps1` and `refresh-token-api-browser.ps1` never touch `.claude.json`.
All scripts live in the project root (the folder that holds `.claude/skills`); run them from there.

## Important: Claude cannot run the password/secret scripts directly

`refresh-token-api-native.ps1` and `refresh-token-mcp-oauth20.ps1` prompt via
`Read-Host -AsSecureString`, which **ignores piped stdin** — piping creds just hangs
(stop it with TaskStop). The `!` prefix doesn't work either: it has no console input,
so `Read-Host` gets an empty value ("client_id is required"). **Open the `.cmd` in its
own console window** (Claude can run this; the user types the secrets there, and
Claude never sees them):
```
cmd //c start "IDMC refresh" <script>.cmd
```
Or the user double-clicks the `.cmd`. Ask the user to tell you when it has finished.
`refresh-token-api-browser.ps1` has no secret prompt, so **Claude can run it**.

## A. MCP server token — `refresh-token-mcp-oauth20.ps1`
Prompts for `client_id` / `client_secret`, then
`POST /authz-service/oauth/token?grant_type=client_credentials&client_id=…&client_secret=…`
and writes `Bearer <access_token>` into every server in `$ServerNames`
(backs up `.claude.json` to `.claude.json.bak` once). Token lifetime 24 h (as of 2026-10-09).

Open it in a new console window:
```
cmd //c start "IDMC MCP OAuth refresh" refresh-token-mcp-oauth20.cmd
```
Then `/mcp` → reconnect the IDMC servers. To add a new IDMC MCP server, add its name
to `$ServerNames` in this script.

## B. REST API token — `refresh-token-api-native.ps1` or `refresh-token-api-browser.ps1`
Both mint a user-login JWT (`/identity-service/api/v1/jwt/Token?client_id=idmc_api`,
~30 min) and save JSON `{source, baseUrl, user, orgId, orgName, issuedAt, expiresAt,
sessionId, jwt}`. Use `sessionId` as `INFA-SESSION-ID` for the v3 admin API (it rejects
the JWT) and `jwt` as `Authorization: Bearer` for CDGC APIs. `idmc-segment.mjs`
re-mints the JWT from `sessionId` automatically while the IDMC session is alive.

### B1 — password (`refresh-token-api-native.ps1`)
Prompts for the username (default from `IDMC_USER`, if set) and password; `/Login` → sessionId → jwt/Token.
```
cmd //c start "IDMC REST token refresh" refresh-token-api-native.cmd
```

### B2 — browser SSO (`refresh-token-api-browser.ps1`)
Opens the login URL in Edge with a DevTools debug port and a dedicated profile, waits
for the login, reads the `IDS-SESSION` cookie, and exchanges it with header
`IDS-SESSION-ID` for `jwt_token`.

Steps for Claude:
1. Ask the user to confirm the login URL of the **target org**. The default is
   `https://dm-em.informaticacloud.com/identity-service/home` (native IDMC login on the
   EMEA pod; override with `IDMC_BROWSER_LOGIN_URL`). For an SSO org, use its
   `https://<pod>.informaticacloud.com/ma/sso/<orgId>` URL. `idmc-segment.mjs` works in any
   org: it uses the org of this token, and its `check` compares that org with the MCP token's.
2. Run it yourself in the background (it waits up to 300 s, `IDMC_LOGIN_TIMEOUT`). Use a
   separate debug port and profile per org, so each org's login is remembered:
   ```
   IDMC_DEBUG_PORT=<port> IDMC_PROFILE_DIR="$(cygpath -w "$TEMP")\\idmc-login-edge-<orgId>" powershell -NoProfile -ExecutionPolicy Bypass -File refresh-token-api-browser.ps1 -LoginUrl "<url>"
   ```
3. Tell the user to log in in the Edge window. It finishes on its own
   (`>> Saved REST API token to ...`); if the profile's session is alive, no login is needed.

Notes: Chrome is not used — corp policy blocks its debug port. There is no
`UserProfile` cookie; the session id is `IDS-SESSION`. Overrides: `IDMC_BROWSER`, `IDMC_BROWSER_LOGIN_URL`,
`IDMC_DEBUG_PORT`, `IDMC_PROFILE_DIR`, `IDMC_LOGIN_TIMEOUT`, `IDMC_API_TOKEN_FILE`.

## Gotchas
- A 403 `ACCESS_DENIED` is a privilege problem, not a token problem — don't re-refresh.
- MCP endpoints need `type: http` + `Bearer <jwt>`; a raw `IDS-SESSION-ID` header does not work.
- Check the token's org (`orgName` in the token file) before REST calls — a token
  from another org fails, or acts on the wrong org.
