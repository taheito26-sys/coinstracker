param(
    [string]$RepoPath = "D:\GitHUB\CoinsTracker",
    [string]$GitHubOwner = "taheito26-sys",
    [string]$GitHubRepo = "coinstracker",
    [ValidateSet('public','private')]
    [string]$GitHubVisibility = "public",
    [string]$CloudflareAccountId = "b925bfdb964cd7966d1a1ce63049ddb0",
    [string]$PagesProjectName = "coinstracker",
    [string]$ProductionBranch = "main",
    [string]$WorkerName = "coin-compass-api",
    [string]$CloudflareApiToken = "",
    [switch]$CreateRepoIfMissing,
    [switch]$CreatePagesProject,
    [switch]$OverwriteRemote
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Warn([string]$Message) {
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Write-Ok([string]$Message) {
    Write-Host $Message -ForegroundColor Green
}

function Assert-Path([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Get-CommandPathOrNull([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Resolve-GhPath {
    $candidates = @(
        (Get-CommandPathOrNull 'gh'),
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "GitHub CLI not found. Install GitHub CLI first."
    }

    return $candidates[0]
}

function Run-External {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [switch]$CaptureOutput,
        [switch]$AllowFailure
    )

    Push-Location $WorkingDirectory
    try {
        if ($CaptureOutput) {
            $output = & $FilePath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
            if (-not $AllowFailure -and $exitCode -ne 0) {
                $text = ($output | Out-String)
                throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')`n$text"
            }
            return ,$output
        }
        else {
            & $FilePath @Arguments
            $exitCode = $LASTEXITCODE
            if (-not $AllowFailure -and $exitCode -ne 0) {
                throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')"
            }
        }
    }
    finally {
        Pop-Location
    }
}

function Get-GitStatusPorcelain([string]$WorkingDirectory) {
    $lines = Run-External -FilePath 'git' -Arguments @('status','--porcelain') -WorkingDirectory $WorkingDirectory -CaptureOutput
    return @($lines | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().Length -gt 0 })
}

function Ensure-LineInFile([string]$FilePath, [string]$Line) {
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Set-Content -LiteralPath $FilePath -Value $Line -Encoding UTF8
        return
    }

    $content = Get-Content -LiteralPath $FilePath -Raw
    if ($content -notmatch [regex]::Escape($Line)) {
        Add-Content -LiteralPath $FilePath -Value "`n$Line"
    }
}

function Set-WorkerUrlInFrontend([string]$FrontendPath, [string]$WorkerUrl) {
    $content = Get-Content -LiteralPath $FrontendPath -Raw
    $escaped = [regex]::Escape($WorkerUrl)

    if ($content -match 'https://REPLACE_WITH_YOUR_WORKER_URL') {
        $content = $content -replace 'https://REPLACE_WITH_YOUR_WORKER_URL', $WorkerUrl
    }
    elseif ($content -match 'const\s+API_BASE\s*=\s*"https://[^"]+";') {
        $content = [regex]::Replace($content, 'const\s+API_BASE\s*=\s*"https://[^"]+";', "const API_BASE = `"$WorkerUrl`";")
    }
    elseif ($content -notmatch $escaped) {
        throw "Could not find frontend API_BASE placeholder or existing Worker URL in $FrontendPath"
    }

    Set-Content -LiteralPath $FrontendPath -Value $content -Encoding UTF8
}

function Get-CloudflareToken([string]$ProvidedToken) {
    if ($ProvidedToken) { return $ProvidedToken }
    if ($env:CLOUDFLARE_API_TOKEN) { return $env:CLOUDFLARE_API_TOKEN }

    $secure = Read-Host 'Paste Cloudflare API token with Pages Write and Workers deploy permissions' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Invoke-CfApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Token,
        [object]$Body = $null,
        [switch]$AllowFailure
    )

    $headers = @{ Authorization = "Bearer $Token" }
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 20 -Compress
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json' -Body $json
        }
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    catch {
        if ($AllowFailure) { return $null }
        throw
    }
}

Write-Step 'Validate local structure'
Assert-Path $RepoPath 'RepoPath'
Assert-Path (Join-Path $RepoPath 'frontend\index.html') 'frontend/index.html'
Assert-Path (Join-Path $RepoPath 'backend\wrangler.jsonc') 'backend/wrangler.jsonc'
Assert-Path (Join-Path $RepoPath 'backend\package.json') 'backend/package.json'

Write-Step 'Validate prerequisites'
foreach ($cmd in @('git','node','npm','npx')) {
    if (-not (Get-CommandPathOrNull $cmd)) {
        throw "Required command not found: $cmd"
    }
}
$ghPath = Resolve-GhPath
Write-Ok "Using gh at: $ghPath"

Write-Step 'Check GitHub CLI auth'
Run-External -FilePath $ghPath -Arguments @('auth','status') -CaptureOutput | Out-Host

Write-Step 'Install backend dependencies'
Run-External -FilePath 'npm' -Arguments @('install') -WorkingDirectory (Join-Path $RepoPath 'backend')

Write-Step 'Check Wrangler auth'
$whoamiOut = Run-External -FilePath 'npx' -Arguments @('wrangler','whoami') -WorkingDirectory (Join-Path $RepoPath 'backend') -CaptureOutput
$whoamiText = ($whoamiOut | Out-String)
$whoamiText | Out-Host
if ($whoamiText -notmatch [regex]::Escape($CloudflareAccountId)) {
    Write-Warn "Cloudflare account ID $CloudflareAccountId was not found in 'wrangler whoami' output. Continuing anyway."
}

Write-Step 'Ensure KV namespace is configured'
$backendWranglerPath = Join-Path $RepoPath 'backend\wrangler.jsonc'
$backendWranglerRaw = Get-Content -LiteralPath $backendWranglerPath -Raw
if ($backendWranglerRaw -match 'REPLACE_WITH_KV_NAMESPACE_ID') {
    $kvOut = Run-External -FilePath 'npx' -Arguments @('wrangler','kv','namespace','create','APP_KV') -WorkingDirectory (Join-Path $RepoPath 'backend') -CaptureOutput
    $kvText = ($kvOut | Out-String)
    $kvText | Out-Host
    if ($kvText -match '"id"\s*:\s*"([a-f0-9]{32})"') {
        $kvId = $Matches[1]
        $backendWranglerRaw = $backendWranglerRaw -replace 'REPLACE_WITH_KV_NAMESPACE_ID', $kvId
        Set-Content -LiteralPath $backendWranglerPath -Value $backendWranglerRaw -Encoding UTF8
        Write-Ok "KV namespace configured: $kvId"
    }
    else {
        throw 'Could not parse KV namespace ID from wrangler output.'
    }
}
else {
    Write-Ok 'backend/wrangler.jsonc already has a KV namespace ID.'
}

Write-Step 'Deploy Worker'
$deployOut = Run-External -FilePath 'npx' -Arguments @('wrangler','deploy') -WorkingDirectory (Join-Path $RepoPath 'backend') -CaptureOutput
$deployText = ($deployOut | Out-String)
$deployText | Out-Host
if ($deployText -match 'https://[A-Za-z0-9._/-]+\.workers\.dev') {
    $workerUrl = $Matches[0]
}
else {
    throw 'Could not parse Worker URL from wrangler deploy output.'
}
Write-Ok "Worker URL: $workerUrl"

Write-Step 'Warm and test Worker'
$pricesUrl = "$workerUrl/api/prices"
$statusUrl = "$workerUrl/api/status"
try {
    Invoke-RestMethod -Uri $pricesUrl -Method Get | Out-Null
}
catch {
    Write-Warn "Price warmup failed. Continuing to status check. $($_.Exception.Message)"
}
$status = Invoke-RestMethod -Uri $statusUrl -Method Get
$status | ConvertTo-Json -Depth 8 | Out-Host
if (-not $status.ok) {
    throw 'Worker /api/status did not report ok = true.'
}

Write-Step 'Update frontend API_BASE'
$frontendPath = Join-Path $RepoPath 'frontend\index.html'
Set-WorkerUrlInFrontend -FrontendPath $frontendPath -WorkerUrl $workerUrl
Write-Ok 'frontend/index.html updated with the live Worker URL.'

Write-Step 'Prepare git repo'
if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    Run-External -FilePath 'git' -Arguments @('init') -WorkingDirectory $RepoPath
}
Run-External -FilePath 'git' -Arguments @('branch','-M',$ProductionBranch) -WorkingDirectory $RepoPath
Ensure-LineInFile -FilePath (Join-Path $RepoPath '.gitignore') -Line 'Cloudflare ID.txt'

Write-Step 'Create GitHub repo if needed'
$repoExists = $true
$null = Run-External -FilePath $ghPath -Arguments @('repo','view',"$GitHubOwner/$GitHubRepo") -CaptureOutput -AllowFailure
if ($LASTEXITCODE -ne 0) {
    $repoExists = $false
}
if (-not $repoExists) {
    if (-not $CreateRepoIfMissing) {
        throw "GitHub repo $GitHubOwner/$GitHubRepo does not exist. Rerun with -CreateRepoIfMissing to create it."
    }
    $visibilityFlag = if ($GitHubVisibility -eq 'private') { '--private' } else { '--public' }
    Run-External -FilePath $ghPath -Arguments @('repo','create',"$GitHubOwner/$GitHubRepo",$visibilityFlag,'--disable-wiki','--source',$RepoPath,'--remote','origin') -WorkingDirectory $RepoPath
}
else {
    $remoteUrl = "https://github.com/$GitHubOwner/$GitHubRepo.git"
    $originCheck = Run-External -FilePath 'git' -Arguments @('remote','get-url','origin') -WorkingDirectory $RepoPath -CaptureOutput -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        Run-External -FilePath 'git' -Arguments @('remote','add','origin',$remoteUrl) -WorkingDirectory $RepoPath
    }
    else {
        $existingOrigin = (($originCheck | Out-String).Trim())
        if ($existingOrigin -ne $remoteUrl) {
            Run-External -FilePath 'git' -Arguments @('remote','set-url','origin',$remoteUrl) -WorkingDirectory $RepoPath
        }
    }
}

Write-Step 'Commit local changes if needed'
$porcelain = Get-GitStatusPorcelain -WorkingDirectory $RepoPath
if ($porcelain.Count -gt 0) {
    Run-External -FilePath 'git' -Arguments @('add','.') -WorkingDirectory $RepoPath
    $porcelainAfterAdd = Get-GitStatusPorcelain -WorkingDirectory $RepoPath
    if ($porcelainAfterAdd.Count -gt 0) {
        Run-External -FilePath 'git' -Arguments @('commit','-m','Bootstrap GitHub + Cloudflare Pages/Workers deployment') -WorkingDirectory $RepoPath
    }
}
else {
    Write-Ok 'No local changes to commit.'
}

Write-Step 'Push branch to GitHub'
$pushArgs = @('push','-u','origin',$ProductionBranch)
$pushOutput = Run-External -FilePath 'git' -Arguments $pushArgs -WorkingDirectory $RepoPath -CaptureOutput -AllowFailure
$pushText = ($pushOutput | Out-String)
$pushText | Out-Host
if ($LASTEXITCODE -ne 0) {
    if ($OverwriteRemote) {
        Write-Warn 'Normal push failed. OverwriteRemote is set, forcing remote update with lease.'
        Run-External -FilePath 'git' -Arguments @('push','--force-with-lease','origin',$ProductionBranch) -WorkingDirectory $RepoPath
    }
    else {
        throw "git push failed. Rerun with -OverwriteRemote only if you intentionally want to replace the remote branch."
    }
}

Write-Step 'Set GitHub Actions secrets'
$cfToken = Get-CloudflareToken -ProvidedToken $CloudflareApiToken
Run-External -FilePath $ghPath -Arguments @('secret','set','CLOUDFLARE_API_TOKEN','--body',$cfToken,'--repo',"$GitHubOwner/$GitHubRepo") -WorkingDirectory $RepoPath
Run-External -FilePath $ghPath -Arguments @('secret','set','CLOUDFLARE_ACCOUNT_ID','--body',$CloudflareAccountId,'--repo',"$GitHubOwner/$GitHubRepo") -WorkingDirectory $RepoPath
Write-Ok 'GitHub Actions secrets set.'

if ($CreatePagesProject) {
    Write-Step 'Create or verify Cloudflare Pages project via API'
    $repoMetaJson = Run-External -FilePath $ghPath -Arguments @('api',"repos/$GitHubOwner/$GitHubRepo") -WorkingDirectory $RepoPath -CaptureOutput
    $repoMetaText = ($repoMetaJson | Out-String)
    $repoMeta = $repoMetaText | ConvertFrom-Json

    $pagesBase = "https://api.cloudflare.com/client/v4/accounts/$CloudflareAccountId/pages/projects"
    $existingProject = Invoke-CfApi -Method 'GET' -Uri "$pagesBase/$PagesProjectName" -Token $cfToken -AllowFailure
    if ($existingProject -and $existingProject.success) {
        Write-Ok "Pages project '$PagesProjectName' already exists."
    }
    else {
        $pagesBody = @{
            name = $PagesProjectName
            production_branch = $ProductionBranch
            build_config = @{
                build_command = 'exit 0'
                destination_dir = 'frontend'
                root_dir = '/'
            }
            source = @{
                type = 'github'
                config = @{
                    owner = $GitHubOwner
                    owner_id = "$($repoMeta.owner.id)"
                    repo_name = $GitHubRepo
                    repo_id = "$($repoMeta.id)"
                    production_branch = $ProductionBranch
                    deployments_enabled = $true
                    production_deployments_enabled = $true
                    pr_comments_enabled = $false
                    preview_deployment_setting = 'all'
                }
            }
        }

        try {
            $created = Invoke-CfApi -Method 'POST' -Uri $pagesBase -Token $cfToken -Body $pagesBody
            $created | ConvertTo-Json -Depth 10 | Out-Host
            if (-not $created.success) {
                throw 'Cloudflare Pages API returned success = false.'
            }
            Write-Ok "Pages project '$PagesProjectName' created."
        }
        catch {
            Write-Warn 'Pages project creation failed.'
            Write-Warn 'Most common cause: the Cloudflare GitHub app has not been granted access to this repository yet.'
            throw
        }
    }

    Write-Step 'Trigger Pages deployment with an empty commit'
    Run-External -FilePath 'git' -Arguments @('commit','--allow-empty','-m','Trigger initial Cloudflare Pages deployment') -WorkingDirectory $RepoPath
    Run-External -FilePath 'git' -Arguments @('push','origin',$ProductionBranch) -WorkingDirectory $RepoPath
}
else {
    Write-Warn 'Pages project creation was skipped. Rerun with -CreatePagesProject to create and link the Pages project via API.'
}

Write-Step 'Final checks'
Write-Host "Frontend repo     : https://github.com/$GitHubOwner/$GitHubRepo"
Write-Host "Worker health URL : $statusUrl"
if ($CreatePagesProject) {
    Write-Host "Pages dashboard   : https://dash.cloudflare.com/?to=/:account/workers-and-pages/view/$PagesProjectName"
}
Write-Ok 'Bootstrap completed.'
