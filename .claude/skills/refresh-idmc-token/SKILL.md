---
name: refresh-idmc-token
description: >-
  Refresh IDMC tokens. Two separate kinds: (a) the MCP server token in
  ~/.claude.json (cdgcsearchmetadata, usermanagement, catalog-*, claire-*,
  data-marketplace-order-management), minted by OAuth 2.0 client credentials (all
  servers) or OAuth 2.1 auth code + PKCE (one server, user identity), with saved
  copies in ~/.idmc/mcp-oauth20-token.json / mcp-oauth21-token.json that can be
  re-applied with -ApplySaved (oauth21 also renews via -Refresh), and (b) the REST API
  token file ~/.idmc/api-token.json used by direct IDMC/CDGC REST calls and
  idmc-segment.mjs. TRIGGER when an IDMC MCP server fails to connect or returns
  401 / "Exception encountered while processing JWT" / AUTH_HEADER_REJECTED /
  "does not support dynamic client registration", when the user asks to clear
  MCP authentication, when a REST call or idmc-segment.mjs reports an expired/missing token, or when
  the user asks to refresh / renew the IDMC token or access token.
---

# Refresh IDMC tokens

There are **two separate tokens, stored in two separate places — never mix them**:

| Purpose | Script | Stored in |
|---|---|---|
| **MCP servers** | `refresh-token-mcp-oauth20.ps1` (OAuth 2.0 client-credentials, all servers) or `refresh-token-mcp-oauth21.ps1` (OAuth 2.1 auth code + PKCE, one server, user identity) | `~/.claude.json` → `projects["<project folder, forward slashes>"].mcpServers.<name>.headers.Authorization`; copies in `~/.idmc/mcp-oauth20-token.json` / `~/.idmc/mcp-oauth21-token.json` (per resource) |
| **REST APIs** (v3 admin, CDGC, `idmc-segment.mjs`) | `refresh-token-api-native.ps1` (password) or `refresh-token-api-browser.ps1` (SSO/browser) | `%USERPROFILE%\.idmc\api-token.json` (override `IDMC_API_TOKEN_FILE`) |

`refresh-token-api-native.ps1` and `refresh-token-api-browser.ps1` never touch `.claude.json`.
All scripts live in the project root (the folder that holds `.claude/skills`); run them from there.

## Which MCP refresh to use (an MCP server fails with 401 / AUTH_HEADER_REJECTED)
1. **Check the saved tokens first** — `expiresAt` in `~/.idmc/mcp-oauth20-token.json` and in the
   per-resource records of `~/.idmc/mcp-oauth21-token.json`. If one is still valid for the
   failing server, run `-ApplySaved` yourself (no prompt, no login):
   - all servers, service principal: `powershell -NoProfile -ExecutionPolicy Bypass -File refresh-token-mcp-oauth20.ps1 -ApplySaved`
   - one server, user identity: `powershell -NoProfile -ExecutionPolicy Bypass -File refresh-token-mcp-oauth21.ps1 -ApplySaved -Resource <name>`
     (the resource name is the last URL segment, e.g. `ordermanagement` for
     `data-marketplace-order-management`; without `-Resource` all unexpired records are applied)
   - OAuth 2.1 access token expired, but the record has a `refresh_token`: run `-Refresh`
     yourself (no prompt, no browser): `powershell -NoProfile -ExecutionPolicy Bypass -File refresh-token-mcp-oauth21.ps1 -Refresh -Resource <name>`
     (without `-Resource` all saved records are refreshed). It saves the new tokens and writes
     the header. On `invalid_grant` the refresh token is expired/revoked: log in again (A2).
2. Otherwise mint a new one: **A** (OAuth 2.0, all servers at once, needs the client secret)
   by default, or **A2** (OAuth 2.1, browser login, one server per run) when the user asks for
   it or the operation must run as the user (possibly `create_order` "only for yourself",
   which fails for the service principal; not yet verified with an OAuth 2.1 token).
3. Claude cannot reconnect a server: ask the user to run `/mcp` → reconnect the server(s)
   named in the script's `Now reconnect:` line.

"Incompatible auth server: does not support dynamic client registration" means the server has
**no** `Authorization` header (Claude Code then tries its own OAuth login, which IDMC does not
support). Same fix: write a token (step 1 or 2), then reconnect.

**Clearing MCP auth** (user asks to clear/reset authentication): `/mcp` → "Clear authentication"
only clears Claude Code's own OAuth login, not the header, and only the user can run it. To clear
the tokens themselves, back up `~/.claude.json` (e.g. `.claude.json.bak-clear-auth-<timestamp>`)
and delete `headers.Authorization` (and an empty `headers`) from the servers under
`projects["<project folder>"].mcpServers`; leave user-scope servers and other projects alone and
keep `~/.idmc`. Both MCP scripts re-create the header when they write a token.

## Important: Claude cannot answer the scripts' prompts

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
`refresh-token-mcp-oauth21.ps1` has no secret either, but its prompts (baseUrl, client_id,
redirect_uri, resource) need a console too: open its `.cmd` the same way, or run it yourself
with all of `-BaseUrl -ClientId -RedirectUri -Resource` passed (the user still logs in in
the browser). `-ApplySaved` (both MCP scripts) and `-Refresh` (oauth21) never prompt.

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

The token (never the secret) is also saved to `~/.idmc/mcp-oauth20-token.json`
(`source, loginUrl, clientId, sub, orgId, audience, servers, issuedAt, expiresAt,
access_token`). **Claude can run `-ApplySaved` itself** (no prompt) to write that saved
token back into all servers while it is unexpired:
```
powershell -NoProfile -ExecutionPolicy Bypass -File refresh-token-mcp-oauth20.ps1 -ApplySaved
```

## A2. One MCP server, user identity — `refresh-token-mcp-oauth21.ps1`
OAuth 2.1 authorization code + PKCE (public client, no secret). Prompts for baseUrl
(default `https://dm-em.informaticacloud.com`), client_id, redirect_uri (default
`http://localhost:9876/callback`) and resource (a number from the list of installed IDMC
servers, or a server name appended to `https://mcp.<host>/mcp-servers/public/`); opens the
browser, then `POST /authz-service/oauth2/token`. The token's `aud` is that one server, so it
is written only into the `.claude.json` server(s) with that url, and saved per resource in
`~/.idmc/mcp-oauth21-token.json`. ~1 h lifetime. Open it with
`cmd //c start "IDMC OAuth 2.1" refresh-token-mcp-oauth21.cmd`, or pass
`-BaseUrl -ClientId -RedirectUri -Resource` to skip the prompts. Claude can run
`-ApplySaved [-Resource <name>]` itself to re-apply saved, unexpired tokens, and
`-Refresh [-Resource <name>]` to get a new access token from the saved `refresh_token`
(`POST /authz-service/oauth2/token` with `grant_type=refresh_token, refresh_token, client_id,
resource`; a rotated refresh token is saved). Used live on 2026-10-16 (cdgcsearchmetadata,
usermanagement); whether IDMC rotates the refresh token, and how long it lives, is not yet verified.

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
- An OAuth 2.1 token is only valid for the server it was minted for (`aud` = that server's URL);
  on any other server it gets 401. The OAuth 2.0 token works on all IDMC MCP servers.
- The two MCP tokens are different identities: OAuth 2.0 = the OAuth app's service principal,
  OAuth 2.1 = the logged-in user. Operations run with that identity's privileges.
- `.claude.json` is what the servers use; the `mcp-oauth2*-token.json` files are only a record
  and the `-ApplySaved` / `-Refresh` source. Never put a REST token (`api-token.json` JWT) into `.claude.json`.
- Check the token's org (`orgName` in the token file) before REST calls — a token
  from another org fails, or acts on the wrong org.
