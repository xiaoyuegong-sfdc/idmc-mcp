@echo off
REM idmc-segment.cmd - create or delete an IDMC/CDGC access segment.
REM   idmc-segment.cmd create "CMC"
REM   idmc-segment.cmd delete "CMC" [--yes]
REM   idmc-segment.cmd check
REM Creates user group "Test-UG-<segment>", asset group "<segment>" and user group policy
REM "Test-UGP-<segment>". Uses the REST API token in %USERPROFILE%\.idmc\api-token.json
REM (run refresh-token-api-browser.cmd or refresh-token-api-native.cmd first); the org is
REM the one of that token. "check" exits 4 if the MCP token is for a different org.

node "%~dp0idmc-segment.mjs" %*

echo.
pause
