@echo off
REM refresh-token-mcp-oauth21.cmd - IDMC MCP token via OAuth 2.1 authorization code + PKCE.
REM Prompts for baseUrl [https://dm-em.informaticacloud.com], client_id,
REM redirect_uri [http://localhost:9876/callback] and the MCP
REM server name (resource; installed servers are proposed), opens the browser for login, catches the code on redirect_uri,
REM POSTs it to /authz-service/oauth2/token and saves %USERPROFILE%\.idmc\mcp-oauth21-token.json.
REM The token is written into every MCP server in %USERPROFILE%\.claude.json that uses
REM that resource; then reconnect it in /mcp. -ApplySaved re-applies the saved token without login.
REM -Refresh [-Resource name] gets a new access token with the saved refresh_token, without login.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-token-mcp-oauth21.ps1" %*

echo.
pause
