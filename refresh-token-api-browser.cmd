@echo off
REM refresh-token-api-browser.cmd - mint an IDMC REST API token from a browser (SSO) login.
REM Double-click, or run from cmd:  refresh-token-api-browser.cmd [-LoginUrl <url>]
REM Asks you to confirm the IDMC login URL, opens it in Edge for you to log in,
REM reads the IDS-SESSION cookie, exchanges it for a JWT, and saves both to
REM %USERPROFILE%\.idmc\api-token.json.
REM This does NOT touch the MCP servers in .claude.json - use
REM refresh-token-mcp-oauth20.cmd for those.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-token-api-browser.ps1" %*

echo.
pause
