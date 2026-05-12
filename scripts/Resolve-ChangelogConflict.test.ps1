# Resolve-ChangelogConflict.test.ps1
# Integration tests using real git repos with real merge conflicts.
# Run: pwsh -File scripts/Resolve-ChangelogConflict.test.ps1
$ErrorActionPreference = "Stop"

$ScriptPath = Join-Path $PSScriptRoot "Resolve-ChangelogConflict.ps1"
$TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "changelog-resolve-tests-$(Get-Random)"
$passed = 0; $failed = 0; $total = 0

function New-TestRepo {
  param([string]$Name, [string]$BaseChangelog)
  $repoPath = Join-Path $TestDir $Name
  New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
  Push-Location $repoPath
  git init --initial-branch main 2>&1 | Out-Null
  git config user.email "test@test.com"
  git config user.name "Test"
  [System.IO.File]::WriteAllText("$repoPath/CHANGELOG.md", $BaseChangelog, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md
  git commit -m "initial" 2>&1 | Out-Null
  Pop-Location
  return $repoPath
}

function Set-BranchChangelog {
  param([string]$RepoPath, [string]$BranchName, [string]$Content)
  Push-Location $RepoPath
  git checkout -b $BranchName 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$RepoPath/CHANGELOG.md", $Content, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md
  git commit -m "update on $BranchName" 2>&1 | Out-Null
  Pop-Location
}

function Merge-MainAndResolve {
  <#
  .SYNOPSIS
    Merge main into current branch, creating a conflict, then run the resolve script.
  .OUTPUTS
    Resolved CHANGELOG.md content (string), or $null if merge succeeded without conflict.
  #>
  param([string]$RepoPath)
  Push-Location $RepoPath
  $mergeOutput = git merge main --no-commit --no-ff 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) {
    git merge --abort 2>&1 | Out-Null
    Pop-Location
    return $null  # no conflict
  }

  # Verify CHANGELOG.md is the only conflict
  $conflicted = @(git diff --name-only --diff-filter=U)
  if ($conflicted.Count -ne 1 -or $conflicted[0] -ne 'CHANGELOG.md') {
    git merge --abort 2>&1 | Out-Null
    Pop-Location
    throw "Unexpected conflicts: $($conflicted -join ', ')"
  }

  & $ScriptPath -ChangelogPath "$RepoPath/CHANGELOG.md"
  if ($LASTEXITCODE -ne 0) {
    git merge --abort 2>&1 | Out-Null
    Pop-Location
    throw "Resolve script failed with exit code $LASTEXITCODE"
  }

  $result = Get-Content "$RepoPath/CHANGELOG.md" -Raw
  git commit --no-edit -m "resolved" 2>&1 | Out-Null
  Pop-Location
  return $result
}

function Assert-Contains {
  param([string]$Content, [string]$Expected, [string]$Label)
  if ($Content -notmatch [regex]::Escape($Expected)) {
    throw "FAIL [$Label]: Expected content to contain '$Expected'"
  }
}

function Assert-NotContains {
  param([string]$Content, [string]$Expected, [string]$Label)
  if ($Content -match [regex]::Escape($Expected)) {
    throw "FAIL [$Label]: Expected content NOT to contain '$Expected'"
  }
}

function Run-Test {
  param([string]$Name, [scriptblock]$Block)
  $script:total++
  try {
    & $Block
    $script:passed++
    Write-Host "  PASS: $Name" -ForegroundColor Green
  } catch {
    $script:failed++
    Write-Host "  FAIL: $Name" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
  }
}

# ---------------------------------------------------------------------------
Write-Host "`nResolve-ChangelogConflict.ps1 Integration Tests" -ForegroundColor Cyan
Write-Host "================================================"
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null

# ---------------------------------------------------------------------------
# Test 1: Both sides have entries in the same category
# ---------------------------------------------------------------------------
Run-Test "Both sides add Fixed entries" {
  $base = @"
# Changelog

## [Unreleased]

### Fixed
- base entry

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Fixed
- base entry
- main's fix

## [1.0.0] old release
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Fixed
- base entry
- PR's fix

## [1.0.0] old release
"@

  $repo = New-TestRepo -Name "test1" -BaseChangelog $base
  Push-Location $repo
  # Create main's changes
  git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null

  # Create PR branch from the base commit (parent of main's update)
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "- main's fix" "main entry preserved"
  Assert-Contains $result "- PR's fix" "PR entry preserved"
  Assert-Contains $result "## [1.0.0] old release" "promoted sections preserved"
}

# ---------------------------------------------------------------------------
# Test 2: PR adds a new category that main doesn't have
# ---------------------------------------------------------------------------
Run-Test "PR adds new category (Added) that main lacks" {
  $base = @"
# Changelog

## [Unreleased]

### Fixed
- base fix

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Fixed
- base fix
- main's fix

## [1.0.0] old release
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Added
- new feature from PR

### Fixed
- base fix
- PR's fix

## [1.0.0] old release
"@

  $repo = New-TestRepo -Name "test2" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "### Added" "Added category present"
  Assert-Contains $result "- new feature from PR" "PR Added entry present"
  Assert-Contains $result "- main's fix" "main Fixed entry preserved"
  Assert-Contains $result "- PR's fix" "PR Fixed entry preserved"
}

# ---------------------------------------------------------------------------
# Test 3: Main's [Unreleased] is empty, PR has entries
# ---------------------------------------------------------------------------
Run-Test "Main unreleased empty, PR has entries" {
  $base = @"
# Changelog

## [Unreleased]

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

## [1.0.0] main promoted something

## [1.0.0] old release
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Added
- PR feature

## [1.0.0] old release
"@

  $repo = New-TestRepo -Name "test3" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "### Added" "Added category from PR present"
  Assert-Contains $result "- PR feature" "PR entry present"
  Assert-Contains $result "## [1.0.0] main promoted something" "main's promoted section preserved"
}

# ---------------------------------------------------------------------------
# Test 4: PR's [Unreleased] is empty, main has entries
# ---------------------------------------------------------------------------
Run-Test "PR unreleased empty, main has entries" {
  $base = @"
# Changelog

## [Unreleased]

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Fixed
- main's fix

## [1.0.0] old release
"@
  $prVersion = @"
# Changelog

## [Unreleased]

## [1.0.0] old release but PR changed this line
"@

  $repo = New-TestRepo -Name "test4" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "- main's fix" "main's entry preserved"
}

# ---------------------------------------------------------------------------
# Test 5: Duplicate entries are deduplicated
# ---------------------------------------------------------------------------
Run-Test "Duplicate entries deduplicated" {
  $base = @"
# Changelog

## [Unreleased]

### Fixed
- shared fix

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Fixed
- shared fix
- main-only fix

## [1.0.0] old release
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Fixed
- shared fix
- pr-only fix

## [1.0.0] old release
"@

  $repo = New-TestRepo -Name "test5" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "- main-only fix" "main-only entry present"
  Assert-Contains $result "- pr-only fix" "pr-only entry present"
  # shared fix should appear once (from main's version) — the PR's copy is deduplicated
  $matches = [regex]::Matches($result, [regex]::Escape("- shared fix"))
  if ($matches.Count -ne 1) {
    throw "FAIL: Expected 'shared fix' exactly once, found $($matches.Count) times"
  }
}

# ---------------------------------------------------------------------------
# Test 6: Multiple categories on both sides
# ---------------------------------------------------------------------------
Run-Test "Multiple categories both sides" {
  $base = @"
# Changelog

## [Unreleased]

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Added
- main feature

### Fixed
- main fix

## [1.0.0] old release
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Changed
- PR refactor

### Fixed
- PR fix

## [1.0.0] old release
"@

  $repo = New-TestRepo -Name "test6" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "### Added" "Added from main"
  Assert-Contains $result "- main feature" "main Added entry"
  Assert-Contains $result "### Changed" "Changed from PR"
  Assert-Contains $result "- PR refactor" "PR Changed entry"
  Assert-Contains $result "### Fixed" "Fixed category"
  Assert-Contains $result "- main fix" "main Fixed entry"
  Assert-Contains $result "- PR fix" "PR Fixed entry"
}

# ---------------------------------------------------------------------------
# Test 7: Promoted sections fully preserved
# ---------------------------------------------------------------------------
Run-Test "All promoted sections intact after resolve" {
  $base = @"
# Changelog

All notable changes.

## [Unreleased]

### Fixed
- base entry

## [20260429.3] fix: improve reliability

### Fixed
- old fix 1

## [20260429.2] feat: add audit skill

### Added
- old feature
"@
  $mainVersion = $base -replace "- base entry", "- base entry`n- main entry"
  $prVersion = $base -replace "- base entry", "- base entry`n- pr entry"

  $repo = New-TestRepo -Name "test7" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "## [20260429.3] fix: improve reliability" "version 3 preserved"
  Assert-Contains $result "## [20260429.2] feat: add audit skill" "version 2 preserved"
  Assert-Contains $result "- old fix 1" "old fix preserved"
  Assert-Contains $result "- old feature" "old feature preserved"
  Assert-Contains $result "- main entry" "main entry merged"
  Assert-Contains $result "- pr entry" "pr entry merged"
}

# ---------------------------------------------------------------------------
# Test 8: No conflict markers in output
# ---------------------------------------------------------------------------
Run-Test "No conflict markers in resolved output" {
  $base = @"
# Changelog

## [Unreleased]

### Added
- base feature

## [1.0.0] old
"@
  $mainVersion = $base -replace "- base feature", "- base feature`n- main feature"
  $prVersion = $base -replace "- base feature", "- base feature`n- pr feature"

  $repo = New-TestRepo -Name "test8" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-NotContains $result "<<<<<<<" "no opening conflict marker"
  Assert-NotContains $result "=======" "no separator marker"
  Assert-NotContains $result ">>>>>>>" "no closing conflict marker"
}

# ---------------------------------------------------------------------------
# Test 9: PR branch has no [Unreleased] header
# ---------------------------------------------------------------------------
Run-Test "PR has no [Unreleased] header — uses main's version" {
  $base = @"
# Changelog

## [Unreleased]

### Fixed
- base fix

## [1.0.0] old release
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Fixed
- base fix
- main fix

## [1.0.0] old release
"@
  # PR version has no [Unreleased] section at all
  $prVersion = @"
# Changelog

## [1.0.0] old release with PR note
"@

  $repo = New-TestRepo -Name "test9" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  # Should use main's version (it has [Unreleased])
  Assert-Contains $result "- main fix" "main's entries preserved"
  Assert-Contains $result "## [Unreleased]" "Unreleased header from main"
}

# ---------------------------------------------------------------------------
# Test 10: Main has no [Unreleased] header
# ---------------------------------------------------------------------------
Run-Test "Main has no [Unreleased] header — uses PR's version" {
  $base = @"
# Changelog

## [Unreleased]

### Fixed
- base fix

## [1.0.0] old release
"@
  # Main removed [Unreleased] entirely
  $mainVersion = @"
# Changelog

## [2.0.0] promoted everything

### Fixed
- base fix
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Added
- PR feature

### Fixed
- base fix
- PR fix

## [1.0.0] old release
"@

  $repo = New-TestRepo -Name "test10" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  # Should use PR's version (it has [Unreleased])
  Assert-Contains $result "- PR feature" "PR entries preserved"
  Assert-Contains $result "## [Unreleased]" "Unreleased header from PR"
}

# ---------------------------------------------------------------------------
# Test 11: Multi-line continuation entries
# ---------------------------------------------------------------------------
Run-Test "Multi-line continuation entries preserved" {
  $base = @"
# Changelog

## [Unreleased]

### Added
- base feature

## [1.0.0] old
"@
  $mainVersion = @"
# Changelog

## [Unreleased]

### Added
- base feature
- main feature with detail
  that continues on the next line

## [1.0.0] old
"@
  $prVersion = @"
# Changelog

## [Unreleased]

### Added
- base feature
- PR multi-line entry
  with continuation text here

## [1.0.0] old
"@

  $repo = New-TestRepo -Name "test11" -BaseChangelog $base
  Push-Location $repo; git checkout main 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $mainVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "main update" 2>&1 | Out-Null
  git checkout -b pr-branch HEAD~1 2>&1 | Out-Null
  [System.IO.File]::WriteAllText("$repo/CHANGELOG.md", $prVersion, [System.Text.UTF8Encoding]::new($false))
  git add CHANGELOG.md; git commit -m "pr update" 2>&1 | Out-Null
  Pop-Location

  Push-Location $repo; git checkout pr-branch 2>&1 | Out-Null; Pop-Location
  $result = Merge-MainAndResolve -RepoPath $repo

  Assert-Contains $result "- main feature with detail" "main multi-line entry"
  Assert-Contains $result "that continues on the next line" "main continuation line"
  Assert-Contains $result "- PR multi-line entry" "PR multi-line entry"
  Assert-Contains $result "with continuation text here" "PR continuation line"

  # Verify continuation lines stay attached to their parent bullet (positional check)
  if ($result -notmatch '- main feature with detail\r?\n\s+that continues on the next line') {
    throw "main continuation line detached from its parent bullet"
  }
  if ($result -notmatch '- PR multi-line entry\r?\n\s+with continuation text here') {
    throw "PR continuation line detached from its parent bullet"
  }
}

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------
Write-Host "`n================================================"
if ($failed -eq 0) {
  Write-Host "All $passed/$total tests passed" -ForegroundColor Green
} else {
  Write-Host "$passed passed, $failed failed out of $total" -ForegroundColor Red
}

# Cleanup temp repos
try { Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}

exit $failed
