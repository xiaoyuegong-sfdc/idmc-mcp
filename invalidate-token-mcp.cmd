@echo off
REM invalidate-token-mcp.cmd - clears the authentication of all local MCP servers of this
REM project (Authorization header in %USERPROFILE%\.claude.json and Claude Code's OAuth login
REM in %USERPROFILE%\.claude\.credentials.json, both backed up) and deletes the saved MCP
REM access/refresh tokens %USERPROFILE%\.idmc\mcp-oauth20-token.json / mcp-oauth21-token.json.
REM The REST API token (api-token.json) is kept. Asks for confirmation unless -Force;
REM -WhatIf only lists what would be removed.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invalidate-token-mcp.ps1" %*

echo.
pause
