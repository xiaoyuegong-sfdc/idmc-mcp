// idmc-segment.mjs
// Creates (or tears down) one segregation test "segment" in IDMC / CDGC:
//   1. user group         "Test-UG-<segment>"   with the Governance Administrator role
//   2. asset group        "<segment>"           at the root level, created, then published
//   3. user group policy  "Test-UGP-<segment>"  all rules scoped to that user group + asset group, created, published, enabled
//   4. user               "Test-U-<segment>"    in that user group; only with --email=<address>
// The test user is normally created with the usermanagement MCP server (see the
// idmc-segregation-test skill); --email is the REST fallback when the MCP token is missing or
// invalid. "delete" refuses while the user group has members other than the test user.
//
// Usage:
//   node idmc-segment.mjs check                     # validate the REST API token and the MCP token
//   node idmc-segment.mjs plan   "CMC"              # print the names that create would use (JSON)
//   node idmc-segment.mjs create "CMC"                       # parts 1-3
//   node idmc-segment.mjs create "CMC" --email=a@b.com       # parts 1-4 (user via REST)
//   node idmc-segment.mjs delete "CMC"              # dry run: lists what would be deleted
//   node idmc-segment.mjs delete "CMC"     --yes    # deletes policy -> asset group -> user -> user group
//   node idmc-segment.mjs delete "CMC"     --yes --only=policy,assetGroup   # just those parts
//                                                   # (parts: policy, assetGroup, user, userGroup)
//
// Auth: reads the REST API token file written by refresh-token-api-native.ps1 / refresh-token-api-browser.ps1
// (%USERPROFILE%\.idmc\api-token.json; NOT the MCP token in .claude.json). Its sessionId is used
// as INFA-SESSION-ID for the v3 admin API and its JWT for the CDGC APIs; an expired JWT is
// re-minted from the sessionId while the IDMC session is still alive.
//
// Org: taken from the REST API token (its orgId), so the script works in whichever org you
// logged in to. "check" also reads the org of the MCP token (org_id claim) and exits 4 if the
// two differ, or 5 if the MCP token is missing or invalid (then the user is created via REST). Set IDMC_ORG_ID to pin an org: the script then refuses a REST
// API token for any other org.
//
// "create" is idempotent: pieces that already exist (matched by exact name) are reused, and an
// asset group / policy that isn't published yet is published.
//
// Env overrides: IDMC_API_TOKEN_FILE, IDMC_ORG_ID, IDMC_POD_URL, CLAUDE_JSON, IDMC_MCP_PROJECT.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Claude Code keys local-scope MCP servers in .claude.json by the project folder, written
// with forward slashes ("C:/work/idmc-mcp"). Default: the folder that holds this script.
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, "/");

// --- configuration -------------------------------------------------------------
const CFG = {
  tokenFile:  process.env.IDMC_API_TOKEN_FILE || join(process.env.USERPROFILE || ".", ".idmc", "api-token.json"),
  orgId:      process.env.IDMC_ORG_ID      || null,                // optional pin; default: org of the REST API token
  podUrl:     process.env.IDMC_POD_URL     || "https://emw1.dm-em.informaticacloud.com",
  identity:   "https://dm-em.informaticacloud.com/identity-service",
  cdgc:       "https://cdgc-api.dm-em.informaticacloud.com",
  claudeJson: process.env.CLAUDE_JSON      || join(process.env.USERPROFILE || ".", ".claude.json"),
  mcpProject: process.env.IDMC_MCP_PROJECT || SCRIPT_DIR,
};

const ROLES = ["Governance Administrator"];

const names = seg => ({
  userGroup:   { name: `Test-UG-${seg}`,  description: `Segregation Test User Group for ${seg}` },
  assetGroup:  { name: seg,               description: `Segregation Test Asset Group for ${seg}` },
  policy:      { name: `Test-UGP-${seg}`, description: `Segregation Test User Group Policy for ${seg}` },
  user:        { name: `Test-U-${seg}`, firstName: "GovAdmin", lastName: seg, title: "Segregation Test Account", phone: "+0123456789" },
});

// [ruleType, permissions, associatedType]
const POLICY_RULES = [
  ["Asset",           ["create", "delete", "execute", "manage_access", "read", "update"]],
  ["Attribute_Group", ["create", "delete", "execute", "read", "update"], "profile-stats-attribute-group"],
  ["Attribute_Group", ["read"],                                          "data-attribute-group"],
  ["Attribute_Group", ["read"],                                          "code-attribute-group"],
  ["Attribute_Group", ["read", "update"],                                "unpublished-changes"],
];

const log = (...a) => console.log(">>", ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

// --- REST API token file ---------------------------------------------------------
const REFRESH_HINT = "run refresh-token-api-browser.ps1 (or refresh-token-api-native.ps1) to log in to the target org";
const claimsOf = jwt => JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString());

// Returns { sid, jwt, user, orgId, orgName } from the token file; the org is the token's own.
async function getSession() {
  let rec;
  try { rec = JSON.parse(readFileSync(CFG.tokenFile, "utf8")); }
  catch { throw new Error(`No REST API token file at ${CFG.tokenFile}; ${REFRESH_HINT}`); }
  if (!rec.orgId) throw new Error(`REST API token in ${CFG.tokenFile} has no org; ${REFRESH_HINT}`);
  if (CFG.orgId && rec.orgId !== CFG.orgId)
    throw new Error(`REST API token is for org "${rec.orgName}" (${rec.orgId}), but IDMC_ORG_ID is ${CFG.orgId}; ${REFRESH_HINT}`);

  let jwt = rec.jwt;
  if (claimsOf(jwt).exp * 1000 < Date.now() + 60_000) {
    const r = await fetch(`${CFG.identity}/api/v1/jwt/Token?client_id=idmc_api&nonce=1234`, { headers: { "IDS-SESSION-ID": rec.sessionId } });
    if (!r.ok) throw new Error(`REST API token expired and the IDMC session is gone (HTTP ${r.status}); ${REFRESH_HINT}`);
    jwt = (await r.json()).jwt_token;
    const c = claimsOf(jwt);
    writeFileSync(CFG.tokenFile, JSON.stringify({ ...rec, jwt,
      issuedAt: new Date(c.iat * 1000).toISOString(), expiresAt: new Date(c.exp * 1000).toISOString() }, null, 2));
    log(`Re-minted the REST API JWT from the saved session (expires ${new Date(c.exp * 1000).toISOString()})`);
  }
  return { sid: rec.sessionId, jwt, user: rec.user, orgId: rec.orgId, orgName: rec.orgName };
}

// --- HTTP helpers ---------------------------------------------------------------
async function call(method, url, headers, body) {
  const r = await fetch(url, { method, headers, body: body && JSON.stringify(body) });
  const text = await r.text();
  let data; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!r.ok) throw new Error(`${method} ${url} -> HTTP ${r.status}: ${text.slice(0, 500)}`);
  return data;
}

function clients(s) {
  const iamH = { "INFA-SESSION-ID": s.sid, Accept: "application/json", "Content-Type": "application/json" };
  const cdgcH = { Authorization: `Bearer ${s.jwt}`, "X-INFA-ORG-ID": s.orgId, "X-INFA-PRODUCT-ID": "CDGC",
                  Accept: "application/json", "Content-Type": "application/json" };
  const v3 = `${CFG.podUrl}/saas/public/core/v3`;
  const policies = `${CFG.cdgc}/ccgf-metadata-admin/api/v1/administration/authorization/policies`;

  // Content-service publish; every item must come back with a 2xx statusCode.
  const publish = async item => {
    const res = await call("POST", `${CFG.cdgc}/ccgf-contentv2/api/v1/publish`, cdgcH, { items: [item] });
    const it = res.items?.[0];
    if (!it || it.statusCode >= 300) throw new Error(`publish ${item.operation} failed: ${JSON.stringify(res).slice(0, 500)}`);
    return it;
  };

  const search = async (type, extraFilter = []) => {
    const res = await call("POST", `${CFG.cdgc}/ccgf-searchv2/api/v1/search`, { ...cdgcH, "X-INFA-SEARCH-LANGUAGE": "elasticsearch" }, {
      from: 0, size: 10000,
      query: { bool: { must_not: [{ terms: { "core.state": ["Deleted"] } }],
                       filter: [{ terms: { elementType: ["OBJECT"] } }, { terms: { type: [type] } }, ...extraFilter] } },
    });
    return res.hits.hits.map(h => h.sourceAsMap);
  };
  // Search can't match core.name, so list by type and match the name exactly here.
  const findByName = async (type, name, extraFilter) => (await search(type, extraFilter)).filter(o => o["core.name"] === name);

  const waitJob = async (jobId, timeoutSec = 180) => {
    const deadline = Date.now() + timeoutSec * 1000;
    for (;;) {
      const j = await call("GET", `${CFG.cdgc}/ccgf-orchestration-management-api-server/api/v1/jobs/${jobId}`, cdgcH);
      if (/COMPLETED|FAILED|CANCEL/.test(j.status)) return j.status;
      if (Date.now() > deadline) return `still ${j.status} after ${timeoutSec}s`;
      await sleep(3000);
    }
  };

  return {
    // v3 admin API: user groups + roles
    findUserGroup: async name => (await call("GET", `${v3}/userGroups?q=${encodeURIComponent(`userGroupName=="${name}"`)}`, iamH))[0],
    createUserGroup: (name, description, roles) => call("POST", `${v3}/userGroups`, iamH, { name, description, roles }),
    deleteUserGroup: id => call("DELETE", `${v3}/userGroups/${id}`, iamH),

    // v3 admin API: users (REST fallback for the usermanagement MCP)
    findUser: async name => (await call("GET", `${v3}/users?q=${encodeURIComponent(`userName=="${name}"`)}`, iamH))[0],
    // No password: IDMC sends the activation email.
    createUser: (u, email, groupId) => call("POST", `${v3}/users`, iamH, {
      name: u.name, firstName: u.firstName, lastName: u.lastName, title: u.title, phone: u.phone, email, groups: [groupId] }),
    addGroupsToUser: (id, groupIds) => call("PUT", `${v3}/users/${id}/addGroups`, iamH, { groups: groupIds }),
    deleteUser: id => call("DELETE", `${v3}/users/${id}`, iamH),
    roleId: async name => {
      const r = (await call("GET", `${v3}/roles?q=${encodeURIComponent(`roleName=="${name}"`)}`, iamH))[0];
      if (!r) throw new Error(`Role not found: ${name}`);
      return r.id;
    },

    // CDGC asset groups
    findAssetGroup: name => findByName("core.AssetGroup", name),
    createAssetGroup: (name, description) => publish({
      elementType: "OBJECT", operation: "INSERT", type: "core.AssetGroup", identityType: "PROVISIONAL", identity: "AG-new",
      attributes: { "core.name": name, "core.description": description, "core.assetLifecycle": "Draft" } }),
    publishAssetGroup: id => publish({
      elementType: "OBJECT", operation: "UPDATE", type: "core.AssetGroup", identityType: "INTERNAL", identity: id,
      attributes: { "core.assetLifecycle": "Published" }, attributeUpdateOperationTypeMap: { "core.assetLifecycle": "OVERWRITE" } }),
    deleteAssetGroup: id => publish({
      elementType: "OBJECT", operation: "DELETE", type: "core.AssetGroup", identityType: "INTERNAL", identity: id, attributes: {} }),

    // CDGC user group policies
    findPolicy: name => findByName("core.accesscontrol.IAccessControlPolicy", name, [{ terms: { "core.category": ["Custom"] } }]),
    createPolicyDraft: async (name, description, userGroupId, assetGroupId) => {
      const condition = JSON.stringify({ equals: { attribute: "core.groups", value: assetGroupId } });
      const res = await call("POST", `${policies}/drafts/bulk-actions`, cdgcH, { items: [{
        "core.name": name, "core.description": description,
        "core.accesscontrol.userSetType": "User_Group", "core.accesscontrol.userSet": userGroupId,
        "core.accesscontrol.policyRules": POLICY_RULES.map(([ruleType, permissions, associatedType]) => ({
          "core.accesscontrol.ruleType": ruleType, "core.accesscontrol.assetTypes": ["core.IClass"],
          "core.accesscontrol.hierarchyScope": "All", "core.accesscontrol.permissions": permissions,
          "core.accesscontrol.condition": condition,
          ...(associatedType && { "core.accesscontrol.associatedType": associatedType }) })),
        action: "UPSERT" }] });
      const it = res.items?.[0];
      if (!it?.["core.externalId"] || it.statusCode >= 300) throw new Error(`policy draft failed: ${JSON.stringify(res).slice(0, 500)}`);
      return it;
    },
    // The search index lags the publish job by a few seconds.
    policyStatus: async externalId => {
      let status;
      for (let i = 0; i < 10; i++) {
        status = (await search("core.accesscontrol.IAccessControlPolicy", [{ terms: { "core.externalId": [externalId] } }]))[0]?.["core.status"];
        if (status === "Enabled") break;
        await sleep(2000);
      }
      return status;
    },
    policyAction: async (action, externalId) => {
      const res = await call("POST", `${policies}/bulk-actions`, cdgcH, { items: [{ action, "core.externalId": externalId }] });
      if (!res.jobId) throw new Error(`policy ${action} not accepted: ${JSON.stringify(res).slice(0, 500)}`);
      return waitJob(res.jobId);
    },
  };
}

// --- commands -------------------------------------------------------------------
async function create(api, seg, email) {
  const n = names(seg);

  // 1. user group
  let ug = await api.findUserGroup(n.userGroup.name);
  if (ug) log(`User group "${ug.userGroupName}" already exists (${ug.id}), reusing`);
  else {
    const roleIds = await Promise.all(ROLES.map(api.roleId));
    ug = await api.createUserGroup(n.userGroup.name, n.userGroup.description, roleIds);
    log(`Created user group "${ug.userGroupName}" (${ug.id}) with roles: ${ug.roles.map(r => r.roleName).join(", ")}`);
  }

  // 2. asset group
  let [ag] = await api.findAssetGroup(n.assetGroup.name);
  let agId = ag?.["core.identity"], agRef = ag?.["core.externalId"];
  if (ag) log(`Asset group "${n.assetGroup.name}" already exists (${agRef}, ${ag["core.assetLifecycle"]}), reusing`);
  else {
    const it = await api.createAssetGroup(n.assetGroup.name, n.assetGroup.description);
    agId = it.internalIdentity; agRef = it.identity;
    log(`Created asset group "${n.assetGroup.name}" (${agRef}, ${agId})`);
  }
  if (ag?.["core.assetLifecycle"] !== "Published") {
    await api.publishAssetGroup(agId);
    log(`Published asset group ${agRef}`);
  }

  // 3. user group policy
  let [pol] = await api.findPolicy(n.policy.name);
  let polRef = pol?.["core.externalId"], polId = pol?.["core.identity"];
  if (pol) log(`Policy "${n.policy.name}" already exists (${polRef}, ${pol["core.status"]}), reusing`);
  else {
    const it = await api.createPolicyDraft(n.policy.name, n.policy.description, ug.id, agId);
    polRef = it["core.externalId"]; polId = it["core.identity"];
    log(`Created policy draft "${n.policy.name}" (${polRef}) for user group ${ug.id} + asset group ${agRef}`);
  }
  // PUBLISH only publishes the draft (status stays Disabled); ENABLE turns it on.
  for (const [action, done] of [["PUBLISH", pol?.["core.assetLifecycle"] === "Published"], ["ENABLE", pol?.["core.status"] === "Enabled"]]) {
    if (done) continue;
    const status = await api.policyAction(action, polRef);
    log(`${action} job for policy ${polRef}: ${status}`);
    if (status !== "COMPLETED") throw new Error(`Policy ${polRef} ${action} did not complete (${status})`);
  }
  const status = await api.policyStatus(polRef);
  if (status !== "Enabled") throw new Error(`Policy ${polRef} status is ${status}, expected Enabled`);
  log(`Policy ${polRef} is Enabled`);

  // 4. user, only with --email (otherwise the skill creates it with the usermanagement MCP)
  let user;
  if (email) {
    user = await api.findUser(n.user.name);
    if (user) {
      log(`User "${user.userName}" already exists (${user.id}), reusing`);
      if (!user.groups?.some(g => g.id === ug.id)) {
        await api.addGroupsToUser(user.id, [ug.id]);
        log(`Added user ${user.id} to user group ${ug.id}`);
      }
    } else {
      user = await api.createUser(n.user, email, ug.id);
      log(`Created user "${user.userName}" (${user.id}) in user group ${ug.id}; activation email goes to ${email}`);
    }
  }

  return { segment: seg,
    userGroup: { name: n.userGroup.name, id: ug.id },
    assetGroup: { name: n.assetGroup.name, ref: agRef, id: agId },
    policy: { name: n.policy.name, ref: polRef, id: polId },
    ...(user && { user: { name: user.userName, id: user.id, email: user.email, state: user.state } }) };
}

// only: subset of PARTS to delete (default all), so the test user can instead be deleted
// via the usermanagement MCP between the asset group and the user group.
const PARTS = ["policy", "assetGroup", "user", "userGroup"];
async function remove(api, seg, confirmed, only = PARTS) {
  const n = names(seg);
  const policies = only.includes("policy") ? await api.findPolicy(n.policy.name) : [];
  const assetGroups = only.includes("assetGroup") ? await api.findAssetGroup(n.assetGroup.name) : [];
  const user = only.includes("user") ? await api.findUser(n.user.name) : undefined;
  const ug = only.includes("userGroup") ? await api.findUserGroup(n.userGroup.name) : undefined;

  const plan = [
    ...policies.map(p => `policy "${n.policy.name}" (${p["core.externalId"]})`),
    ...assetGroups.map(a => `asset group "${n.assetGroup.name}" (${a["core.externalId"]})`),
    ...(user ? [`user "${user.userName}" (${user.id})`] : []),
    ...(ug ? [`user group "${ug.userGroupName}" (${ug.id}, ${ug.users.length} members)`] : []),
  ];
  if (!plan.length) { log(`Nothing found for segment "${seg}"`); return; }
  log(`Segment "${seg}" contains:\n   - ${plan.join("\n   - ")}`);
  if (!confirmed) { log("Dry run; re-run with --yes to delete"); return; }
  // The test user is fine when it is deleted in this run (before the user group).
  const others = ug?.users.filter(u => u.userName !== user?.userName) || [];
  if (others.length)
    throw new Error(`User group "${ug.userGroupName}" still has members (${others.map(u => u.userName).join(", ")}); delete those users first`);

  // Policy first: it references the user group and the asset group.
  for (const p of policies) {
    const status = await api.policyAction("DELETE", p["core.externalId"]);
    if (status !== "COMPLETED") throw new Error(`Policy ${p["core.externalId"]} DELETE did not complete (${status})`);
    log(`Deleted policy ${p["core.externalId"]}`);
  }
  for (const a of assetGroups) { await api.deleteAssetGroup(a["core.identity"]); log(`Deleted asset group ${a["core.externalId"]}`); }
  if (user) { await api.deleteUser(user.id); log(`Deleted user ${user.id}`); }
  if (ug) { await api.deleteUserGroup(ug.id); log(`Deleted user group ${ug.id}`); }
}

// Validates both tokens with a live call: the REST API token file (v3 + CDGC) and the
// usermanagement MCP token in .claude.json, then compares their orgs.
// Exit codes: 0 both valid + same org, 3 REST API token not usable, 4 orgs differ or one is empty,
// 5 REST API token valid but MCP token missing/invalid (the user then goes via REST).
async function check() {
  let restOk = true, mcpOk = true, restOrg = null, restOrgName = null, mcpOrg = null;
  try {
    const s = await getSession();
    restOrg = s.orgId; restOrgName = s.orgName;
    const api = clients(s);
    await api.roleId(ROLES[0]);                       // v3 admin API with the session id
    await api.findAssetGroup("__token_check__");      // CDGC search with the JWT
    log(`REST API token: VALID - ${s.user}, org "${s.orgName}" (${s.orgId}), JWT expires ${new Date(claimsOf(s.jwt).exp * 1000).toISOString()}`);
  } catch (e) { restOk = false; log(`REST API token: INVALID - ${e.message}`); }

  try {
    const projects = JSON.parse(readFileSync(CFG.claudeJson, "utf8")).projects || {};
    const key = Object.keys(projects).find(k => k.toLowerCase() === CFG.mcpProject.toLowerCase());   // drive-letter case varies
    const srv = projects[key]?.mcpServers?.usermanagement;
    if (!srv?.headers?.Authorization)
      throw new Error(`no usermanagement server with an Authorization header for project "${CFG.mcpProject}" in ${CFG.claudeJson} (set IDMC_MCP_PROJECT if Claude Code runs in another folder)`);
    const c = claimsOf(srv.headers.Authorization.replace(/^Bearer\s+/, ""));
    mcpOrg = c.org_id || null;
    const exp = new Date(c.exp * 1000).toISOString();
    if (c.exp * 1000 < Date.now()) throw new Error(`token expired at ${exp}; run refresh-token-mcp-oauth20.cmd, then /mcp -> reconnect`);
    const r = await fetch(srv.url, { method: "POST",
      headers: { ...srv.headers, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "idmc-segment-check", version: "1" } } }) });
    if (!r.ok) throw new Error(`usermanagement rejected the token (HTTP ${r.status}); run refresh-token-mcp-oauth20.cmd, then /mcp -> reconnect`);
    log(`MCP token (usermanagement): VALID - client ${c.client_name || c.client_id}, org ${mcpOrg || "(none)"}, expires ${exp}`);
  } catch (e) { mcpOk = false; log(`MCP token (usermanagement): INVALID - ${e.message}`); }

  // Printed even when a token is invalid, so a refresh can target the right org.
  const same = restOrg && mcpOrg && restOrg === mcpOrg;
  if (restOk && !mcpOk) log(`ORG: REST ONLY - "${restOrgName}" (${restOrg}); manage the user via REST (create --email, delete)`);
  else log(same ? `ORG: MATCH - "${restOrgName}" (${restOrg})`
                : `ORG: MISMATCH - REST API token org ${restOrg || "(none)"}${restOrgName ? ` "${restOrgName}"` : ""}, MCP token org ${mcpOrg || "(none)"}`);
  if (!restOk) process.exit(3);
  if (!mcpOk) process.exit(5);
  if (!same) process.exit(4);
}

// --- CLI ------------------------------------------------------------------------
const [cmd, seg] = process.argv.slice(2);
if (!(cmd === "check" || (["plan", "create", "delete"].includes(cmd) && seg))) {
  console.log('Usage: node idmc-segment.mjs check\n       node idmc-segment.mjs plan "<segment>"\n       node idmc-segment.mjs create "<segment>" [--email=<address>]\n       node idmc-segment.mjs delete "<segment>" [--yes] [--only=policy,assetGroup,user,userGroup]');
  process.exit(2);
}
if (cmd === "check") { await check(); process.exit(0); }
if (cmd === "plan") { console.log(JSON.stringify(names(seg), null, 2)); process.exit(0); }
const email = process.argv.find(a => a.startsWith("--email="))?.slice(8);
if (email !== undefined && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
  console.error(`ERROR: not a valid email address: "${email}"`);
  process.exit(2);
}
try {
  const session = await getSession();
  log(`Signed in as ${session.user}, org "${session.orgName}" (${session.orgId})`);
  const api = clients(session);
  if (cmd === "create") console.log(JSON.stringify(await create(api, seg, email), null, 2));
  else {
    const only = process.argv.find(a => a.startsWith("--only="))?.slice(7).split(",") || PARTS;
    const bad = only.filter(p => !PARTS.includes(p));
    if (bad.length) throw new Error(`Unknown --only part(s): ${bad.join(", ")} (use ${PARTS.join(",")})`);
    await remove(api, seg, process.argv.includes("--yes"), only);
  }
} catch (e) {
  console.error("ERROR:", e.message);
  process.exit(1);
}
