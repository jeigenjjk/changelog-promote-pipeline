# changelog-promote-pipeline

PoC: Reusable GitHub Actions workflow for changelog promotion.

Translates the AzDO `claude-changelog-promote` pipeline (definition 1207) to a reusable GitHub Actions workflow that any repo can call with a thin caller.

## What it does

1. On push to main that modifies CHANGELOG.md, promotes `[Unreleased]` entries to a versioned section
2. Auto-resolves CHANGELOG.md merge conflicts on open PRs

## Usage

Add this thin caller to your repo at `.github/workflows/changelog-promote.yml`:

```yaml
name: Changelog Promote
on:
  push:
    branches: [main]
    paths: ['CHANGELOG.md']
jobs:
  promote:
    if: "!contains(github.event.head_commit.message, '[skip ci]')"
    uses: jeigenjjk/changelog-promote-pipeline/.github/workflows/changelog-promote.yml@main
    with:
      trigger_sha: ${{ github.sha }}
    permissions:
      contents: write
      pull-requests: read
```

## Test Results

| Test | Description | Result |
|------|-------------|--------|
| T1 | PR merge with CHANGELOG entry | pending |
| T2 | PR merge without CHANGELOG change | pending |
| T3 | Promotion commit no re-trigger | pending |
| T4 | Auto-resolve PR conflict | pending |
| T5 | Multi-file conflict skipped | pending |
| T6 | Version format YYYYMMDD.N | pending |
| T7 | Branch protection bypass | pending |
| T8 | Concurrent merge queuing | pending |
| T9 | Script tests on ubuntu | pending |
| T10 | Custom version input | pending |
| T11 | Cross-repo workflow_call | pending |
| T12 | GITHUB_TOKEN fallback | pending |
| T13 | Empty unreleased skip | pending |
| T14 | Multiple categories | pending |
| T15 | Version monotonicity | pending |
| T16 | [skip ci] scope | pending |
