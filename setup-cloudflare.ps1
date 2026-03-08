$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "=== Coin Compass Cloudflare starter setup ===" -ForegroundColor Cyan
Write-Host "1. cd backend"
Write-Host "2. npm install"
Write-Host "3. npx wrangler login"
Write-Host "4. npx wrangler kv namespace create APP_KV"
Write-Host "5. Put the returned KV namespace ID into backend/wrangler.jsonc"
Write-Host "6. npx wrangler deploy"
Write-Host "7. Copy the Worker URL into frontend/index.html as API_BASE"
Write-Host "8. Upload repo to GitHub and connect frontend directory to Cloudflare Pages"
