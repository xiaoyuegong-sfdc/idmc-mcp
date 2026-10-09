@echo off
REM refresh-token-mcp-oauth20.cmd - refresh the IDMC MCP token via OAuth 2.0.
REM Double-click, or run from cmd:  refresh-token-mcp-oauth20.cmd
REM Prompts for your IDMC client_id and client_secret (secret never displayed or
REM stored), mints a fresh access token using the client_credentials grant, and
REM writes it into %USERPROFILE%\.claude.json. This is the ONLY token used by the
REM MCP servers; REST API tokens come from refresh-token-api-native.cmd / refresh-token-api-browser.cmd.
REM Afterwards:  /mcp  ->  reconnect cdgcsearchmetadata

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-token-mcp-oauth20.ps1"

echo.
pause
