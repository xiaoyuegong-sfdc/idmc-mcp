# invalidate-token-api.ps1
# Removes the stored REST API token (the user-login JWT and IDMC session id written by
# refresh-token-api-native.ps1 / refresh-token-api-browser.ps1):
#   1. logs the session out at IDMC (POST {login host}/saas/public/core/v3/logout with
#      header INFA-SESSION-ID; the login host is the token's baseUrl, the v3 pod answers
#      404), so neither the session id nor JWTs minted from it can be used again
#      (idmc-segment.mjs re-mints the JWT from the session id); best effort, an already
#      expired session is reported and skipped. -NoLogout skips this step.
#   2. deletes %USERPROFILE%\.idmc\api-token.json (override IDMC_API_TOKEN_FILE).
#   3. with -Profiles only: deletes the dedicated Edge login profiles of
#      refresh-token-api-browser.ps1 (%TEMP%\idmc-login-edge*, or IDMC_PROFILE_DIR),
#      which remember the SSO login, so the next browser refresh asks for a login again.
#      Edge must not be running with that profile.
#
# The MCP tokens (.claude.json, mcp-oauth2*-token.json) are left alone; use
# invalidate-token-mcp.ps1 for those. Afterwards get a new token with
# refresh-token-api-browser.cmd or refresh-token-api-native.cmd.
#
# -Force    no confirmation prompt
# -WhatIf   only list what would be removed
# Env overrides: IDMC_API_TOKEN_FILE, IDMC_LOGIN_URL (login host if the token has no
# baseUrl, default https://dm-em.informaticacloud.com), IDMC_PROFILE_DIR.

param(
    [switch]$NoLogout,
    [switch]$Profiles,
    [switch]$Force,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$TokenFile = if ($env:IDMC_API_TOKEN_FILE) { $env:IDMC_API_TOKEN_FILE } else { Join-Path $env:USERPROFILE '.idmc\api-token.json' }
$DefaultLoginUrl = if ($env:IDMC_LOGIN_URL) { $env:IDMC_LOGIN_URL } else { 'https://dm-em.informaticacloud.com' }

$record = $null
if (Test-Path $TokenFile) {
    try { $record = Get-Content -Raw -Encoding UTF8 $TokenFile | ConvertFrom-Json }
    catch { Write-Host ">> $TokenFile is not valid JSON - it is deleted without logout." }
}
$sessionId = if ($record) { "$($record.sessionId)" } else { '' }
$LoginUrl  = if ($record -and $record.baseUrl) { ([Uri]"$($record.baseUrl)").GetLeftPart('Authority') } else { $DefaultLoginUrl.TrimEnd('/') }

$profileDirs = @()
if ($Profiles) {
    $profileDirs = if ($env:IDMC_PROFILE_DIR) { @($env:IDMC_PROFILE_DIR | Where-Object { Test-Path $_ }) }
                   else { @(Get-ChildItem -Directory -Path $env:TEMP -Filter 'idmc-login-edge*' | ForEach-Object FullName) }
}

# --- summary + confirmation --------------------------------------------------
if ($record) {
    Write-Host "Token file: $TokenFile"
    Write-Host "   source $($record.source), user $($record.user), org $($record.orgName) ($($record.orgId)), JWT expires $($record.expiresAt)"
} elseif (Test-Path $TokenFile) {
    Write-Host "Token file: $TokenFile"
} else {
    Write-Host "Token file: none ($TokenFile)"
}
Write-Host "1. IDMC session logout: $(if ($NoLogout) { 'skipped (-NoLogout)' } elseif ($sessionId) { "POST $LoginUrl/saas/public/core/v3/logout" } else { 'none (no session id)' })"
Write-Host "2. Delete token file:   $(if (Test-Path $TokenFile) { 'yes' } else { 'none' })"
if ($Profiles) { Write-Host "3. Edge login profiles to delete: $(if ($profileDirs) { $profileDirs -join ', ' } else { 'none' })" }

if (-not (Test-Path $TokenFile) -and -not $profileDirs) {
    Write-Host ">> Nothing to invalidate."
    return
}
if ($WhatIf) { Write-Host ">> -WhatIf: nothing changed."; return }
if (-not $Force) {
    $answer = Read-Host 'Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { Write-Host ">> Aborted, nothing changed."; return }
}

# --- 1. end the IDMC session ---------------------------------------------------
if ($sessionId -and -not $NoLogout) {
    try {
        Invoke-RestMethod -Method Post -Uri "$LoginUrl/saas/public/core/v3/logout" `
            -Headers @{ 'INFA-SESSION-ID' = $sessionId; Accept = 'application/json' } | Out-Null
        Write-Host ">> Logged out IDMC session of $($record.user)"
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -eq 401 -or $status -eq 403) {
            Write-Host ">> Logout: session already expired or invalid (HTTP $status)"
        } else {
            Write-Host ">> Logout failed: $($_.Exception.Message) $($_.ErrorDetails.Message)"
            Write-Host "   (wrong login host? check baseUrl in the token file) - the token file is deleted anyway; the session ends when it times out."
        }
    }
}

# --- 2. delete the stored token --------------------------------------------------
if (Test-Path $TokenFile) {
    Remove-Item -Force $TokenFile
    Write-Host ">> Deleted $TokenFile"
}

# --- 3. delete the Edge login profiles -----------------------------------------
foreach ($d in $profileDirs) {
    try { Remove-Item -Recurse -Force $d; Write-Host ">> Deleted Edge profile $d" }
    catch { Write-Host ">> Could not delete $d (Edge still running with it?): $($_.Exception.Message)" }
}

Write-Host ">> Done. Get a new REST API token with refresh-token-api-browser.cmd or refresh-token-api-native.cmd."
