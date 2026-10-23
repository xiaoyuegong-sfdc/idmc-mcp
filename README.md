# IDMC MCP + segregation test toolkit

Claude Code project for Informatica IDMC / CDGC. It contains:

- **Skill `idmc-segregation-test`**: creates or deletes a segregation test entity `<E>` in an IDMC org:
  user group `Test-UG-<E>` (Governance Administrator), root asset group `<E>`, enabled user group
  policy `Test-UGP-<E>`, and test user `Test-U-<E>` (via the `usermanagement` MCP, or via REST
  when the MCP token is missing or invalid).
- **Skill `refresh-idmc-token`**: refreshes or invalidates the IDMC tokens, which are the MCP
  server token (OAuth 2.0 or OAuth 2.1) and the REST API token (see below).
- The scripts these skills use: `idmc-segment.mjs`, `refresh-token-*.ps1` / `.cmd`,
  `invalidate-token-mcp.ps1` / `.cmd`, `invalidate-token-api.ps1` / `.cmd`.

Once set up, ask Claude things like *"create a segregation test for Dummy 3"*,
*"delete the segregation entity CMC"*, *"refresh the IDMC token"* or *"invalidate the MCP tokens"*.

## Requirements

- Windows, with [Claude Code](https://claude.com/claude-code), Node.js 18+, Windows PowerShell 5.1+
  and Microsoft Edge (the browser login uses Edge remote debugging; Chrome's is blocked by corp policy).
- In the target IDMC org:
  - an **OAuth client** (client_id / client_secret) for the MCP servers (OAuth 2.0), and/or
    a **public OAuth client** (client_id only) with redirect URI `http://localhost:9876/callback`
    registered, for the per-user OAuth 2.1 login;
  - a user login with admin rights (it creates user groups, asset groups, policies and users).
- Defaults are for the EMEA pod (`dm-em`). For another pod, set `IDMC_POD_URL` / `IDMC_LOGIN_URL`,
  and check the hosts at the top of `idmc-segment.mjs`.

## Setup

1. Extract or clone this folder anywhere, e.g. `C:\work\idmc-mcp`, and run every command below
   **from that folder**.
2. Add the IDMC MCP servers at local scope (the default), with a placeholder token:
   ```
   claude mcp add --transport http usermanagement https://mcp.dm-em.informaticacloud.com/mcp-servers/public/usermanagement --header "Authorization: Bearer x"
   claude mcp add --transport http cdgcsearchmetadata https://mcp.dm-em.informaticacloud.com/mcp-servers/public/cdgcsearchmetadata --header "Authorization: Bearer x"
   claude mcp add --transport http catalog-discovery https://mcp.dm-em.informaticacloud.com/mcp-servers/public/cdgccatalogdiscovery --header "Authorization: Bearer x"
   claude mcp add --transport http catalog-enrichment https://mcp.dm-em.informaticacloud.com/mcp-servers/public/cdgccatalogenrichment --header "Authorization: Bearer x"
   claude mcp add --transport http claire-data-exploration-agent-mcp https://mcp.dm-em.informaticacloud.com/mcp-servers/public/dataexplorationagent --header "Authorization: Bearer x"
   claude mcp add --transport http data-marketplace-order-management https://mcp.dm-em.informaticacloud.com/mcp-servers/public/ordermanagement --header "Authorization: Bearer x"
   ```
   Only `usermanagement` is used by the segregation skill, and it is optional there (the skill
   falls back to REST for the test user). Don't put these servers in a shared
   `.mcp.json`: their tokens are personal.
3. Double-click `refresh-token-mcp-oauth20.cmd` and enter your OAuth client_id / client_secret.
   This writes the real token into the servers in `%USERPROFILE%\.claude.json`.
   Alternatively, run `refresh-token-mcp-oauth21.cmd` once per server to log in as yourself in the browser
   (see [OAuth 2.1 login](#oauth-21-login-one-server-as-your-user)).
4. Get a REST API token: double-click `refresh-token-api-browser.cmd` (Edge login, no password
   typed), or `refresh-token-api-native.cmd` (username + password). It is saved to
   `%USERPROFILE%\.idmc\api-token.json`.
5. Start `claude` in this folder, run `/mcp`, and check that `usermanagement` is connected.
6. Check both tokens: `node idmc-segment.mjs check`. It should end with `ORG: MATCH`
   (or `ORG: REST ONLY` if you skip the MCP token).

## The tokens: keep MCP and REST separate

| Token | Script | Stored in | Lifetime |
|---|---|---|---|
| MCP servers (all at once, service principal) | `refresh-token-mcp-oauth20.cmd` (OAuth 2.0 client credentials) | `%USERPROFILE%\.claude.json`; copy in `%USERPROFILE%\.idmc\mcp-oauth20-token.json` | ~24 h |
| MCP server (one per run, your user) | `refresh-token-mcp-oauth21.cmd` (OAuth 2.1 authorization code + PKCE, browser login) | `%USERPROFILE%\.claude.json`; copy per resource in `%USERPROFILE%\.idmc\mcp-oauth21-token.json` | ~1 h |
| REST APIs (`idmc-segment.mjs`) | `refresh-token-api-browser.cmd` or `refresh-token-api-native.cmd` | `%USERPROFILE%\.idmc\api-token.json` | JWT ~30 min, re-minted automatically while the IDMC session lives |

Never put the REST API JWT (`api-token.json`) into `.claude.json`; only the MCP OAuth tokens
belong there. When the MCP and REST tokens are both valid they must be for the
**same org**; `idmc-segment.mjs check` verifies this, and the skill refuses to create or delete
anything otherwise. With only a valid REST API token, everything (including the user) goes via REST.
No secret is stored in this folder: passwords and client secrets are only prompted.

`.claude.json` is what the MCP servers actually use; the `mcp-oauth2*-token.json` files are a
record (issued/expiry, org, subject) and the source for `-ApplySaved`, which writes a saved,
unexpired token back into the servers without a new login or secret, e.g.
`refresh-token-mcp-oauth20.cmd -ApplySaved` after an OAuth 2.1 token replaced one server's header,
or `refresh-token-mcp-oauth21.cmd -ApplySaved [-Resource <name>]`. An OAuth 2.1 token is only
valid for the one server it was minted for (`aud` = that server's URL).
The OAuth 2.1 record also keeps the `refresh_token`: `refresh-token-mcp-oauth21.cmd -Refresh
[-Resource <name>]` uses it to get a new access token (no browser, no prompt) once the ~1 h token
has expired, saves the new tokens and writes the header; then `/mcp` -> reconnect.

## Invalidating tokens

Two scripts remove the stored tokens again, one per kind; neither touches the other kind.
Both list what they will remove and ask for confirmation (`-Force` skips it, `-WhatIf` only lists).

| Script | Removes | Options |
|---|---|---|
| `invalidate-token-mcp.cmd` | For every local MCP server of this project: the `Authorization` header in `.claude.json` and Claude Code's own OAuth login in `.claude\.credentials.json` (what `/mcp` → "Clear authentication" removes); both files are backed up to `*.bak-invalidate-<timestamp>`. Then deletes the saved MCP access and refresh tokens `mcp-oauth20-token.json` and `mcp-oauth21-token.json`. | `-Project <folder>` (default: this folder) |
| `invalidate-token-api.cmd` | Logs the IDMC session out (`POST <baseUrl>/saas/public/core/v3/logout` with the saved session id, so `idmc-segment.mjs` can no longer re-mint a JWT from it) and deletes `api-token.json`. | `-NoLogout` (only delete the file), `-Profiles` (also delete the Edge login profiles `%TEMP%\idmc-login-edge*`, so the next browser refresh asks for a login) |

The MCP tokens are only deleted locally, not revoked at IDMC: an access token copied elsewhere
stays valid until it expires. Afterwards the MCP servers fail with "does not support dynamic
client registration" until you write a new token (`-ApplySaved` / `-Refresh` have nothing left
to use), and a running Claude Code session keeps its open connections until `/mcp` → reconnect.

## OAuth 2.0 client credentials (all servers, service principal)

`refresh-token-mcp-oauth20.cmd` uses the OAuth 2.0 client credentials grant. It prompts for
`client_id` and `client_secret` (the secret is read securely, never displayed or stored) and
uses the login host `https://dm-em.informaticacloud.com` (or `IDMC_LOGIN_URL`). The token
acts as the OAuth app's service principal, not as a user, and is written into every IDMC MCP
server in `.claude.json` (`cdgcsearchmetadata`, `usermanagement`,
`claire-data-exploration-agent-mcp`, `catalog-discovery`, `catalog-enrichment`,
`data-marketplace-order-management`).

### API call

It makes one call, with no browser, no PKCE, no `scope` and no `resource`. Unlike the OAuth 2.1
script, it uses the `/oauth/token` path (not `/oauth2/token`), and the parameters go in the
**query string**, not in a form body:
```http
POST https://dm-em.informaticacloud.com/authz-service/oauth/token?grant_type=client_credentials&client_id=<client_id>&client_secret=<client_secret>
```
(no request body; `client_id` and `client_secret` are URL-encoded)

curl equivalent:
```bash
curl -X POST -G "https://dm-em.informaticacloud.com/authz-service/oauth/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET"
```
The script accepts either a raw token string or JSON, and takes the token from the first field
it finds of `access_token`, `jwt_token` or `token`. It then:
1. decodes the JWT claims to get `sub`, `org_id`, `aud` and the expiry (`exp`, falling back to
   `expires_in`);
2. saves the token (never the secret) with those claims to
   `%USERPROFILE%\.idmc\mcp-oauth20-token.json`;
3. sets `Authorization: Bearer <token>` on every server above in `.claude.json` (it backs up
   `.claude.json.bak` the first time). Then reconnect the servers in `/mcp`.

The grant returns no refresh token, so there is no `-Refresh`: when the token expires, run the
script again. `-ApplySaved` makes no API call; it writes the saved token back into the servers
as long as it has not expired.

## OAuth 2.1 login (one server, as your user)

`refresh-token-mcp-oauth21.cmd` uses the authorization code grant with PKCE (S256). It is a
public client, so no secret is needed. It prompts for:

| Prompt | Default | Parameter |
|---|---|---|
| `baseUrl` | `https://dm-em.informaticacloud.com` (or `IDMC_LOGIN_URL`) | `-BaseUrl` |
| `client_id` | none | `-ClientId` |
| `redirect_uri` | `http://localhost:9876/callback` (must be `http` on localhost/127.0.0.1) | `-RedirectUri` |
| `resource` | none; lists the IDMC MCP servers installed in `.claude.json` to pick by number, or type a name. It is appended to `https://mcp.<baseUrl host>/mcp-servers/public/` | `-Resource` |

The script then:
1. opens the browser at `<baseUrl>/authz-service/oauth2/authorize` and waits for the login on `redirect_uri`;
2. sends `POST <baseUrl>/authz-service/oauth2/token` (form-encoded: `grant_type=authorization_code`,
   `code`, `redirect_uri`, `client_id`, `code_verifier`, `resource`);
3. saves the response under its resource URL in `%USERPROFILE%\.idmc\mcp-oauth21-token.json`;
4. writes the token into every server in `.claude.json` with that URL and tells you which one
   to reconnect in `/mcp`.

The token acts as the logged-in user (not the OAuth app's service principal), so operations
run with your own IDMC privileges. It lasts ~1 h; renew it without login via `-Refresh`. `-ShowDetails` prints every request and
response parameter and the token claims (tokens masked). Example without prompts:
```
refresh-token-mcp-oauth21.cmd -BaseUrl https://dm-em.informaticacloud.com -ClientId <id> -RedirectUri http://localhost:9876/callback -Resource usermanagement
```

### API calls

All values below use the default `baseUrl`; `<resource>` is the full MCP resource URL
`https://mcp.dm-em.informaticacloud.com/mcp-servers/public/<server name>`.

**1. Authorize (browser).** The script generates a random 32-byte `code_verifier` (base64url,
43 chars), `code_challenge = BASE64URL(SHA256(code_verifier))` and a GUID `state`, then opens:
```
GET https://dm-em.informaticacloud.com/authz-service/oauth2/authorize
    ?response_type=code
    &client_id=<client_id>
    &redirect_uri=http://localhost:9876/callback
    &scope=mcp:tools:read mcp:tools:write mcp:tools:execute
    &state=<guid>
    &code_challenge=<code_challenge>
    &code_challenge_method=S256
    &resource=<resource>
```
After login, IDMC redirects to `redirect_uri?code=...&state=...`. The local listener checks
that `state` matches and takes the `code`.

**2. Token exchange.** This is the call that returns the access token (public client, no secret;
the `code_verifier` proves the caller started the login):
```http
POST https://dm-em.informaticacloud.com/authz-service/oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=<code from the callback>
&redirect_uri=http://localhost:9876/callback
&client_id=<client_id>
&code_verifier=<code_verifier>
&resource=<resource>
```
curl equivalent:
```bash
curl -X POST "https://dm-em.informaticacloud.com/authz-service/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=http://localhost:9876/callback" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "code_verifier=$CODE_VERIFIER" \
  --data-urlencode "resource=https://mcp.dm-em.informaticacloud.com/mcp-servers/public/$SERVER"
```
The response holds `access_token`, `token_type`, `expires_in`, `scope` and optionally
`refresh_token`. The script saves it and sets `Authorization: Bearer <access_token>` on the
matching MCP servers in `.claude.json`.

**3. Refresh (`-Refresh`).** No browser; same endpoint, using the saved record:
```http
POST https://dm-em.informaticacloud.com/authz-service/oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=<saved refresh_token>
&client_id=<saved clientId>
&resource=<resource>
```
A rotated `refresh_token` in the response replaces the saved one; if none is returned the old
one is kept. `invalid_grant` means the refresh token expired or was revoked, so log in again
without `-Refresh`.

## Environment overrides (optional)

| Variable | Used by | Purpose |
|---|---|---|
| `IDMC_USER` | `refresh-token-api-native.ps1` | Default username at the prompt |
| `IDMC_LOGIN_URL` | `refresh-token-api-native.ps1`, `refresh-token-mcp-oauth20.ps1`, `refresh-token-mcp-oauth21.ps1`, `invalidate-token-api.ps1` | Login host (default `https://dm-em.informaticacloud.com`; the OAuth 2.1 script prompts with it as default; the API invalidation uses it only if the token has no `baseUrl`) |
| `IDMC_OAUTH20_TOKEN_FILE`, `IDMC_OAUTH21_TOKEN_FILE` | `refresh-token-mcp-oauth20.ps1`, `refresh-token-mcp-oauth21.ps1`, `invalidate-token-mcp.ps1` | Saved MCP token file locations |
| `IDMC_BROWSER_LOGIN_URL` | `refresh-token-api-browser.ps1` | Default login page (e.g. an SSO URL `.../ma/sso/<orgId>`) |
| `IDMC_DEBUG_PORT`, `IDMC_PROFILE_DIR`, `IDMC_LOGIN_TIMEOUT`, `IDMC_BROWSER` | `refresh-token-api-browser.ps1` (`IDMC_PROFILE_DIR` also `invalidate-token-api.ps1 -Profiles`) | Edge debug port, profile folder, wait time, browser path |
| `IDMC_API_TOKEN_FILE` | all REST scripts | REST token file location |
| `IDMC_ORG_ID` | `idmc-segment.mjs` | Pin to one org; refuses REST tokens from any other org |
| `IDMC_POD_URL` | `idmc-segment.mjs` | v3 admin API pod (default `https://emw1.dm-em.informaticacloud.com`) |
| `CLAUDE_JSON` | `idmc-segment.mjs`, `refresh-token-mcp-oauth20.ps1`, `refresh-token-mcp-oauth21.ps1`, `invalidate-token-mcp.ps1` | Claude config holding the MCP tokens (default `%USERPROFILE%\.claude.json`) |
| `IDMC_MCP_PROJECT` | `idmc-segment.mjs` | Project entry in that file to read the MCP token from (default: this folder) |

## Troubleshooting

- `check` exits 3: a token is invalid. Re-run the refresh script it names.
- `check` exits 4: the tokens are for different orgs. Refresh one of them into the right org.
- `check` exits 5: the REST API token is fine but the MCP token is missing or invalid. The skill
  then creates/deletes the test user via REST (`idmc-segment.mjs create "<E>" --email=<address>`,
  `delete "<E>" --yes`) instead of the `usermanagement` MCP.
- MCP 401 / "Exception encountered while processing JWT": run `refresh-token-mcp-oauth20.cmd`
  (or `-ApplySaved` if the saved token is still valid), or `refresh-token-mcp-oauth21.cmd` for one
  server, then `/mcp` → reconnect.
- MCP 401 right after an OAuth 2.1 refresh: the token was minted for another server (`aud`), or it
  expired (~1 h). Run `refresh-token-mcp-oauth21.cmd -Refresh -Resource <name>` (uses the saved
  refresh token, no login), mint one for that server, or `-ApplySaved -Resource <name>` if the saved
  token is still valid. `invalid_grant` on `-Refresh` means the refresh token expired: log in again.
- MCP "Incompatible auth server: does not support dynamic client registration": the server has no
  `Authorization` header, so Claude Code tries its own OAuth login, which IDMC does not support.
  Write a token with one of the MCP scripts (or `-ApplySaved` / `-Refresh`), then `/mcp` → reconnect.
- Resetting MCP auth: `/mcp` → "Clear authentication" only clears Claude Code's own OAuth login
  for that server, not the `Authorization` header in `.claude.json`, so an expired header keeps
  failing. Run `invalidate-token-mcp.cmd` (see [Invalidating tokens](#invalidating-tokens)), then
  write fresh tokens as above.
- OAuth 2.1 login fails with a redirect/client error: the `redirect_uri` must exactly match one
  registered for the client. If port 9876 is in use, register and enter another loopback URI.
- 403 `ACCESS_DENIED`: the token is valid, but the user or client lacks privileges in that org.
