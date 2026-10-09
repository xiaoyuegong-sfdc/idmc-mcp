# refresh-token-mcp-oauth20.ps1
# Mints a fresh IDMC access token via the OAuth 2.0 client-credentials grant
# (authz-service) and writes it into the Authorization header of each configured
# IDMC MCP server (all names in $ServerNames) in %USERPROFILE%\.claude.json.
#
# This is the ONLY script that writes the MCP servers' token in .claude.json.
# refresh-token-api-native.ps1 / refresh-token-api-browser.ps1 mint the REST API token instead and
# save it to %USERPROFILE%\.idmc\api-token.json, leaving .claude.json untouched.
#
# Unlike refresh-token-api-native.ps1 (identity-service user login -> JWT), this uses the
# OAuth 2.0 client_credentials flow: POST /authz-service/oauth/token with the
# query parameters grant_type=client_credentials, client_id, client_secret.
#
# IDMC access tokens expire ~30 minutes after grant. Re-run whenever one of the
# MCP servers reports a 401, then /mcp -> reconnect it.
#
# The client_secret is prompted securely (never displayed, never stored).

$ErrorActionPreference = 'Stop'

$LoginUrl    = if ($env:IDMC_LOGIN_URL) { $env:IDMC_LOGIN_URL } else { 'https://dm-em.informaticacloud.com' }
$ClaudeJson  = if ($env:CLAUDE_JSON)    { $env:CLAUDE_JSON }    else { Join-Path $env:USERPROFILE '.claude.json' }
$ServerNames = @('cdgcsearchmetadata','usermanagement','claire-data-exploration-agent-mcp','catalog-discovery','catalog-enrichment','data-marketplace-order-management')

# --- credentials (prompted; nothing stored on disk) ------------------------
$clientId = Read-Host "IDMC client_id"
if ([string]::IsNullOrWhiteSpace($clientId)) { throw "client_id is required" }
$secure   = Read-Host "IDMC client_secret" -AsSecureString
$bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$clientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
if ([string]::IsNullOrWhiteSpace($clientSecret)) { throw "client_secret is required" }

try {
    # --- request access token via client_credentials grant -----------------
    Write-Host ">> Requesting access token from $LoginUrl/authz-service/oauth/token ..."
    $query = 'grant_type=client_credentials' +
             '&client_id='     + [Uri]::EscapeDataString($clientId) +
             '&client_secret=' + [Uri]::EscapeDataString($clientSecret)
    $tokenResp = Invoke-RestMethod -Method Post `
        -Uri "$LoginUrl/authz-service/oauth/token?$query"

    # Endpoint may return a raw token string or a JSON wrapper.
    if ($tokenResp -is [string]) {
        $token = $tokenResp.Trim()
    } else {
        $token = $tokenResp.access_token
        if (-not $token) { $token = $tokenResp.jwt_token }
        if (-not $token) { $token = $tokenResp.token }
    }
    $token = ("$token").Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "No access token in response: $($tokenResp | ConvertTo-Json -Compress)"
    }
}
finally {
    $clientSecret = $null  # drop plaintext secret from memory
}

# --- write token into ~/.claude.json ---------------------------------------
Write-Host ">> Got access token, updating headers in $ClaudeJson ..."
$json = Get-Content -Raw -Encoding UTF8 $ClaudeJson | ConvertFrom-Json

$script:updated = 0
function Set-Auth($node) {
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $node.PSObject.Properties) {
            if (($ServerNames -contains $prop.Name) -and $prop.Value -is [System.Management.Automation.PSCustomObject]) {
                if (-not $prop.Value.PSObject.Properties['headers']) {
                    $prop.Value | Add-Member -NotePropertyName headers -NotePropertyValue ([PSCustomObject]@{})
                }
                $h = $prop.Value.headers
                if ($h.PSObject.Properties['Authorization']) { $h.Authorization = "Bearer $token" }
                else { $h | Add-Member -NotePropertyName Authorization -NotePropertyValue "Bearer $token" }
                $script:updated++
            }
            Set-Auth $prop.Value
        }
    } elseif ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
        foreach ($item in $node) { Set-Auth $item }
    }
}
Set-Auth $json

if ($script:updated -eq 0) { throw "None of the servers ($($ServerNames -join ', ')) were found in $ClaudeJson" }

# Backup once, then write (preserve UTF-8, no BOM).
$backup = "$ClaudeJson.bak"
if (-not (Test-Path $backup)) { Copy-Item $ClaudeJson $backup }
$out = $json | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($ClaudeJson, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ">> Updated $script:updated entr$(if($script:updated -eq 1){'y'}else{'ies'}). Now reconnect: /mcp -> $($ServerNames -join ', ')"
