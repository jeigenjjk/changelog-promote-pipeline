[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ChangelogPath,
  [Parameter(Mandatory)][string]$Version,
  [string]$PrTitle = ""
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ChangelogPath)) {
  Write-Host "No CHANGELOG.md at '$ChangelogPath' - skipping"
  exit 0
}

$lines = Get-Content $ChangelogPath
$unreleasedIdx = -1; $nextSectionIdx = -1; $hasContent = $false

for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^\s*##\s*\[Unreleased\]') { $unreleasedIdx = $i; continue }
  if ($unreleasedIdx -ge 0 -and $nextSectionIdx -lt 0 -and $lines[$i] -match '^\s*##\s*\[') {
    $nextSectionIdx = $i
  }
  if ($unreleasedIdx -ge 0 -and $nextSectionIdx -lt 0 -and $lines[$i].Trim() -and $lines[$i] -notmatch '^\s*##') {
    $hasContent = $true
  }
}

if ($unreleasedIdx -lt 0) { Write-Host "No [Unreleased] section found - skipping"; exit 0 }
if (-not $hasContent) { Write-Host "No entries under [Unreleased] - skipping"; exit 0 }

if ($PrTitle) {
  $PrTitle = $PrTitle -replace '[#\[\]`<>|*_~]', '' -replace '[\x00-\x1F]', ' ' -replace '\s{2,}', ' '
  $PrTitle = $PrTitle.Trim()
  if ($PrTitle.Length -gt 120) { $PrTitle = $PrTitle.Substring(0, 120) + '...' }
}

$versionHeader = if ($PrTitle) { "## [$Version] $PrTitle" } else { "## [$Version]" }
if ($nextSectionIdx -lt 0) { $nextSectionIdx = $lines.Count }

$newLines = @()
$newLines += $lines[0..$unreleasedIdx]
$newLines += ""
$newLines += $versionHeader
if (($unreleasedIdx + 1) -lt $nextSectionIdx) {
  $newLines += $lines[($unreleasedIdx + 1)..($nextSectionIdx - 1)]
}
if ($nextSectionIdx -lt $lines.Count) {
  $newLines += $lines[$nextSectionIdx..($lines.Count - 1)]
}

[System.IO.File]::WriteAllText($ChangelogPath, ($newLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host "CHANGELOG.md updated: promoted [Unreleased] to '$versionHeader'"
exit 0
