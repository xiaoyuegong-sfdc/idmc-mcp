# refresh-token-api-native.ps1
# Mints a fresh IDMC JWT (identity-service, client_id=idmc_api) for calling the IDMC /
# CDGC REST APIs and saves it, with the session id, to %USERPROFILE%\.idmc\api-token.json.
#
# This is the REST API token. It is NOT written to the MCP servers in .claude.json -
# they use the OAuth token from refresh-token-mcp-oauth20.ps1.
#
# IDMC access tokens expire 30 minutes after grant; re-run when an API call returns 401.
#
# The password is prompted securely (never displayed, never stored).
# Env overrides: IDMC_LOGIN_URL, IDMC_USER (default username), IDMC_API_TOKEN_FILE.

$ErrorActionPreference = 'Stop'

$LoginUrl   = if ($env:IDMC_LOGIN_URL) { $env:IDMC_LOGIN_URL } else { 'https://dm-em.informaticacloud.com' }
$TokenFile  = if ($env:IDMC_API_TOKEN_FILE) { $env:IDMC_API_TOKEN_FILE } else { Join-Path $env:USERPROFILE '.idmc\api-token.json' }
$DefaultUser = $env:IDMC_USER   # optional default for the username prompt

# --- credentials (prompted; nothing stored on disk) ------------------------
$user = Read-Host $(if ($DefaultUser) { "IDMC username [$DefaultUser]" } else { "IDMC username" })
if ([string]::IsNullOrWhiteSpace($user)) { $user = $DefaultUser }
if ([string]::IsNullOrWhiteSpace($user)) { throw "username is required" }
$secure = Read-Host "IDMC password" -AsSecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$pass   = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

try {
    # --- step 1: login -> sessionId ----------------------------------------
    Write-Host ">> Logging in to $LoginUrl/identity-service/api/v1/Login ..."
    $loginBody  = @{ username = $user; password = $pass } | ConvertTo-Json
    $loginResp  = Invoke-RestMethod -Method Post `
        -Uri "$LoginUrl/identity-service/api/v1/Login" `
        -ContentType 'application/json' -Body $loginBody
    $sessionId = $loginResp.sessionId
    if (-not $sessionId) { $sessionId = $loginResp.session_id }
    if (-not $sessionId) { throw "No sessionId in login response: $($loginResp | ConvertTo-Json -Compress)" }

    # --- step 2: sessionId -> JWT ------------------------------------------
    Write-Host ">> Got sessionId, requesting JWT ..."
    $headers = @{ 'IDS-SESSION-ID' = $sessionId; 'cookie' = "USER_SESSION=$sessionId" }
    $jwtResp = Invoke-RestMethod -Method Get `
        -Uri "$LoginUrl/identity-service/api/v1/jwt/Token?client_id=idmc_api&nonce=1234" `
        -Headers $headers

    # Endpoint may return a raw token string or a JSON wrapper.
    if ($jwtResp -is [string]) {
        $jwt = $jwtResp.Trim()
    } else {
        $jwt = $jwtResp.jwt_token; if (-not $jwt) { $jwt = $jwtResp.token }; if (-not $jwt) { $jwt = $jwtResp.access_token }
    }
    $jwt = ("$jwt").Trim().Trim('"')
    if (($jwt -split '\.').Count -ne 3) { throw "Did not get a JWT (got: $($jwt.Substring(0,[Math]::Min(80,$jwt.Length)))...)" }
}
finally {
    $pass = $null  # drop plaintext password from memory
}

# --- step 3: save JWT + session id to the REST API token file ---------------
$payload = ($jwt -split '\.')[1].Replace('-', '+').Replace('_', '/')
$payload += '=' * ((4 - $payload.Length % 4) % 4)
$claims  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json

$record = [ordered]@{
    source    = 'refresh-token-api-native'
    baseUrl   = $LoginUrl
    user      = $claims.user_name
    orgId     = $claims.org_id
    orgName   = $claims.org_name
    issuedAt  = ([DateTimeOffset]::FromUnixTimeSeconds($claims.iat)).UtcDateTime.ToString('o')
    expiresAt = ([DateTimeOffset]::FromUnixTimeSeconds($claims.exp)).UtcDateTime.ToString('o')
    sessionId = $sessionId
    jwt       = $jwt
}
New-Item -ItemType Directory -Force (Split-Path $TokenFile) | Out-Null
[System.IO.File]::WriteAllText($TokenFile, ($record | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ">> Saved REST API token for $($claims.user_name) ($($claims.org_name)) to $TokenFile (expires $($record.expiresAt))"
