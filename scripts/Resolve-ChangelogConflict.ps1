[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ChangelogPath
)
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve-ChangelogConflict.ps1
#
# Called during an active git merge conflict where CHANGELOG.md is the only
# conflicted file. Uses git stage refs to read both sides:
#   Stage 2 (:2:) = "ours"   = PR branch (before merge)
#   Stage 3 (:3:) = "theirs" = main (authoritative base)
#
# Strategy: take main's full file as the base (it has the latest promoted
# sections), then merge the PR's [Unreleased] entries into main's [Unreleased].
# ---------------------------------------------------------------------------

# Keep a Changelog category order (for inserting new categories)
$CategoryOrder = @('Added', 'Changed', 'Deprecated', 'Removed', 'Fixed', 'Security')

function ConvertFrom-UnreleasedSection {
  <#
  .SYNOPSIS
    Extract [Unreleased] entries grouped by category from changelog content.
  .OUTPUTS
    Hashtable: @{ CategoryName = @(entry lines); _order = @(categories in file order); _headerIdx = int; _endIdx = int }
  #>
  param([string[]]$Lines)

  $result = @{ _order = [System.Collections.Generic.List[string]]::new(); _headerIdx = -1; _endIdx = -1 }
  $inUnreleased = $false
  $currentCategory = '_uncategorized'

  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $line = $Lines[$i]

    # Find [Unreleased] header
    if (-not $inUnreleased -and $line -match '^\s*##\s*\[Unreleased\]') {
      $result._headerIdx = $i
      $inUnreleased = $true
      continue
    }

    # End of [Unreleased]: next version section
    if ($inUnreleased -and $line -match '^\s*##\s*\[(?!Unreleased)') {
      $result._endIdx = $i
      break
    }

    if (-not $inUnreleased) { continue }

    # Category header (### Added, ### Fixed, etc.)
    if ($line -match '^\s*###\s+(.+)$') {
      $currentCategory = $Matches[1].Trim()
      if (-not $result._order.Contains($currentCategory)) {
        $result._order.Add($currentCategory)
      }
      if (-not $result.ContainsKey($currentCategory)) {
        $result[$currentCategory] = @()
      }
      continue
    }

    # Entry line (starts with - or *)
    if ($line -match '^\s*[-*]\s+') {
      if (-not $result.ContainsKey($currentCategory)) {
        $result[$currentCategory] = @()
        if (-not $result._order.Contains($currentCategory)) {
          $result._order.Add($currentCategory)
        }
      }
      $result[$currentCategory] += $line
      continue
    }

    # Continuation line (indented, belongs to previous entry) or blank line
    # Skip blank lines but keep continuation lines attached to their category
    if ($line.Trim() -and $currentCategory -and $result.ContainsKey($currentCategory)) {
      $result[$currentCategory] += $line
    }
  }

  # If we never found a next section, unreleased extends to end of file
  if ($inUnreleased -and $result._endIdx -lt 0) {
    $result._endIdx = $Lines.Count
  }

  return $result
}

function Merge-UnreleasedSections {
  <#
  .SYNOPSIS
    Merge PR's [Unreleased] entries into main's [Unreleased] section.
  .DESCRIPTION
    Takes main's full changelog as the base. For each category in the PR's
    unreleased section, appends entries that don't already exist in main's
    version. New categories are inserted in Keep a Changelog order.
  #>
  param(
    [string[]]$MainLines,
    [hashtable]$MainUnreleased,
    [hashtable]$PrUnreleased
  )

  # Collect entries to add per category
  $entriesToAdd = @{}
  $newCategories = @()

  foreach ($cat in $PrUnreleased._order) {
    if ($cat -eq '_uncategorized' -or $cat.StartsWith('_')) { continue }
    $prEntries = $PrUnreleased[$cat]
    if (-not $prEntries -or $prEntries.Count -eq 0) { continue }

    if ($MainUnreleased.ContainsKey($cat)) {
      # Category exists in main — find entries not already present (deduplicate by trimmed content)
      $mainSet = $MainUnreleased[$cat] | ForEach-Object { $_.Trim() }
      $newEntries = $prEntries | Where-Object { $_.Trim() -notin $mainSet }
      if ($newEntries -and @($newEntries).Count -gt 0) {
        $entriesToAdd[$cat] = @($newEntries)
      }
    } else {
      # New category from PR — track for insertion
      $newCategories += $cat
      $entriesToAdd[$cat] = @($prEntries)
    }
  }

  # Handle uncategorized entries from PR
  if ($PrUnreleased.ContainsKey('_uncategorized') -and $PrUnreleased['_uncategorized'].Count -gt 0) {
    $mainUncategorized = if ($MainUnreleased.ContainsKey('_uncategorized')) { $MainUnreleased['_uncategorized'] | ForEach-Object { $_.Trim() } } else { @() }
    $newUncategorized = $PrUnreleased['_uncategorized'] | Where-Object { $_.Trim() -notin $mainUncategorized }
    if ($newUncategorized -and @($newUncategorized).Count -gt 0) {
      $entriesToAdd['_uncategorized'] = @($newUncategorized)
    }
  }

  if ($entriesToAdd.Count -eq 0) {
    Write-Host "No new entries to merge from PR"
    return $MainLines
  }

  # Build the merged [Unreleased] section
  $headerIdx = $MainUnreleased._headerIdx
  $endIdx = $MainUnreleased._endIdx

  # Reconstruct: header + preamble, then categories with merged entries, then rest of file
  $output = [System.Collections.Generic.List[string]]::new()

  # Everything before [Unreleased] header (inclusive)
  for ($i = 0; $i -le $headerIdx; $i++) {
    $output.Add($MainLines[$i])
  }

  # Build merged category content
  # Start with main's existing categories and append PR entries
  $emittedCategories = [System.Collections.Generic.List[string]]::new()

  # Walk through main's unreleased section, injecting PR entries after each category's entries
  $i = $headerIdx + 1
  while ($i -lt $endIdx) {
    $line = $MainLines[$i]

    if ($line -match '^\s*###\s+(.+)$') {
      $cat = $Matches[1].Trim()
      $emittedCategories.Add($cat)
      $output.Add($line)
      $i++

      # Emit main's entries for this category
      while ($i -lt $endIdx -and $MainLines[$i] -notmatch '^\s*###\s+') {
        $output.Add($MainLines[$i])
        $i++
      }

      # Append PR's entries for this category (if any)
      if ($entriesToAdd.ContainsKey($cat)) {
        foreach ($entry in $entriesToAdd[$cat]) {
          $output.Add($entry)
        }
        $entriesToAdd.Remove($cat)
      }
    } else {
      $output.Add($line)
      $i++
    }
  }

  # Insert new categories from PR (not yet emitted) in Keep a Changelog order
  $remainingCats = $entriesToAdd.Keys | Where-Object { -not $_.StartsWith('_') -and $_ -notin $emittedCategories }
  $sortedRemaining = $remainingCats | Sort-Object { $idx = $CategoryOrder.IndexOf($_); if ($idx -lt 0) { 999 } else { $idx } }

  foreach ($cat in $sortedRemaining) {
    # Add blank line before new category if last line isn't blank
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Trim()) {
      $output.Add("")
    }
    $output.Add("### $cat")
    foreach ($entry in $entriesToAdd[$cat]) {
      $output.Add($entry)
    }
  }

  # Append uncategorized entries (if any)
  if ($entriesToAdd.ContainsKey('_uncategorized')) {
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Trim()) {
      $output.Add("")
    }
    foreach ($entry in $entriesToAdd['_uncategorized']) {
      $output.Add($entry)
    }
  }

  # Ensure blank line before next version section
  if ($endIdx -lt $MainLines.Count) {
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Trim()) {
      $output.Add("")
    }
  }

  # Everything from the next version section onward
  for ($i = $endIdx; $i -lt $MainLines.Count; $i++) {
    $output.Add($MainLines[$i])
  }

  return $output.ToArray()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Convert absolute path to repo-relative Unix-style path for git show :N: syntax
$gitRoot = (git rev-parse --show-toplevel).Trim() -replace '\\', '/'
$absNormalized = ($ChangelogPath -replace '\\', '/').TrimEnd('/')
$relPath = $absNormalized
if ($absNormalized.StartsWith($gitRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  $relPath = $absNormalized.Substring($gitRoot.Length).TrimStart('/')
}
Write-Host "Resolving conflict for: $relPath (git root: $gitRoot)"

# Read both sides from git merge stages
$oursContent = git show ":2:${relPath}" 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to read stage 2 (ours/PR) of ${relPath}: $oursContent"
}
$theirsContent = git show ":3:${relPath}" 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to read stage 3 (theirs/main) of ${relPath}: $theirsContent"
}

# Split on LF; any trailing \r from CRLF input is handled by .Trim() in deduplication.
# Output is always written with LF line endings (normalized from CRLF if present).
$oursLines = $oursContent -split "`n"
$theirsLines = $theirsContent -split "`n"

Write-Host "Ours (PR): $($oursLines.Count) lines"
Write-Host "Theirs (main): $($theirsLines.Count) lines"

# Parse [Unreleased] from both
$prUnreleased = ConvertFrom-UnreleasedSection -Lines $oursLines
$mainUnreleased = ConvertFrom-UnreleasedSection -Lines $theirsLines

if ($prUnreleased._headerIdx -lt 0) {
  Write-Host "PR branch has no [Unreleased] section — using main's version as-is"
  [System.IO.File]::WriteAllText($ChangelogPath, ($theirsLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
  git add $ChangelogPath
  exit 0
}

if ($mainUnreleased._headerIdx -lt 0) {
  Write-Host "Main has no [Unreleased] section — using PR's version as-is"
  [System.IO.File]::WriteAllText($ChangelogPath, ($oursLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
  git add $ChangelogPath
  exit 0
}

# Merge: use main as base, inject PR's entries
$merged = Merge-UnreleasedSections -MainLines $theirsLines -MainUnreleased $mainUnreleased -PrUnreleased $prUnreleased

[System.IO.File]::WriteAllText($ChangelogPath, ($merged -join "`n"), [System.Text.UTF8Encoding]::new($false))
git add $ChangelogPath

$prCatCount = ($prUnreleased._order | Where-Object { -not $_.StartsWith('_') }).Count
$prEntryCount = ($prUnreleased.Keys | Where-Object { -not $_.StartsWith('_') } | ForEach-Object { $prUnreleased[$_].Count } | Measure-Object -Sum).Sum
Write-Host "Resolved: merged $prEntryCount entries across $prCatCount categories from PR into main's changelog"
exit 0
