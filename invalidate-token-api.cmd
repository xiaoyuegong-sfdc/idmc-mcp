@echo off
REM invalidate-token-api.cmd - removes the stored REST API token: logs the IDMC session out
REM (v3 logout with the saved session id; -NoLogout skips it) and deletes
REM %USERPROFILE%\.idmc\api-token.json (session id + JWT). -Profiles also deletes the Edge
REM login profiles (%TEMP%\idmc-login-edge*) of refresh-token-api-browser. The MCP tokens are
REM kept (see invalidate-token-mcp.cmd). Asks for confirmation unless -Force;
REM -WhatIf only lists what would be removed.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invalidate-token-api.ps1" %*

echo.
pause
