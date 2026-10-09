@echo off
REM refresh-token-api-native.cmd - mint an IDMC REST API token (user login, client_id=idmc_api).
REM Double-click, or run from cmd:  refresh-token-api-native.cmd
REM Prompts for your IDMC password (never displayed or stored), mints a fresh
REM JWT, and saves it with the session id to %USERPROFILE%\.idmc\api-token.json.
REM This does NOT touch the MCP servers in .claude.json - use
REM refresh-token-mcp-oauth20.cmd for those.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-token-api-native.ps1"

echo.
pause
