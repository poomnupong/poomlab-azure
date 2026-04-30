# Branch Protection Setup Guide

This guide walks you through configuring branch protection on `main` for this repository. Because `main` is the production deployment branch for both Bicep infrastructure and NixOS host configurations, protecting it prevents accidental direct pushes and ensures all changes pass validation before merging.

---

## Why Branch Protection Matters for This Repo

| Risk without protection | Mitigation |
|---|---|
| A direct push to `main` could trigger `deploy-infra` or `deploy-nixos` without any code review | Branch protection requires PRs before merging |
| A bad Bicep template or broken NixOS flake could reach production | Required status checks (`ci-pr.yml`) catch errors before merge |
| An admin could bypass protections to "hotfix" quickly, accidentally breaking infra | "Do not allow bypassing" enforces checks for everyone including admins |
| History rewrites could corrupt the deployment audit trail | Linear history requirement prevents force-pushes |

---

## Step-by-step via GitHub UI

1. Go to **Settings → Branches** in the repository.
2. Under **Branch protection rules**, click **Add branch protection rule** (or **Edit** if a rule for `main` already exists).
3. In **Branch name pattern**, enter: `main`

### Required settings

#### Require a pull request before merging
- ✅ **Enable**: "Require a pull request before merging"
- Set **Required number of approvals** to `1` (recommended for a team; set to `0` for solo use if desired)
- ✅ **Dismiss stale pull request approvals when new commits are pushed** — ensures re-review after changes

#### Require status checks to pass before merging
- ✅ **Enable**: "Require status checks to pass before merging"
- ✅ **Require branches to be up to date before merging** — prevents stale PR merges

Click **Add required status checks** (the search box) and add the following job names. These job names must **exactly** match the `name:` field in the workflow YAML:

| Job name to search for | Workflow | Description |
|---|---|---|
| `Validate Bicep` | `ci-pr.yml` (`validate-infra` job) | Bicep lint + `az deployment what-if` |
| `Validate NixOS` | `ci-pr.yml` (`validate-nixos` job) | `nix flake check ./nixos` |

> **Note:** Status check names only appear in the search box **after** `ci-pr.yml` has run at least once on a pull request. If the checks don't appear yet, open a test PR (even a trivial README change) to trigger the workflow, then come back and add the checks.

#### Do not allow bypassing the above settings
- ✅ **Enable**: "Do not allow bypassing the above settings" — prevents admins from force-merging without checks

---

## Optional (Recommended) Settings

### Require linear history
- ✅ **Enable**: "Require linear history" — enforces squash or rebase merges, keeping `git log` clean and each commit independently deployable

### Restrict who can push to matching branches
If you want to lock down direct pushes entirely (even from admins who might accidentally push):
- ✅ **Restrict pushes that create matching branches** and leave the allow list empty

---

## Via GitHub CLI (scripted setup)

You can set up branch protection programmatically using the GitHub API. Replace `YOUR_ORG` and `YOUR_REPO` with your values:

```bash
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/YOUR_ORG/YOUR_REPO/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Validate Bicep",
      "Validate NixOS"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true
}
EOF
```

> **Tip:** Run `gh auth login` first if you haven't already. The token needs `repo` scope (or `admin:org` for org repos).

---

## Production Environment Protection

The `deploy-infra` and `deploy-nixos` workflows both use `environment: production`. You can add an extra layer of protection specifically for deployments:

1. Go to **Settings → Environments → production**
2. Add **Required reviewers** — at least one person must approve before the deploy job runs
3. Set a **Wait timer** (e.g. 5 minutes) to give you a window to cancel accidental deploys
4. Optionally restrict which branches can deploy to `production` (only `main` should deploy)

This means even after a PR is merged to `main`, the deployment itself is gated behind a manual approval step in the GitHub Actions UI.

---

## NixOS Deploy — No SSH Private Key Required

The `deploy-nixos` workflow uses a **GitOps pull model** rather than SSH/Colmena:

- **No SSH private key is needed.** The workflow uses the existing OIDC Azure login to invoke `az vm run-command invoke` on each target VM via the Azure control plane.
- **The `GITHUB_TOKEN` is passed ephemerally.** Each `az vm run-command invoke` call passes the built-in `GITHUB_TOKEN` as an environment variable so the VM can pull its NixOS configuration from this private repository. The token is scoped to the workflow run and expires when the run ends — it is never written to disk or stored on the VM.
- **The VM runs `nixos-rebuild switch --flake` itself.** It pulls the config directly from GitHub using the ephemeral token, applies the configuration, and the token is then discarded.

This means the only secrets required are the standard OIDC set (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) — the same secrets already used by `deploy-infra`.
