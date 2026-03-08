param(
    [string]$RepoPath = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [string]$GitHubOwner = "",
    [string]$GitHubRepo = "",
    [ValidateSet("public","private")]
    [string]$GitHubVisibility = "public",
    [string]$PagesProjectName = "",
    [string]$CloudflareAccountId = $env:CLOUDFLARE_ACCOUNT_ID,
    [string]$CloudflareApiToken = $env:CLOUDFLARE_API_TOKEN,
    [switch]$SkipGitHub,
    [switch]$SkipOpenDashboards,
    [switch]$SkipWorkflowSecrets
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host "" 
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [switch]$AllowFailure,
        [switch]$Quiet
    )

    Push-Location $WorkingDirectory
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $text = (($output | Out-String).Trim())
    if (-not $Quiet -and $text) {
        Write-Host $text
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')`n$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

function Replace-InFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $content = Get-Content -Raw -LiteralPath $Path
    $updated = [regex]::Replace($content, $Pattern, $Replacement)
    if ($updated -ne $content) {
        Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8
        return $true
    }
    return $false
}

function Get-PlaceholderState {
    param([string]$Path, [string]$Token)
    $content = Get-Content -Raw -LiteralPath $Path
    return $content.Contains($Token)
}

function Ensure-GitIdentity {
    param([string]$WorkingDirectory)

    $gitName = (Invoke-External -FilePath git -Arguments @("config", "user.name") -WorkingDirectory $WorkingDirectory -AllowFailure -Quiet).Output
    $gitEmail = (Invoke-External -FilePath git -Arguments @("config", "user.email") -WorkingDirectory $WorkingDirectory -AllowFailure -Quiet).Output

    if ([string]::IsNullOrWhiteSpace($gitName)) {
        $gitName = Read-Host "Enter git user.name"
        if ([string]::IsNullOrWhiteSpace($gitName)) { throw "git user.name is required." }
        Invoke-External -FilePath git -Arguments @("config", "user.name", $gitName) -WorkingDirectory $WorkingDirectory | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($gitEmail)) {
        $gitEmail = Read-Host "Enter git user.email"
        if ([string]::IsNullOrWhiteSpace($gitEmail)) { throw "git user.email is required." }
        Invoke-External -FilePath git -Arguments @("config", "user.email", $gitEmail) -WorkingDirectory $WorkingDirectory | Out-Null
    }
}

function Ensure-GitRepo {
    param([string]$WorkingDirectory)

    if (-not (Test-Path (Join-Path $WorkingDirectory ".git"))) {
        Invoke-External -FilePath git -Arguments @("init") -WorkingDirectory $WorkingDirectory | Out-Null
    }

    Ensure-GitIdentity -WorkingDirectory $WorkingDirectory
    Invoke-External -FilePath git -Arguments @("branch", "-M", "main") -WorkingDirectory $WorkingDirectory | Out-Null
}

function Get-GitStatusPorcelain {
    param([string]$WorkingDirectory)
    return (Invoke-External -FilePath git -Arguments @("status", "--porcelain") -WorkingDirectory $WorkingDirectory -Quiet).Output
}

function Commit-IfNeeded {
    param([string]$WorkingDirectory, [string]$Message)
    $status = Get-GitStatusPorcelain -WorkingDirectory $WorkingDirectory
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        Invoke-External -FilePath git -Arguments @("add", ".") -WorkingDirectory $WorkingDirectory | Out-Null
        Invoke-External -FilePath git -Arguments @("commit", "-m", $Message) -WorkingDirectory $WorkingDirectory | Out-Null
    }
    else {
        Write-Info "No git changes to commit."
    }
}

function Get-WranglerWhoAmI {
    param([string]$WorkingDirectory)
    return Invoke-External -FilePath npx -Arguments @("wrangler", "whoami") -WorkingDirectory $WorkingDirectory -AllowFailure
}

function Ensure-CloudflareAuth {
    param([string]$WorkingDirectory)

    if (-not [string]::IsNullOrWhiteSpace($CloudflareApiToken)) {
        $env:CLOUDFLARE_API_TOKEN = $CloudflareApiToken
        Write-Info "Using CLOUDFLARE_API_TOKEN from script parameter or environment."
    }

    if (-not [string]::IsNullOrWhiteSpace($CloudflareAccountId)) {
        $env:CLOUDFLARE_ACCOUNT_ID = $CloudflareAccountId
        Write-Info "Using CLOUDFLARE_ACCOUNT_ID from script parameter or environment."
    }

    $whoami = Get-WranglerWhoAmI -WorkingDirectory $WorkingDirectory
    if ($whoami.ExitCode -ne 0) {
        Write-Warn "Wrangler is not authenticated yet. Browser login will open now."
        Invoke-External -FilePath npx -Arguments @("wrangler", "login") -WorkingDirectory $WorkingDirectory | Out-Null
        $whoami = Get-WranglerWhoAmI -WorkingDirectory $WorkingDirectory
        if ($whoami.ExitCode -ne 0) {
            throw "Wrangler login did not succeed."
        }
    }

    if ([string]::IsNullOrWhiteSpace($CloudflareAccountId)) {
        $match = [regex]::Match($whoami.Output, '(?i)\b[0-9a-f]{32}\b')
        if ($match.Success) {
            $script:CloudflareAccountId = $match.Value
            $env:CLOUDFLARE_ACCOUNT_ID = $match.Value
            Write-Info "Detected Cloudflare account ID from wrangler whoami output."
        }
    }

    if ([string]::IsNullOrWhiteSpace($CloudflareAccountId)) {
        $script:CloudflareAccountId = Read-Host "Enter your Cloudflare Account ID for GitHub Actions secrets"
        if ([string]::IsNullOrWhiteSpace($script:CloudflareAccountId)) {
            throw "Cloudflare Account ID is required for the GitHub Actions workflow secrets."
        }
        $env:CLOUDFLARE_ACCOUNT_ID = $script:CloudflareAccountId
    }
}

function Ensure-KvNamespace {
    param(
        [string]$WorkingDirectory,
        [string]$BackendConfigPath
    )

    if (-not (Get-PlaceholderState -Path $BackendConfigPath -Token "REPLACE_WITH_KV_NAMESPACE_ID")) {
        Write-Info "KV namespace ID already present in backend/wrangler.jsonc."
        return
    }

    $result = Invoke-External -FilePath npx -Arguments @("wrangler", "kv", "namespace", "create", "APP_KV", "--config", $BackendConfigPath) -WorkingDirectory $WorkingDirectory
    $match = [regex]::Match($result.Output, '(?i)\b[0-9a-f]{32}\b')
    if (-not $match.Success) {
        throw "Could not parse the KV namespace ID from Wrangler output."
    }

    $namespaceId = $match.Value
    $escapedId = [regex]::Escape("REPLACE_WITH_KV_NAMESPACE_ID")
    $changed = Replace-InFile -Path $BackendConfigPath -Pattern $escapedId -Replacement $namespaceId
    if (-not $changed) {
        throw "Failed to write the KV namespace ID into backend/wrangler.jsonc."
    }

    Write-Info "KV namespace bound with ID: $namespaceId"
}

function Check-Backend {
    param([string]$WorkingDirectory, [string]$BackendConfigPath)
    Invoke-External -FilePath npx -Arguments @("wrangler", "check", "--config", $BackendConfigPath) -WorkingDirectory $WorkingDirectory | Out-Null
}

function Deploy-Worker {
    param([string]$WorkingDirectory, [string]$BackendConfigPath)

    $deploy = Invoke-External -FilePath npx -Arguments @("wrangler", "deploy", "--config", $BackendConfigPath) -WorkingDirectory $WorkingDirectory
    $match = [regex]::Match($deploy.Output, 'https://[^\s''\"]+\.workers\.dev')
    if (-not $match.Success) {
        $match = [regex]::Match($deploy.Output, 'https://[^\s''\"]+')
    }
    if (-not $match.Success) {
        throw "Could not parse the deployed Worker URL from Wrangler output."
    }

    return $match.Value.TrimEnd('/')
}

function Test-WorkerStatus {
    param([string]$WorkerBaseUrl)

    $statusUrl = "$WorkerBaseUrl/api/status"
    Write-Info "Testing Worker health: $statusUrl"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $statusUrl -TimeoutSec 30
    }
    catch {
        throw "Worker health check failed at $statusUrl. $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        throw "Worker health check returned no response."
    }

    if ($response.ok -ne $true) {
        throw "Worker health check responded, but .ok was not true."
    }
}

function Update-FrontendApiBase {
    param([string]$FrontendIndexPath, [string]$WorkerBaseUrl)
    $replacement = 'const API_BASE = "' + $WorkerBaseUrl + '";'
    $changed = Replace-InFile -Path $FrontendIndexPath -Pattern 'const API_BASE = ".*?";' -Replacement $replacement
    if (-not $changed) {
        throw "Failed to update API_BASE in frontend/index.html."
    }
}

function Get-GitHubAuthenticatedUser {
    param([string]$WorkingDirectory)
    $result = Invoke-External -FilePath gh -Arguments @("auth", "status") -WorkingDirectory $WorkingDirectory -AllowFailure -Quiet
    if ($result.ExitCode -ne 0) {
        Write-Warn "GitHub CLI is not authenticated. The script will start gh auth login."
        Invoke-External -FilePath gh -Arguments @("auth", "login") -WorkingDirectory $WorkingDirectory | Out-Null
    }

    $user = Invoke-External -FilePath gh -Arguments @("api", "user", "--jq", ".login") -WorkingDirectory $WorkingDirectory -AllowFailure -Quiet
    if ($user.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($user.Output)) {
        throw "Could not determine the authenticated GitHub username via gh api user."
    }
    return $user.Output.Trim()
}

function Ensure-OriginAndPush {
    param(
        [string]$WorkingDirectory,
        [string]$Owner,
        [string]$Repo,
        [string]$Visibility
    )

    $origin = Invoke-External -FilePath git -Arguments @("remote", "get-url", "origin") -WorkingDirectory $WorkingDirectory -AllowFailure -Quiet
    if ($origin.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($origin.Output)) {
        Write-Info "Git remote origin already exists: $($origin.Output.Trim())"
        Invoke-External -FilePath git -Arguments @("push", "-u", "origin", "main") -WorkingDirectory $WorkingDirectory | Out-Null
        return
    }

    $repoFullName = "$Owner/$Repo"
    $visibilitySwitch = if ($Visibility -eq "private") { "--private" } else { "--public" }

    Invoke-External -FilePath gh -Arguments @(
        "repo", "create", $repoFullName,
        $visibilitySwitch,
        "--source", ".",
        "--remote", "origin",
        "--push",
        "--description", "Coin Compass static frontend plus Cloudflare Worker backend"
    ) -WorkingDirectory $WorkingDirectory | Out-Null
}

function Set-GitHubWorkflowSecrets {
    param(
        [string]$WorkingDirectory,
        [string]$Owner,
        [string]$Repo,
        [string]$AccountId,
        [string]$ApiToken
    )

    if ($SkipWorkflowSecrets) {
        Write-Warn "Skipping GitHub Actions secrets by request."
        return
    }

    if ([string]::IsNullOrWhiteSpace($ApiToken)) {
        $ApiToken = Read-Host "Enter Cloudflare API Token for GitHub Actions secret CLOUDFLARE_API_TOKEN"
        if ([string]::IsNullOrWhiteSpace($ApiToken)) {
            Write-Warn "No Cloudflare API token entered. GitHub workflow secrets were not set."
            return
        }
    }

    if ([string]::IsNullOrWhiteSpace($AccountId)) {
        $AccountId = Read-Host "Enter Cloudflare Account ID for GitHub Actions secret CLOUDFLARE_ACCOUNT_ID"
        if ([string]::IsNullOrWhiteSpace($AccountId)) {
            Write-Warn "No Cloudflare account ID entered. GitHub workflow secrets were not set."
            return
        }
    }

    $repoFullName = "$Owner/$Repo"

    Invoke-External -FilePath gh -Arguments @("secret", "set", "CLOUDFLARE_API_TOKEN", "--repo", $repoFullName, "--body", $ApiToken) -WorkingDirectory $WorkingDirectory | Out-Null
    Invoke-External -FilePath gh -Arguments @("secret", "set", "CLOUDFLARE_ACCOUNT_ID", "--repo", $repoFullName, "--body", $AccountId) -WorkingDirectory $WorkingDirectory | Out-Null
}

function Open-NextUrls {
    param([string]$RepoUrl, [string]$PagesProjectName)

    if ($SkipOpenDashboards) {
        return
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoUrl)) {
            Start-Process $RepoUrl | Out-Null
        }
        Start-Process "https://dash.cloudflare.com/?to=/:account/workers-and-pages" | Out-Null
    }
    catch {
        Write-Warn "Could not auto-open the browser windows."
    }

    Write-Host "" 
    Write-Host "Cloudflare Pages connection values:" -ForegroundColor Green
    Write-Host "  Project name           : $PagesProjectName"
    Write-Host "  Production branch      : main"
    Write-Host "  Framework preset       : None"
    Write-Host "  Build command          : leave empty"
    Write-Host "  Build output directory : frontend"
    Write-Host "  Root directory         : /"
}

Write-Step "Validate prerequisites"
Require-Command git
Require-Command node
Require-Command npm
Require-Command npx

if (-not $SkipGitHub) {
    Require-Command gh
}

$RepoPath = [System.IO.Path]::GetFullPath($RepoPath)
if (-not (Test-Path $RepoPath)) {
    throw "Repo path not found: $RepoPath"
}

$frontendIndexPath = Join-Path $RepoPath "frontend\index.html"
$backendConfigPath = Join-Path $RepoPath "backend\wrangler.jsonc"
$backendPackagePath = Join-Path $RepoPath "backend\package.json"

foreach ($requiredPath in @($frontendIndexPath, $backendConfigPath, $backendPackagePath)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required file not found: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($GitHubRepo)) {
    $GitHubRepo = Split-Path $RepoPath -Leaf
}

if ([string]::IsNullOrWhiteSpace($PagesProjectName)) {
    $PagesProjectName = $GitHubRepo
}

Write-Step "Install backend dependencies"
Invoke-External -FilePath npm -Arguments @("install") -WorkingDirectory (Join-Path $RepoPath "backend") | Out-Null

Write-Step "Authenticate Wrangler"
Ensure-CloudflareAuth -WorkingDirectory $RepoPath

Write-Step "Create or reuse KV namespace"
Ensure-KvNamespace -WorkingDirectory $RepoPath -BackendConfigPath $backendConfigPath

Write-Step "Check backend"
Check-Backend -WorkingDirectory $RepoPath -BackendConfigPath $backendConfigPath

Write-Step "Deploy Worker"
$workerUrl = Deploy-Worker -WorkingDirectory $RepoPath -BackendConfigPath $backendConfigPath
Write-Host "Worker URL: $workerUrl" -ForegroundColor Green

Write-Step "Test Worker health"
Test-WorkerStatus -WorkerBaseUrl $workerUrl

Write-Step "Update frontend API base"
Update-FrontendApiBase -FrontendIndexPath $frontendIndexPath -WorkerBaseUrl $workerUrl

Write-Step "Prepare git repository"
Ensure-GitRepo -WorkingDirectory $RepoPath
Commit-IfNeeded -WorkingDirectory $RepoPath -Message "Bootstrap GitHub and Cloudflare deployment"

$repoUrl = ""
if (-not $SkipGitHub) {
    Write-Step "Create or push GitHub repository"
    if ([string]::IsNullOrWhiteSpace($GitHubOwner)) {
        $GitHubOwner = Get-GitHubAuthenticatedUser -WorkingDirectory $RepoPath
    }

    Ensure-OriginAndPush -WorkingDirectory $RepoPath -Owner $GitHubOwner -Repo $GitHubRepo -Visibility $GitHubVisibility
    $repoUrl = "https://github.com/$GitHubOwner/$GitHubRepo"

    Write-Step "Set GitHub Actions secrets"
    Set-GitHubWorkflowSecrets -WorkingDirectory $RepoPath -Owner $GitHubOwner -Repo $GitHubRepo -AccountId $CloudflareAccountId -ApiToken $CloudflareApiToken
}
else {
    Write-Warn "Skipping GitHub repo creation and push by request."
}

Write-Step "Finish with Cloudflare Pages Git integration"
Open-NextUrls -RepoUrl $repoUrl -PagesProjectName $PagesProjectName

Write-Host "" 
Write-Host "Completed." -ForegroundColor Green
Write-Host "Worker deployed and frontend updated." -ForegroundColor Green
Write-Host "Use the opened Cloudflare Pages screen to connect the GitHub repo." -ForegroundColor Green
Write-Host "Do NOT use wrangler pages deploy if you want Git integration later, because Git-integrated Pages projects cannot switch from Direct Upload afterward." -ForegroundColor Yellow
