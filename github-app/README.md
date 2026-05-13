# GitHub App Setup

This directory contains everything needed to create and configure the **changelog-promote-bot** GitHub App.

## Why a GitHub App?

The changelog promotion workflow pushes commits directly to `main`. On repos with branch protection, `GITHUB_TOKEN` cannot bypass the rules. A GitHub App installed as a bypass actor in rulesets provides scoped, auditable, short-lived tokens for this purpose.

## Files

| File | Purpose |
|------|---------|
| `manifest.json` | App definition (permissions, webhook config). Version-controlled. |
| `create-app.html` | Opens GitHub's manifest registration flow. Human step. |
| `Register-GitHubApp.ps1` | Exchanges the registration code for credentials, stores secrets, installs App. |
| `.credentials.json` | Output of registration (App ID, private key). **Gitignored — never commit.** |

## Setup Flow

### Who does what

| Step | Done by | Tool |
|------|---------|------|
| 1. Open `create-app.html`, click button | Human (browser) | GitHub web UI |
| 2. Click "Create GitHub App" on GitHub | Human (browser) | GitHub web UI |
| 3. Copy `code` from redirect URL | Human (browser) | URL bar |
| 4. Run `Register-GitHubApp.ps1 -Code "..."` | Human or Claude | PowerShell |
| 5. Install App on account (URL provided by script) | Human (browser) | GitHub web UI |

### Detailed steps

1. Open `create-app.html` in a browser where you're signed in to GitHub
2. Click **"Create GitHub App on GitHub"** — GitHub shows a confirmation page
3. Click **"Create GitHub App for {account}"** — GitHub redirects to `localhost:9999`
4. The redirect page won't load (expected). Copy the `code=XXXXX` value from the URL bar
5. Run the registration script:
   ```
   pwsh -File github-app/Register-GitHubApp.ps1 -Code "PASTE_CODE_HERE"
   ```
6. The script will prompt you to install the App (opens a URL). Select repos and click Install.

### What the script does

1. **Exchanges** the registration code for App credentials via `POST /app-manifests/{code}/conversions`
2. **Saves** credentials to `.credentials.json` (gitignored)
3. **Stores** `CHANGELOG_APP_ID` and `CHANGELOG_APP_PRIVATE_KEY` as repository secrets on target repos
4. **Reports** the App ID, slug, and installation ID for use in workflows

## Recreating the App

If the App needs to be recreated (deleted and re-registered):

1. Delete the existing App: GitHub Settings > Developer settings > GitHub Apps > changelog-promote-bot > Delete
2. Delete `.credentials.json`
3. Follow the setup flow above
4. Re-add the App as a bypass actor in any rulesets that reference it

## Permissions

| Scope | Level | Why |
|-------|-------|-----|
| Contents | Read & Write | Push promotion commits to main, checkout cross-repo scripts |
| Pull Requests | Read & Write | List open PRs for auto-resolve, push to PR branches |
| Metadata | Read | Required by GitHub for all Apps |

## Production notes

For org-level deployment (`jjkeller-ts`):
- Change `manifest.json` URLs to point to the org's shared infrastructure repo
- Update `Register-GitHubApp.ps1` default `$TargetRepos` to org repos
- Store the private key in Azure Key Vault instead of (or in addition to) GitHub secrets
- Use org-level Actions secrets instead of per-repo secrets
