# refresh-token-api-browser.ps1
# Mints a fresh IDMC JWT from an interactive browser (SSO) login for calling the IDMC /
# CDGC REST APIs and saves it, with the session id, to %USERPROFILE%\.idmc\api-token.json.
#
# This is the REST API token. It is NOT written to the MCP servers in .claude.json -
# they use the OAuth token from refresh-token-mcp-oauth20.ps1.
#
# Unlike refresh-token-api-native.ps1 (username/password) and refresh-token-mcp-oauth20.ps1
# (client_id/secret), no credential is typed here:
#   1. confirm the IDMC login URL (e.g. an SSO URL .../ma/sso/<orgId>)
#   2. open it in Edge with a DevTools debug port and a dedicated profile; you log in
#   3. read the IDS-SESSION cookie over the DevTools protocol
#   4. GET /identity-service/api/v1/jwt/Token?client_id=idmc_api&nonce=1234
#      with header IDS-SESSION-ID: <cookie>  ->  jwt_token
#
# Chrome is not used by default: corporate policy blocks its remote-debugging port.
# The dedicated profile remembers the SSO login, so later runs may finish without
# any clicks while the IDMC session is still alive.
#
# IDMC access tokens expire ~30 minutes after grant; re-run when an API call returns 401.

param(
    [string]$LoginUrl            # skip the prompt, e.g. -LoginUrl https://dm-em.informaticacloud.com/ma/sso/<orgId>
)

$ErrorActionPreference = 'Stop'

$DefaultLoginUrl = if ($env:IDMC_BROWSER_LOGIN_URL) { $env:IDMC_BROWSER_LOGIN_URL } else { 'https://dm-em.informaticacloud.com/identity-service/home' }
$TokenFile   = if ($env:IDMC_API_TOKEN_FILE) { $env:IDMC_API_TOKEN_FILE } else { Join-Path $env:USERPROFILE '.idmc\api-token.json' }
$DebugPort   = if ($env:IDMC_DEBUG_PORT)    { [int]$env:IDMC_DEBUG_PORT } else { 9334 }
$TimeoutSec  = if ($env:IDMC_LOGIN_TIMEOUT) { [int]$env:IDMC_LOGIN_TIMEOUT } else { 300 }
$ProfileDir  = if ($env:IDMC_PROFILE_DIR)   { $env:IDMC_PROFILE_DIR } else { Join-Path $env:TEMP 'idmc-login-edge' }

# --- step 1: confirm the login URL ------------------------------------------
if (-not $LoginUrl) {
    $LoginUrl = Read-Host "IDMC login URL [$DefaultLoginUrl]"
    if ([string]::IsNullOrWhiteSpace($LoginUrl)) { $LoginUrl = $DefaultLoginUrl }
}
$uri = [Uri]$LoginUrl
if ($uri.Scheme -ne 'https') { throw "Login URL must be https: $LoginUrl" }
$BaseUrl  = $uri.GetLeftPart([UriPartial]::Authority)   # e.g. https://dm-em.informaticacloud.com
$IdmcHost = $uri.Host
Write-Host ">> Login URL: $LoginUrl"

# --- DevTools protocol helper: one request/response on a websocket target -----
function Invoke-Cdp([string]$WsUrl, [string]$Method) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [Threading.CancellationToken]::None
    try {
        $ws.ConnectAsync([Uri]$WsUrl, $ct).GetAwaiter().GetResult()
        $req = [Text.Encoding]::UTF8.GetBytes((@{ id = 1; method = $Method } | ConvertTo-Json -Compress))
        $ws.SendAsync((New-Object 'ArraySegment[byte]' (,$req)), 'Text', $true, $ct).GetAwaiter().GetResult()
        $buf = New-Object byte[] 65536
        while ($true) {
            $ms = New-Object IO.MemoryStream
            do {
                $r = $ws.ReceiveAsync((New-Object 'ArraySegment[byte]' (,$buf)), $ct).GetAwaiter().GetResult()
                $ms.Write($buf, 0, $r.Count)
            } while (-not $r.EndOfMessage)
            $msg = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            if ($msg.id -eq 1) { return $msg.result }
        }
    } finally {
        if ($ws.State -eq 'Open') { $ws.CloseAsync('NormalClosure', '', $ct).GetAwaiter().GetResult() }
        $ws.Dispose()
    }
}

function Get-DebugVersion {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json/version" -TimeoutSec 3 } catch { $null }
}

# --- step 2: open the login URL in a debuggable Edge -------------------------
if (Get-DebugVersion) {
    Write-Host ">> Reusing debug browser on port $DebugPort, opening a new tab ..."
    Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$DebugPort/json/new?$LoginUrl" | Out-Null
} else {
    $browser = if ($env:IDMC_BROWSER) { $env:IDMC_BROWSER } else {
        @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $browser) { throw "Microsoft Edge not found; set IDMC_BROWSER to a Chromium browser path" }
    Write-Host ">> Launching $browser ..."
    Start-Process $browser -ArgumentList "--remote-debugging-port=$DebugPort", "--user-data-dir=`"$ProfileDir`"", '--no-first-run', $LoginUrl
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Get-DebugVersion)) {
        if ((Get-Date) -gt $deadline) { throw "Browser debug port $DebugPort did not open (blocked by policy?)" }
        Start-Sleep -Milliseconds 500
    }
}

# --- step 3+4: wait for login, read IDS-SESSION, exchange it for a JWT -------
Write-Host ">> Please log in to IDMC in the browser window (waiting up to $TimeoutSec s) ..."
$jwt = $null
$tried = @{}
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not $jwt) {
    if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSec s waiting for a valid IDS-SESSION cookie" }
    Start-Sleep -Seconds 2

    $wsUrl   = (Get-DebugVersion).webSocketDebuggerUrl
    if (-not $wsUrl) { throw "Browser was closed before login completed" }
    $session = (Invoke-Cdp $wsUrl 'Storage.getCookies').cookies |
        Where-Object { $_.name -eq 'IDS-SESSION' -and $IdmcHost.EndsWith($_.domain.TrimStart('.')) } |
        Select-Object -First 1 -ExpandProperty value
    # Skip until a cookie appears; a stale one from an earlier run is tried only once.
    if (-not $session -or $tried[$session]) { continue }
    $tried[$session] = $true

    try {
        $jwtResp = Invoke-RestMethod -Method Get `
            -Uri "$BaseUrl/identity-service/api/v1/jwt/Token?client_id=idmc_api&nonce=1234" `
            -Headers @{ 'IDS-SESSION-ID' = $session }
    } catch {
        Write-Host ">> IDS-SESSION not accepted yet ($($_.Exception.Message)); still waiting for login ..."
        continue
    }

    # Endpoint may return a raw token string or a JSON wrapper.
    $token = if ($jwtResp -is [string]) { $jwtResp } else { $jwtResp.jwt_token }
    $token = ("$token").Trim().Trim('"')
    if (($token -split '\.').Count -ne 3) { throw "Did not get a JWT (got: $($token.Substring(0,[Math]::Min(80,$token.Length)))...)" }
    $jwt = $token
}

$payload = ($jwt -split '\.')[1].Replace('-', '+').Replace('_', '/')
$payload += '=' * ((4 - $payload.Length % 4) % 4)
$claims  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
Write-Host ">> Got JWT for $($claims.user_name) ($($claims.org_name))"

# --- step 5: save JWT + session id to the REST API token file -----------------
$record = [ordered]@{
    source    = 'refresh-token-api-browser'
    baseUrl   = $BaseUrl
    user      = $claims.user_name
    orgId     = $claims.org_id
    orgName   = $claims.org_name
    issuedAt  = ([DateTimeOffset]::FromUnixTimeSeconds($claims.iat)).UtcDateTime.ToString('o')
    expiresAt = ([DateTimeOffset]::FromUnixTimeSeconds($claims.exp)).UtcDateTime.ToString('o')
    sessionId = $session
    jwt       = $jwt
}
New-Item -ItemType Directory -Force (Split-Path $TokenFile) | Out-Null
[System.IO.File]::WriteAllText($TokenFile, ($record | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ">> Saved REST API token to $TokenFile (expires $($record.expiresAt))"
