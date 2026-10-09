# IDMC MCP + segregation test toolkit

Claude Code project for Informatica IDMC / CDGC. It contains:

- **Skill `idmc-segregation-test`**: creates or deletes a segregation test entity `<E>` in an IDMC org:
  user group `Test-UG-<E>` (Governance Administrator), root asset group `<E>`, enabled user group
  policy `Test-UGP-<E>`, and test user `Test-U-<E>`.
- **Skill `refresh-idmc-token`**: refreshes the two IDMC tokens (see below).
- The scripts these skills use: `idmc-segment.mjs`, `refresh-token-*.ps1` / `.cmd`.

Once set up, ask Claude things like *"create a segregation test for Dummy 3"*,
*"delete the segregation entity CMC"* or *"refresh the IDMC token"*.

## Requirements

- Windows, with [Claude Code](https://claude.com/claude-code), Node.js 18+, Windows PowerShell 5.1+
  and Microsoft Edge (the browser login uses Edge remote debugging; Chrome's is blocked by corp policy).
- In the target IDMC org:
  - an **OAuth client** (client_id / client_secret) for the MCP servers;
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
   Only `usermanagement` is needed for the segregation skill. Don't put these servers in a shared
   `.mcp.json`: their tokens are personal.
3. Double-click `refresh-token-mcp-oauth20.cmd` and enter your OAuth client_id / client_secret.
   This writes the real token into the servers in `%USERPROFILE%\.claude.json`.
4. Get a REST API token: double-click `refresh-token-api-browser.cmd` (Edge login, no password
   typed), or `refresh-token-api-native.cmd` (username + password). It is saved to
   `%USERPROFILE%\.idmc\api-token.json`.
5. Start `claude` in this folder, run `/mcp`, and check that `usermanagement` is connected.
6. Check both tokens: `node idmc-segment.mjs check`. It should end with `ORG: MATCH`.

## The two tokens: keep them separate

| Token | Script | Stored in | Lifetime |
|---|---|---|---|
| MCP servers | `refresh-token-mcp-oauth20.cmd` (OAuth client credentials) | `%USERPROFILE%\.claude.json` | ~24 h |
| REST APIs (`idmc-segment.mjs`) | `refresh-token-api-browser.cmd` or `refresh-token-api-native.cmd` | `%USERPROFILE%\.idmc\api-token.json` | JWT ~30 min, re-minted automatically while the IDMC session lives |

Never put a user-login JWT into `.claude.json`. Both tokens must be for the **same org**;
`idmc-segment.mjs check` verifies this, and the skill refuses to create or delete anything otherwise.
No secret is stored in this folder: passwords and client secrets are only prompted.

## Environment overrides (optional)

| Variable | Used by | Purpose |
|---|---|---|
| `IDMC_USER` | `refresh-token-api-native.ps1` | Default username at the prompt |
| `IDMC_LOGIN_URL` | `refresh-token-api-native.ps1`, `refresh-token-mcp-oauth20.ps1` | Login host (default `https://dm-em.informaticacloud.com`) |
| `IDMC_BROWSER_LOGIN_URL` | `refresh-token-api-browser.ps1` | Default login page (e.g. an SSO URL `.../ma/sso/<orgId>`) |
| `IDMC_DEBUG_PORT`, `IDMC_PROFILE_DIR`, `IDMC_LOGIN_TIMEOUT`, `IDMC_BROWSER` | `refresh-token-api-browser.ps1` | Edge debug port, profile folder, wait time, browser path |
| `IDMC_API_TOKEN_FILE` | all REST scripts | REST token file location |
| `IDMC_ORG_ID` | `idmc-segment.mjs` | Pin to one org; refuses REST tokens from any other org |
| `IDMC_POD_URL` | `idmc-segment.mjs` | v3 admin API pod (default `https://emw1.dm-em.informaticacloud.com`) |
| `IDMC_MCP_PROJECT`, `CLAUDE_JSON` | `idmc-segment.mjs` | Where to find the MCP token (default: this folder's entry in `%USERPROFILE%\.claude.json`) |

## Troubleshooting

- `check` exits 3: a token is invalid. Re-run the refresh script it names.
- `check` exits 4: the tokens are for different orgs. Refresh one of them into the right org.
- MCP 401 / "Exception encountered while processing JWT": run `refresh-token-mcp-oauth20.cmd`,
  then `/mcp` → reconnect.
- 403 `ACCESS_DENIED`: the token is valid, but the user or client lacks privileges in that org.
