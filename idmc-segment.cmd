@echo off
REM idmc-segment.cmd - create or delete an IDMC/CDGC access segment.
REM   idmc-segment.cmd create "CMC" [--email=a@b.com]
REM   idmc-segment.cmd delete "CMC" [--yes]
REM   idmc-segment.cmd check
REM Creates user group "Test-UG-<segment>", asset group "<segment>", user group policy
REM "Test-UGP-<segment>" and, with --email, user "Test-U-<segment>". Uses the REST API token in
REM %USERPROFILE%\.idmc\api-token.json (run refresh-token-api-browser.cmd or
REM refresh-token-api-native.cmd first); the org is the one of that token. "check" exits 4 if
REM the MCP token is for a different org, 5 if the MCP token is missing or invalid.

node "%~dp0idmc-segment.mjs" %*

echo.
pause
