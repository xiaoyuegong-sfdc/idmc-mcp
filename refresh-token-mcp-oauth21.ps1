# refresh-token-mcp-oauth21.ps1
# Mints an IDMC MCP access token via the OAuth 2.1 authorization-code grant with
# PKCE (S256), as advertised by the MCP server's protected-resource metadata:
#   GET {McpResource origin}/.well-known/oauth-protected-resource{path}
#   GET {LoginUrl}/.well-known/oauth-authorization-server/authz-service
#
# Flow:
#   1. generate code_verifier, code_challenge = BASE64URL(SHA256(verifier)), state
#   2. listen on redirect_uri (loopback) and open the browser at
#      {LoginUrl}/authz-service/oauth2/authorize?...&resource=<McpResource>
#   3. user logs in; the callback receives ?code=...&state=...
#   4. POST {LoginUrl}/authz-service/oauth2/token (form-encoded, public client):
#        grant_type=authorization_code, code, redirect_uri, client_id,
#        code_verifier, resource
#
# The token response is saved to %USERPROFILE%\.idmc\mcp-oauth21-token.json
# (override IDMC_OAUTH21_TOKEN_FILE), one record per resource URL, and written into
# the Authorization header of every MCP server in %USERPROFILE%\.claude.json whose
# url is that resource (plus any server named with -ServerName); afterwards
# reconnect it via /mcp.
# -ApplySaved skips the login and re-applies every saved, unexpired token (only
# the one for -Resource <name or URL> if given).
# -Refresh skips the login too: for every saved record (or -Resource) it POSTs
#   grant_type=refresh_token, refresh_token, client_id, resource
# to /authz-service/oauth2/token, saves the new tokens (a rotated refresh token
# replaces the old one) and applies the new access token. An invalid_grant answer
# means the refresh token is no longer valid: log in again without -Refresh.
#
# Prompts (skipped when the matching parameter is passed):
#   baseUrl       - IDMC login URL, default https://dm-em.informaticacloud.com
#                   (or IDMC_LOGIN_URL)                         (-BaseUrl)
#   client_id     - required, no default                       (-ClientId)
#   redirect_uri  - default http://localhost:9876/callback     (-RedirectUri)
#   resource      - MCP server name, required, no default; it is appended to
#                   https://mcp.<baseUrl host>/mcp-servers/public/
#                   (e.g. dqverifyaddress)                      (-Resource)
#                   The IDMC MCP servers installed in .claude.json under that
#                   prefix are listed as proposals; enter a number or a name.
# No secret is prompted; the browser login is the only other user step.

param(
    [string]$BaseUrl,
    [string]$ClientId,
    [string]$RedirectUri,
    [string]$Resource,
    [string]$Scope       = 'mcp:tools:read mcp:tools:write mcp:tools:execute',
    [int]$TimeoutSec     = 300,
    [string[]]$ServerName = @(),
    [switch]$ApplySaved,
    [switch]$Refresh,
    [switch]$ShowDetails
)

$ErrorActionPreference = 'Stop'

$ClaudeJson  = if ($env:CLAUDE_JSON)    { $env:CLAUDE_JSON }    else { Join-Path $env:USERPROFILE '.claude.json' }
$TokenFile   = if ($env:IDMC_OAUTH21_TOKEN_FILE) { $env:IDMC_OAUTH21_TOKEN_FILE } else { Join-Path $env:USERPROFILE '.idmc\mcp-oauth21-token.json' }
$DefaultBaseUrl     = if ($env:IDMC_LOGIN_URL) { $env:IDMC_LOGIN_URL } else { 'https://dm-em.informaticacloud.com' }
$DefaultRedirectUri = 'http://localhost:9876/callback'

# MCP server entries (user + project scopes) of ~/.claude.json, as name/value pairs.
function Get-McpServerEntries($cfg) {
    $scopes = @($cfg.mcpServers)
    if ($cfg.projects) { $scopes += $cfg.projects.PSObject.Properties.Value | ForEach-Object { $_.mcpServers } }
    foreach ($servers in $scopes) {
        if ($servers) { $servers.PSObject.Properties }
    }
}

# Writes "Bearer <token>" into each server whose url is $resourceUrl or whose name is in -ServerName.
function Set-McpServerToken([string]$resourceUrl, [string]$token) {
    $json = Get-Content -Raw -Encoding UTF8 $ClaudeJson | ConvertFrom-Json
    $names = @()
    foreach ($srv in Get-McpServerEntries $json) {
        if ("$($srv.Value.url)".TrimEnd('/') -ne $resourceUrl -and -not ($ServerName -contains $srv.Name)) { continue }
        if (-not $srv.Value.PSObject.Properties['headers']) {
            $srv.Value | Add-Member -NotePropertyName headers -NotePropertyValue ([PSCustomObject]@{})
        }
        $h = $srv.Value.headers
        if ($h.PSObject.Properties['Authorization']) { $h.Authorization = "Bearer $token" }
        else { $h | Add-Member -NotePropertyName Authorization -NotePropertyValue "Bearer $token" }
        $names += $srv.Name
    }
    if ($names.Count -eq 0) {
        Write-Host ">> No MCP server in $ClaudeJson uses $resourceUrl - token not applied."
        return
    }
    $backup = "$ClaudeJson.bak"
    if (-not (Test-Path $backup)) { Copy-Item $ClaudeJson $backup }
    [IO.File]::WriteAllText($ClaudeJson, ($json | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    Write-Host ">> Applied token to $($names -join ', ') in $ClaudeJson. Now reconnect: /mcp -> $($names -join ', ')"
}

function Show-Params([string]$title, $map) {
    if (-not $ShowDetails) { return }
    Write-Host ""
    Write-Host "== $title"
    foreach ($k in $map.Keys) { Write-Host ("   {0,-22} = {1}" -f $k, $map[$k]) }
}
function Hide-Token([string]$t) {
    if (-not $t) { return '' }
    if ($t.Length -le 24) { return $t }
    "$($t.Substring(0, 12))...$($t.Substring($t.Length - 8)) ($($t.Length) chars)"
}

function Show-TokenResponse($tokenResp) {
    if (-not $ShowDetails) { return }
    $resp = [ordered]@{}
    foreach ($prop in $tokenResp.PSObject.Properties) {
        $resp[$prop.Name] = if ($prop.Name -match 'token$' -and $prop.Name -ne 'token_type') { Hide-Token "$($prop.Value)" } else { $prop.Value }
    }
    Show-Params 'Token response (HTTP 200)' $resp
    $seg = $tokenResp.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $seg += '=' * ((4 - $seg.Length % 4) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg)) | ConvertFrom-Json
    $c = [ordered]@{}
    foreach ($prop in $claims.PSObject.Properties) {
        $c[$prop.Name] = if ($prop.Name -in 'exp','iat','nbf') { "$($prop.Value)  ($([DateTimeOffset]::FromUnixTimeSeconds([long]$prop.Value).LocalDateTime))" } else { ($prop.Value | ConvertTo-Json -Compress) }
    }
    Show-Params 'access_token JWT claims' $c
    Write-Host ""
}

# Saved token records keyed by resource URL. A file from before per-resource
# storage (one flat record) is read as a single entry.
function Read-SavedTokens {
    $map = [ordered]@{}
    if (-not (Test-Path $TokenFile)) { return $map }
    $saved = Get-Content -Raw -Encoding UTF8 $TokenFile | ConvertFrom-Json
    if ($saved.PSObject.Properties['access_token']) { $map[$saved.resource] = $saved; return $map }
    foreach ($prop in $saved.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    $map
}

# Builds the record for a token response and stores it under $resourceUrl.
# A refresh response without a refresh_token keeps the previous one.
function Save-TokenRecord([string]$resourceUrl, [string]$source, [string]$loginUrl, [string]$clientId, $tokenResp, [string]$previousRefresh) {
    $issued = Get-Date
    $record = [ordered]@{
        source        = $source
        loginUrl      = $loginUrl
        clientId      = $clientId
        resource      = $resourceUrl
        scope         = $tokenResp.scope
        tokenType     = $tokenResp.token_type
        issuedAt      = $issued.ToString('o')
        expiresAt     = if ($tokenResp.expires_in) { $issued.AddSeconds([int]$tokenResp.expires_in).ToString('o') } else { $null }
        access_token  = $tokenResp.access_token
        refresh_token = if ($tokenResp.refresh_token) { $tokenResp.refresh_token } else { $previousRefresh }
    }
    $saved = Read-SavedTokens
    $saved[$resourceUrl] = $record
    New-Item -ItemType Directory -Force -Path (Split-Path $TokenFile) | Out-Null
    [IO.File]::WriteAllText($TokenFile, ($saved | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Host ">> Saved token response for $resourceUrl to $TokenFile (expires $($record.expiresAt))"
}

# Saved resource URLs to act on: all, or the one matching -Resource (name or URL).
function Select-SavedResources($saved) {
    $keys = @($saved.Keys)
    if ($Resource) {
        $r = $Resource.Trim().TrimEnd('/')
        $keys = @($keys | Where-Object { $_ -eq $r -or $_.EndsWith("/$r") })
        if ($keys.Count -eq 0) { throw "No saved token for resource '$Resource' in $TokenFile" }
    }
    if ($keys.Count -eq 0) { throw "No saved tokens in $TokenFile" }
    $keys
}

if ($Refresh) {
    $saved  = Read-SavedTokens
    $failed = 0
    foreach ($k in Select-SavedResources $saved) {
        $rec = $saved[$k]
        if (-not $rec.refresh_token) {
            Write-Host ">> Skipping $k - no refresh_token saved; run the script again without -Refresh"
            continue
        }
        $body = [ordered]@{
            grant_type    = 'refresh_token'
            refresh_token = $rec.refresh_token
            client_id     = $rec.clientId
            resource      = $k
        }
        Show-Params "POST $($rec.loginUrl)/authz-service/oauth2/token  (Content-Type: application/x-www-form-urlencoded)" `
            ([ordered]@{ grant_type = 'refresh_token'; refresh_token = (Hide-Token $rec.refresh_token); client_id = $rec.clientId; resource = $k })
        try {
            $tokenResp = Invoke-RestMethod -Method Post -Uri "$($rec.loginUrl)/authz-service/oauth2/token" `
                -ContentType 'application/x-www-form-urlencoded' -Body $body
        } catch {
            $failed++
            $detail = "$($_.ErrorDetails.Message)"
            Write-Host ">> Refresh failed for ${k}: $($_.Exception.Message) $detail"
            if ($detail -match 'invalid_grant') {
                Write-Host "   The refresh token expired or was revoked - log in again (run the script without -Refresh)."
            }
            continue
        }
        if (-not $tokenResp.access_token) {
            $failed++
            Write-Host ">> Refresh for $k returned no access_token: $($tokenResp | ConvertTo-Json -Compress)"
            continue
        }
        $state = if (-not $tokenResp.refresh_token) { 'not returned, keeping the saved one' }
                 elseif ($tokenResp.refresh_token -ne $rec.refresh_token) { 'rotated' }
                 else { 'returned unchanged' }
        Write-Host ">> Refreshed $k (refresh token $state)"
        Show-TokenResponse $tokenResp
        Save-TokenRecord $k $rec.source $rec.loginUrl $rec.clientId $tokenResp $rec.refresh_token
        Set-McpServerToken $k $tokenResp.access_token
    }
    if ($failed) { exit 1 }
    return
}

if ($ApplySaved) {
    $saved = Read-SavedTokens
    foreach ($k in Select-SavedResources $saved) {
        $rec = $saved[$k]
        if ($rec.expiresAt -and [DateTime]$rec.expiresAt -le (Get-Date)) {
            Write-Host ">> Skipping $k - expired at $($rec.expiresAt); run the script again without -ApplySaved"
            continue
        }
        Write-Host ">> Saved token: $k (expires $($rec.expiresAt))"
        Set-McpServerToken $k $rec.access_token
    }
    return
}

# --- prompted parameters ---------------------------------------------------
if (-not $BaseUrl) { $BaseUrl = Read-Host "baseUrl [$DefaultBaseUrl]" }
$BaseUrl = $BaseUrl.Trim().TrimEnd('/')
if (-not $BaseUrl) { $BaseUrl = $DefaultBaseUrl.TrimEnd('/') }
$base = [Uri]$BaseUrl
if ($base.Scheme -ne 'https') { throw "baseUrl must be an https URL, got: $BaseUrl" }
$LoginUrl       = "https://$($base.Authority)"
$ResourcePrefix = "https://mcp.$($base.Authority)/mcp-servers/public/"

if (-not $ClientId) { $ClientId = Read-Host 'client_id' }
$ClientId = $ClientId.Trim()
if (-not $ClientId) { throw 'client_id is required' }

if (-not $RedirectUri) { $RedirectUri = Read-Host "redirect_uri [$DefaultRedirectUri]" }
$RedirectUri = $RedirectUri.Trim()
if (-not $RedirectUri) { $RedirectUri = $DefaultRedirectUri }
$redirect = [Uri]$RedirectUri
if ($redirect.Scheme -ne 'http' -or -not $redirect.IsLoopback) {
    throw "redirect_uri must be an http loopback URL (localhost / 127.0.0.1), got: $RedirectUri"
}

if (-not $Resource) {
    # Proposals: IDMC MCP servers in .claude.json (user + project scopes) under $ResourcePrefix.
    $proposals = @()
    if (Test-Path $ClaudeJson) {
        $cfg = Get-Content -Raw -Encoding UTF8 $ClaudeJson | ConvertFrom-Json
        foreach ($srv in Get-McpServerEntries $cfg) {
            $url = "$($srv.Value.url)"
            if ($url.StartsWith($ResourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $name = $url.Substring($ResourcePrefix.Length).Trim('/')
                if ($name -and -not ($proposals | Where-Object Name -eq $name)) {
                    $proposals += [PSCustomObject]@{ Name = $name; Server = $srv.Name }
                }
            }
        }
    }
    $proposals = @($proposals | Sort-Object Name)
    if ($proposals.Count -gt 0) {
        Write-Host "Installed MCP servers under $ResourcePrefix"
        for ($i = 0; $i -lt $proposals.Count; $i++) {
            Write-Host ("  {0,2}) {1,-28} (Claude server: {2})" -f ($i + 1), $proposals[$i].Name, $proposals[$i].Server)
        }
    }
    $Resource = Read-Host "resource (number or MCP server name) $ResourcePrefix"
    $n = 0
    if ([int]::TryParse($Resource.Trim(), [ref]$n)) {
        if ($n -lt 1 -or $n -gt $proposals.Count) { throw "No proposal number $n" }
        $Resource = $proposals[$n - 1].Name
    }
}
$Resource = $Resource.Trim().Trim('/')
if (-not $Resource) { throw 'resource is required' }
$McpResource = $ResourcePrefix + $Resource


function ConvertTo-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# --- PKCE + state ----------------------------------------------------------
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$buf = New-Object byte[] 32; $rng.GetBytes($buf)
$codeVerifier  = ConvertTo-Base64Url $buf      # 43 chars, RFC 7636 unreserved set
$sha           = [Security.Cryptography.SHA256]::Create()
$codeChallenge = ConvertTo-Base64Url ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($codeVerifier)))
$state         = [guid]::NewGuid().ToString()

$q = [ordered]@{
    response_type         = 'code'
    client_id             = $ClientId
    redirect_uri          = $RedirectUri
    scope                 = $Scope
    state                 = $state
    code_challenge        = $codeChallenge
    code_challenge_method = 'S256'
    resource              = $McpResource
}
$authorizeUrl = "$LoginUrl/authz-service/oauth2/authorize?" +
    (($q.GetEnumerator() | ForEach-Object { $_.Key + '=' + [Uri]::EscapeDataString($_.Value) }) -join '&')

Show-Params 'PKCE (generated locally, never sent together)' ([ordered]@{
    code_verifier  = $codeVerifier
    code_challenge = "$codeChallenge  (= BASE64URL(SHA256(code_verifier)))"
})
Show-Params "GET $LoginUrl/authz-service/oauth2/authorize" $q

# --- loopback listener -----------------------------------------------------
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://$($redirect.Authority)/")
$listener.Start()
try {
    Write-Host ">> Listening on $RedirectUri"
    Write-Host ">> Opening browser for login:"
    Write-Host "   $authorizeUrl"
    Start-Process $authorizeUrl

    $code = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $code) {
        $pending = $listener.GetContextAsync()
        while (-not $pending.Wait(1000)) {
            if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSec s waiting for the OAuth callback" }
        }
        $ctx = $pending.Result
        if ($ctx.Request.Url.AbsolutePath -ne $redirect.AbsolutePath) {
            $ctx.Response.StatusCode = 404; $ctx.Response.Close(); continue
        }
        $qs = $ctx.Request.QueryString
        $msg = if ($qs['error']) { "Login failed: $($qs['error']) $($qs['error_description'])" }
               elseif ($qs['state'] -ne $state) { 'Login failed: state mismatch' }
               else { 'Login complete - you can close this tab.' }
        $html = [Text.Encoding]::UTF8.GetBytes("<html><body><h3>$([Net.WebUtility]::HtmlEncode($msg))</h3></body></html>")
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.OutputStream.Write($html, 0, $html.Length)
        $ctx.Response.Close()

        if ($qs['error'])            { throw "Authorization error: $($qs['error']) - $($qs['error_description'])" }
        if ($qs['state'] -ne $state) { throw "State mismatch in callback (possible CSRF); aborting" }
        Show-Params "Callback GET $($ctx.Request.Url.AbsolutePath)" ([ordered]@{
            code           = $qs['code']
            state          = "$($qs['state'])  (matches: $($qs['state'] -eq $state))"
        })
        $code = $qs['code']
        if (-not $code)              { throw "Callback has no code: $($ctx.Request.Url.Query)" }
    }
}
finally {
    $listener.Stop(); $listener.Close()
}
Write-Host ">> Got authorization code, exchanging at $LoginUrl/authz-service/oauth2/token ..."

# --- token exchange (POST, form-encoded, public client) ---------------------
$body = [ordered]@{
    grant_type    = 'authorization_code'
    code          = $code
    redirect_uri  = $RedirectUri
    client_id     = $ClientId
    code_verifier = $codeVerifier
    resource      = $McpResource
}
Show-Params "POST $LoginUrl/authz-service/oauth2/token  (Content-Type: application/x-www-form-urlencoded)" $body
try {
    $tokenResp = Invoke-RestMethod -Method Post -Uri "$LoginUrl/authz-service/oauth2/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body $body
} catch {
    $detail = $_.ErrorDetails.Message
    throw "Token request failed: $($_.Exception.Message) $detail"
}
$token = $tokenResp.access_token
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "No access_token in response: $($tokenResp | ConvertTo-Json -Compress)"
}

Show-TokenResponse $tokenResp

# --- save token response -----------------------------------------------------
Save-TokenRecord $McpResource 'oauth21-authorization-code-pkce' $LoginUrl $ClientId $tokenResp

# --- apply to the matching MCP servers in ~/.claude.json ----------------------
Set-McpServerToken $McpResource $token
