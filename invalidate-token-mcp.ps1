# invalidate-token-mcp.ps1
# Clears the authentication of every local-scope MCP server of this project and
# removes the saved MCP access and refresh tokens:
#   1. %USERPROFILE%\.claude.json -> projects["<project folder>"].mcpServers.<name>:
#      deletes headers.Authorization (and headers, if it is then empty);
#      %USERPROFILE%\.claude\.credentials.json -> mcpOAuth: deletes Claude Code's own
#      OAuth login of those servers (what /mcp -> "Clear authentication" removes).
#      Both files are backed up to <file>.bak-invalidate-<timestamp> first.
#   2. deletes the saved MCP token files %USERPROFILE%\.idmc\mcp-oauth20-token.json
#      (access token) and %USERPROFILE%\.idmc\mcp-oauth21-token.json (access and
#      refresh tokens); override IDMC_OAUTH20_TOKEN_FILE / IDMC_OAUTH21_TOKEN_FILE.
#
# User-scope servers, other projects and the REST API token (~/.idmc/api-token.json)
# are left alone. The tokens are only deleted locally, not revoked at IDMC: an access
# token copied elsewhere stays valid until it expires.
# Afterwards the servers fail to connect until a new token is written with
# refresh-token-mcp-oauth20.ps1 or refresh-token-mcp-oauth21.ps1 (-ApplySaved and
# -Refresh no longer work, there is nothing saved); then reconnect them via /mcp.
#
# -Project  project folder whose local servers are cleared (default: this script's folder)
# -Force    no confirmation prompt
# -WhatIf   only list what would be removed

param(
    [string]$Project = $PSScriptRoot,
    [switch]$Force,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$ClaudeJson  = if ($env:CLAUDE_JSON) { $env:CLAUDE_JSON } else { Join-Path $env:USERPROFILE '.claude.json' }
$Credentials = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$TokenFiles  = @(
    $(if ($env:IDMC_OAUTH20_TOKEN_FILE) { $env:IDMC_OAUTH20_TOKEN_FILE } else { Join-Path $env:USERPROFILE '.idmc\mcp-oauth20-token.json' })
    $(if ($env:IDMC_OAUTH21_TOKEN_FILE) { $env:IDMC_OAUTH21_TOKEN_FILE } else { Join-Path $env:USERPROFILE '.idmc\mcp-oauth21-token.json' })
)
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-JsonFile([string]$path, $obj) {
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
}

# --- find the local servers ------------------------------------------------
$projectKey = $Project.TrimEnd('\', '/').Replace('\', '/')
$cfg = Get-Content -Raw -Encoding UTF8 $ClaudeJson | ConvertFrom-Json
$proj = $null
if ($cfg.projects) {
    $proj = $cfg.projects.PSObject.Properties | Where-Object { $_.Name -ieq $projectKey } | Select-Object -First 1
}
$servers = if ($proj -and $proj.Value.mcpServers) { @($proj.Value.mcpServers.PSObject.Properties) } else { @() }
$serverNames = @($servers | ForEach-Object Name)

$withHeader = @($servers | Where-Object { $_.Value.headers -and $_.Value.headers.PSObject.Properties['Authorization'] })

$cred = $null
$oauthKeys = @()
if (Test-Path $Credentials) {
    $cred = Get-Content -Raw -Encoding UTF8 $Credentials | ConvertFrom-Json
    if ($cred.mcpOAuth) {
        $oauthKeys = @($cred.mcpOAuth.PSObject.Properties | Where-Object { $serverNames -contains $_.Value.serverName } | ForEach-Object Name)
    }
}

$existingTokenFiles = @($TokenFiles | Where-Object { Test-Path $_ })

# --- summary + confirmation --------------------------------------------------
Write-Host "Project: $projectKey"
if (-not $proj) { Write-Host "   (no entry in $ClaudeJson)" }
Write-Host "Local MCP servers: $(if ($serverNames) { $serverNames -join ', ' } else { 'none' })"
Write-Host "1. Authorization header to remove ($ClaudeJson): $(if ($withHeader) { ($withHeader | ForEach-Object Name) -join ', ' } else { 'none' })"
Write-Host "   Claude Code OAuth logins to remove ($Credentials): $(if ($oauthKeys) { ($oauthKeys | ForEach-Object { $_.Split('|')[0] }) -join ', ' } else { 'none' })"
Write-Host "2. Saved MCP token files to delete: $(if ($existingTokenFiles) { $existingTokenFiles -join ', ' } else { 'none' })"

if (-not $withHeader -and -not $oauthKeys -and -not $existingTokenFiles) {
    Write-Host ">> Nothing to invalidate."
    return
}
if ($WhatIf) { Write-Host ">> -WhatIf: nothing changed."; return }
if (-not $Force) {
    $answer = Read-Host 'Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { Write-Host ">> Aborted, nothing changed."; return }
}

# --- 1. clear authentication -------------------------------------------------
if ($withHeader) {
    Copy-Item $ClaudeJson "$ClaudeJson.bak-invalidate-$Stamp"
    foreach ($srv in $withHeader) {
        $srv.Value.headers.PSObject.Properties.Remove('Authorization')
        if (-not @($srv.Value.headers.PSObject.Properties).Count) { $srv.Value.PSObject.Properties.Remove('headers') }
    }
    Write-JsonFile $ClaudeJson $cfg
    Write-Host ">> Removed the Authorization header of $(($withHeader | ForEach-Object Name) -join ', ') (backup: $ClaudeJson.bak-invalidate-$Stamp)"
}
if ($oauthKeys) {
    Copy-Item $Credentials "$Credentials.bak-invalidate-$Stamp"
    foreach ($k in $oauthKeys) { $cred.mcpOAuth.PSObject.Properties.Remove($k) }
    Write-JsonFile $Credentials $cred
    Write-Host ">> Removed $($oauthKeys.Count) Claude Code OAuth login(s) (backup: $Credentials.bak-invalidate-$Stamp)"
}

# --- 2. remove the saved access / refresh tokens ------------------------------
foreach ($f in $existingTokenFiles) {
    Remove-Item -Force $f
    Write-Host ">> Deleted $f"
}

Write-Host ">> Done. Reconnecting now fails until a new token is written: run refresh-token-mcp-oauth20.cmd"
Write-Host "   or refresh-token-mcp-oauth21.cmd, then /mcp -> reconnect. A running Claude Code session keeps"
Write-Host "   its open connections until /mcp -> reconnect or a restart."
