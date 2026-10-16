@echo off
REM refresh-token-mcp-oauth20.cmd - refresh the IDMC MCP token via OAuth 2.0.
REM Double-click, or run from cmd:  refresh-token-mcp-oauth20.cmd
REM Prompts for your IDMC client_id and client_secret (secret never displayed or
REM stored), mints a fresh access token using the client_credentials grant, and
REM writes it into %USERPROFILE%\.claude.json. It is the token for all IDMC MCP
REM servers (refresh-token-mcp-oauth21.cmd mints a per-server user token); REST API tokens come from refresh-token-api-native.cmd / refresh-token-api-browser.cmd.
REM The token (not the secret) is also saved to %USERPROFILE%\.idmc\mcp-oauth20-token.json;
REM  refresh-token-mcp-oauth20.cmd -ApplySaved  re-applies it without prompting.
REM Afterwards: run /mcp and reconnect the IDMC servers

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-token-mcp-oauth20.ps1" %*

echo.
pause
