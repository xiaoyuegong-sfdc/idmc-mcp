---
name: idmc-segregation-test
description: >-
  Build (or tear down) an IDMC/CDGC segregation test solution for one entity
  (asset group) in the IDMC org of the current tokens: user group Test-UG-<entity> with the
  Governance Administrator role, a root-level
  asset group <entity>, an enabled user group policy Test-UGP-<entity> with full
  rules, and a test user Test-U-<entity> in that user group. TRIGGER when the
  user asks to create/build/set up a segregation test, a test segment, or a
  test asset group + user group + policy + user for an entity, or to delete /
  remove / tear down / clean up a segregation entity.
---

Two options: **Create** (steps 1–5) and **Delete** (section D). Pick the one that
matches the request; if it's unclear, ask.

# IDMC segregation test for one entity

Creates four things for an entity `<E>` in the **target org**. The org isn't fixed:
it is the org of the tokens. The REST API token (`orgId` in `~/.idmc/api-token.json`)
drives the script, and the MCP token (its `org_id` claim) drives the `usermanagement`
tools. When both are usable they must point to the same org (see step 2).

| # | Asset | Name | Created via |
|---|---|---|---|
| 1 | User group, role Governance Administrator | `Test-UG-<E>` | REST (`idmc-segment.mjs`) |
| 2 | Asset group at the root level, published | `<E>` | REST (`idmc-segment.mjs`) |
| 3 | User group policy, user group 1 + asset group 2 on all 5 rules, published + enabled | `Test-UGP-<E>` | REST (`idmc-segment.mjs`) |
| 4 | User in user group 1 | `Test-U-<E>` | `usermanagement` MCP `create_user`; **REST fallback** (`idmc-segment.mjs create --email=`) |

**User path.** Asset 4 (create, look up, delete) goes through the `usermanagement` MCP
by default. Use the **REST path** instead (the v3 users API in `idmc-segment.mjs`, with the
REST API token) when any of these is true:
- `check` exits 5: the MCP token is missing, expired or rejected;
- the `mcp__usermanagement__*` tools aren't available in this session (server failed to connect);
- an MCP user call fails with 401 / `AUTH_HEADER_REJECTED` / "Exception encountered while processing JWT".

Don't stop to refresh the MCP token in these cases; say in the plan that the user goes via
REST and why. (The user can still choose to refresh the MCP token instead.)

User fields: First Name `GovAdmin`, Last Name `<E>`, Job Title `Segregation Test Account`,
Phone `+0123456789`, E-Mail `<email>`.

The script is `idmc-segment.mjs` in the project root (the folder that holds `.claude/skills`). It holds the naming
patterns, the descriptions and the policy rules. Run it from the project root.

## Step 1: collect the inputs
Ask the user for both inputs at once, unless they already gave them:
- **Entity name** `<E>`, e.g. `Dummy 3`.
- **Valid email** for the test user. Check it looks like `name@domain.tld`; ask again if it doesn't.
  IDMC sends this address an activation email, because no password is set.

## Step 2: check both tokens and the org
```
node idmc-segment.mjs check
```
This makes a live call with each token. It prints one line per token, then an
`ORG:` line that compares the REST API token's org with the MCP token's org.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | Both valid, `ORG: MATCH` | Use that org. **Don't ask** the user about the org; just state it (name + ID) in the plan. |
| 3 | The REST API token is invalid (the MCP token may be too) | Refresh the REST API token (below). The `ORG:` line shows which org each token belongs to, so refresh into the right one. |
| 4 | Both valid, `ORG: MISMATCH`: the orgs differ, or one token has no org | Ask the user to confirm the target org (below). |
| 5 | REST API token valid, MCP token missing/invalid, `ORG: REST ONLY` | Use the REST API token's org and the **REST user path**. Don't ask about the org; state it in the plan. |

**Org confirmation (exit 4 only).** AskUserQuestion: "The REST API token is for org
`<name>` (`<id>`) but the MCP token is for org `<id>`. Which org should the test
assets go to?" Give one option per org found, plus Cancel. Then refresh the token that
points to the **other** org, so both match the chosen one:
- To change the REST API token's org, log in to the chosen org with the REST refresh below.
- To change the MCP token's org, run the OAuth refresh with that org's client credentials.

Re-run `check`, and continue only on exit 0. Never create or delete anything while the
orgs differ.

Refreshes:
- **REST API token** (`~/.idmc/api-token.json`, used for assets 1–3) is INVALID or in the
  wrong org: ask the user to refresh it. With their OK, run the browser refresh yourself
  in the background, and the user logs in to the target org in the Edge window if asked.
  Use a separate profile and port for each org, so an org's existing login is reused:
  ```
  IDMC_DEBUG_PORT=<port> IDMC_PROFILE_DIR="$(cygpath -w "$TEMP")\\idmc-login-edge-<org>" powershell -NoProfile -ExecutionPolicy Bypass -File refresh-token-api-browser.ps1 -LoginUrl "https://dm-em.informaticacloud.com/identity-service/home"
  ```
  Or offer the password method, `cmd //c start "" refresh-token-api-native.cmd`.
  An expired JWT alone is fine; the script gets a new one while the IDMC session is alive.
- **MCP token** (`usermanagement` in `~/.claude.json`, used for asset 4) is INVALID: no
  refresh needed, use the REST user path. Only if the user asks to use the MCP anyway:
  open `cmd //c start "IDMC MCP OAuth refresh" refresh-token-mcp-oauth20.cmd`.
  The user enters the client_id/secret of the target org's OAuth client in that window,
  then runs `/mcp` → reconnect `usermanagement`.
- Even when the check passes (exit 0), the `mcp__usermanagement__*` tools must be available
  in this session. If they aren't, use the REST user path.

Never put a user-login JWT into `.claude.json` (see the `refresh-idmc-token` skill).
Re-run `check` after any refresh, and continue only on exit 0 (both VALID, `ORG: MATCH`)
or exit 5 (REST API token VALID, `ORG: REST ONLY`, REST user path).
`IDMC_ORG_ID=<id>` is optional: it pins the script to one org and rejects a REST API
token from any other org. You don't need it in normal use.

## Step 3: show the plan and ask for confirmation
Get the exact names and descriptions:
```
node idmc-segment.mjs plan "<E>"
```
Check what already exists:
- `node idmc-segment.mjs delete "<E>"` is a **dry run only**; never add `--yes` here.
  It lists the existing user group, asset group and policy, and also the user `Test-U-<E>`
  (looked up via REST), so on the REST user path this is the only check needed.
- MCP user path: `mcp__usermanagement__get_user_details` with `q: "userName==Test-U-<E>"` finds an existing user.

Then show the target org (name + ID, from the `ORG:` line) and a table of the 4 assets: name, description, and what is
enabled (user group role; asset group Published; policy Published + Enabled with
the 5 rules below; user with its fields and email). Mark anything that already
exists as **reused**, because create skips it. Say which path creates the user (MCP, or
REST and why). Mention the activation email to `<email>`.
Ask the user to confirm (AskUserQuestion: Create / Cancel). **Do not create anything
without an explicit yes.**

Policy rules, each with the condition `core.groups == <asset group id>`, hierarchy scope All:
1. Asset: create, delete, execute, manage_access, read, update
2. Attribute group `profile-stats-attribute-group`: create, delete, execute, read, update
3. Attribute group `data-attribute-group`: read
4. Attribute group `code-attribute-group`: read
5. Attribute group `unpublished-changes`: read, update

## Step 4: create
1. Assets 1–3 (MCP user path), or assets 1–4 (REST user path, add `--email`):
   ```
   node idmc-segment.mjs create "<E>"
   node idmc-segment.mjs create "<E>" --email="<email>"
   ```
   This takes about 1–2 minutes, since the policy publish and enable steps are async jobs.
   It prints a JSON summary; keep `userGroup.id` (and `user.id` on the REST path). Fail-safe: if it errors, report the
   error and stop; the run can be repeated safely, because existing pieces are reused
   (an existing user is added to the user group if needed).
   On the REST path, skip to 3.
2. MCP user path only. Asset 4, with `mcp__usermanagement__create_user`:
   `name: "Test-U-<E>"`, `firstName: "GovAdmin"`, `lastName: "<E>"`,
   `title: "Segregation Test Account"`, `phone: "+0123456789"`, `email: "<email>"`,
   `groups: ["<userGroup.id>"]`. This takes the group **ID**, not the name; leave out the password.
   Skip this step if the user already exists, and make sure it is in the group
   (`add_groups_to_user` takes group **names**).
   The API accepted the spaces in `lastName: "Dummy 2"` and user names without an `@`.
   If IDMC rejects a name, report the error and ask before changing it.
   If the call fails with an auth error (401 / `AUTH_HEADER_REJECTED`), switch to the REST
   path: re-run step 1 with `--email="<email>"` (assets 1–3 are reused).
3. Check the result. MCP: `get_user_group_details` with `q: "userGroupId==<id>"` should list
   `Test-U-<E>` under `users`. REST: `node idmc-segment.mjs delete "<E>" --only=user,userGroup`
   (dry run) should list the user and show the user group with 1 member.

## Step 5: summary
State the org (name + ID). Report a table with each asset's name, ID or reference (user group ID, asset group
`AGP-…` + internal ID, policy `MAC-…` + internal ID, user ID), its state (Published,
Enabled, user state Provisioned) and the Governance Administrator role. Remind the user about the
activation email.

## D. Delete a segregation entity
Deletes, **in this order**: user group policy → asset group → user → user group.
The policy goes first because it references the user group and the asset group. The
user goes before the user group because the script refuses to delete a group that
still has members.

### D1: inputs and tokens
- Ask for the entity name `<E>` if it wasn't given. No email is needed.
- Run step 2 (`node idmc-segment.mjs check`), with the same rules: refresh an invalid
  REST API token, ask for the org only on exit 4, and pick the user path (MCP, or REST on
  exit 5 / tools unavailable). Deletes happen in the org of the tokens.

### D2: show what will be deleted and ask for confirmation
- `node idmc-segment.mjs delete "<E>"` is a dry run. It lists the policy `Test-UGP-<E>`,
  the asset group `<E>`, the user `Test-U-<E>` and the user group `Test-UG-<E>`, with its members.
- MCP user path: `mcp__usermanagement__get_user_details` with `q: "userName==Test-U-<E>"` finds the user and its ID.

State the org (name + ID), then show a table in delete order (the 4 items with their IDs or references). Mark missing
items as "not found, skipped". If the user group has members **other than**
`Test-U-<E>`, list them and stop: the script won't delete that group, and those users
aren't part of this test setup. Warn that deleting is **permanent**, then ask for an
explicit confirmation (AskUserQuestion: Delete / Cancel). If nothing exists, say so and stop.

### D3: delete, one step at a time
Stop at the first failure and report what was already deleted.

**REST user path:** one command deletes all 4 in order (policy → asset group → user → user group):
```
node idmc-segment.mjs delete "<E>" --yes
```

**MCP user path:**
1. **Policy and asset group** (REST):
   ```
   node idmc-segment.mjs delete "<E>" --yes --only=policy,assetGroup
   ```
   The policy DELETE is an async job; the script waits for COMPLETED, then deletes the asset group.
2. **User** (MCP): `mcp__usermanagement__delete_user` with the user ID from D2.
   On an auth error, use `node idmc-segment.mjs delete "<E>" --yes --only=user` instead.
3. **User group** (REST):
   ```
   node idmc-segment.mjs delete "<E>" --yes --only=userGroup
   ```

### D4: check and summarize
- `node idmc-segment.mjs delete "<E>"` should report `Nothing found for segment "<E>"`.
  This covers the user too.
- MCP user path, optionally: `get_user_details` with `q: "userName==Test-U-<E>"` should return `[]`.

Report a table of the 4 items: name, ID or reference, and Deleted / not found.
