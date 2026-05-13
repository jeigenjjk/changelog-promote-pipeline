<#
.SYNOPSIS
    Completes GitHub App registration from a manifest flow code.

.DESCRIPTION
    After creating a GitHub App via the manifest flow (create-app.html),
    this script exchanges the registration code for App credentials,
    saves them locally, stores them as repository secrets, and installs
    the App on target repositories.

.PARAMETER Code
    The registration code from the GitHub redirect URL (code=XXXXX).

.PARAMETER TargetRepos
    Repositories to store secrets on and install the App.
    Defaults to the changelog-promote target repos.

.PARAMETER CredentialsPath
    Where to save the credentials JSON. Defaults to github-app/.credentials.json.

.EXAMPLE
    pwsh -File github-app/Register-GitHubApp.ps1 -Code "v1.abc123def456"

.EXAMPLE
    pwsh -File github-app/Register-GitHubApp.ps1 -Code "v1.abc123" -TargetRepos @("myorg/repo-a","myorg/repo-b")
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Code,

    [string[]]$TargetRepos = @(
        "jeigenjjk/changelog-promote-target-unrestricted",
        "jeigenjjk/changelog-promote-target-restricted"
    ),

    [string]$CredentialsPath = (Join-Path $PSScriptRoot ".credentials.json")
)

$ErrorActionPreference = "Stop"

# --- Step 1: Exchange code for credentials ---
Write-Host "`n=== Step 1: Exchanging registration code for App credentials ===" -ForegroundColor Cyan

$response = gh api --method POST "/app-manifests/$Code/conversions" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to exchange code. Has it expired? (Codes expire after 1 hour)`n$response"
}

$credentials = $response | ConvertFrom-Json

$saved = [ordered]@{
    app_id         = $credentials.id
    app_slug       = $credentials.slug
    app_name       = $credentials.name
    client_id      = $credentials.client_id
    pem            = $credentials.pem
    webhook_secret = $credentials.webhook_secret
    owner          = $credentials.owner.login
    html_url       = $credentials.html_url
    created_at     = $credentials.created_at
}

# Save credentials locally (gitignored)
$saved | ConvertTo-Json -Depth 5 | Set-Content -Path $CredentialsPath -Encoding UTF8
Write-Host "  Credentials saved to: $CredentialsPath" -ForegroundColor Green
Write-Host "  App Name: $($saved.app_name)"
Write-Host "  App ID:   $($saved.app_id)"
Write-Host "  Slug:     $($saved.app_slug)"
Write-Host "  Owner:    $($saved.owner)"

# --- Step 2: Get installation ID ---
Write-Host "`n=== Step 2: Getting App installation ===" -ForegroundColor Cyan

# Authenticate as the App to list installations
$jwtHeader = @{ alg = "RS256"; typ = "JWT" } | ConvertTo-Json -Compress
$now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$jwtPayload = @{ iat = $now - 60; exp = $now + 300; iss = $saved.app_id } | ConvertTo-Json -Compress

function ConvertTo-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$headerB64  = ConvertTo-Base64Url([System.Text.Encoding]::UTF8.GetBytes($jwtHeader))
$payloadB64 = ConvertTo-Base64Url([System.Text.Encoding]::UTF8.GetBytes($jwtPayload))
$unsigned   = "$headerB64.$payloadB64"

$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem($saved.pem)
$sigBytes = $rsa.SignData(
    [System.Text.Encoding]::UTF8.GetBytes($unsigned),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)
$jwt = "$unsigned.$(ConvertTo-Base64Url $sigBytes)"

# Check if the App is already installed
$installationsJson = gh api "/app/installations" --jq '.[].id' -H "Authorization: Bearer $jwt" 2>&1
$installationId = $null
if ($LASTEXITCODE -eq 0 -and $installationsJson) {
    $installationId = ($installationsJson -split "`n")[0].Trim()
    Write-Host "  Found existing installation: $installationId" -ForegroundColor Green
}
else {
    Write-Host "  No installation found yet. You'll need to install the App (Step 3)." -ForegroundColor Yellow
}

# --- Step 3: Install the App ---
Write-Host "`n=== Step 3: Installing App on account ===" -ForegroundColor Cyan

if (-not $installationId) {
    $installUrl = "https://github.com/apps/$($saved.app_slug)/installations/new"
    Write-Host "  The App needs to be installed on your account."
    Write-Host "  Open this URL in your browser to install:" -ForegroundColor Yellow
    Write-Host "    $installUrl" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Select 'All repositories' or choose specific repos, then click Install."
    Write-Host "  Press Enter after installing..." -ForegroundColor Yellow
    Read-Host

    # Re-check installation
    $installationsJson = gh api "/app/installations" --jq '.[].id' -H "Authorization: Bearer $jwt" 2>&1
    if ($LASTEXITCODE -eq 0 -and $installationsJson) {
        $installationId = ($installationsJson -split "`n")[0].Trim()
        Write-Host "  Installation confirmed: $installationId" -ForegroundColor Green
    }
    else {
        Write-Warning "Could not confirm installation. You may need to install manually later."
    }
}

# --- Step 4: Store secrets on target repos ---
Write-Host "`n=== Step 4: Storing App credentials as repository secrets ===" -ForegroundColor Cyan

# Write PEM to a temp file for secret storage (avoids shell escaping issues)
$pemTempFile = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($pemTempFile, $saved.pem, [System.Text.UTF8Encoding]::new($false))

    foreach ($repo in $TargetRepos) {
        Write-Host "  Setting secrets on $repo..."

        gh secret set CHANGELOG_APP_ID --repo $repo --body "$($saved.app_id)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to set CHANGELOG_APP_ID on $repo (repo may not exist yet)"
            continue
        }

        # Use < redirection to avoid shell escaping issues with PEM content
        $pemContent = Get-Content $pemTempFile -Raw
        $pemContent | gh secret set CHANGELOG_APP_PRIVATE_KEY --repo $repo --body - 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to set CHANGELOG_APP_PRIVATE_KEY on $repo"
            continue
        }

        Write-Host "    CHANGELOG_APP_ID and CHANGELOG_APP_PRIVATE_KEY set" -ForegroundColor Green
    }

    # Also set on the pipeline repo itself (for reference / self-test)
    $pipelineRepo = "jeigenjjk/changelog-promote-pipeline"
    Write-Host "  Setting secrets on $pipelineRepo..."
    gh secret set CHANGELOG_APP_ID --repo $pipelineRepo --body "$($saved.app_id)" 2>&1 | Out-Null
    $pemContent | gh secret set CHANGELOG_APP_PRIVATE_KEY --repo $pipelineRepo --body - 2>&1 | Out-Null
    Write-Host "    CHANGELOG_APP_ID and CHANGELOG_APP_PRIVATE_KEY set" -ForegroundColor Green
}
finally {
    Remove-Item $pemTempFile -Force -ErrorAction SilentlyContinue
}

# --- Summary ---
Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  App Name:        $($saved.app_name)"
Write-Host "  App ID:          $($saved.app_id)"
Write-Host "  App Slug:        $($saved.app_slug)"
Write-Host "  Installation ID: $installationId"
Write-Host "  Credentials:     $CredentialsPath"
Write-Host "  Secrets set on:  $($TargetRepos -join ', '), $pipelineRepo"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Create the target repos (if not yet created)"
Write-Host "    2. Add the App as a bypass actor in branch protection rulesets"
Write-Host "    3. Update thin callers to pass App credentials as secrets"
Write-Host "    4. Run end-to-end tests"
Write-Host ""
