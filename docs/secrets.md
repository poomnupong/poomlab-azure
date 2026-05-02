# Repository Secrets Reference

This document describes every repository secret required by the GitHub Actions
workflows in this repository.  All secrets are stored under
**Settings → Secrets and variables → Actions → Secrets**.

---

## Azure OIDC secrets (required by `deploy-infra` and `deploy-nixos`)

These four secrets are created by the [bootstrap script](../bootstrap/bootstrap.sh)
and enable workflows to authenticate to Azure via OpenID Connect — no
long-lived password or certificate is stored.

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `AZURE_CLIENT_ID`        | Application (client) ID of the Entra ID app registration |
| `AZURE_TENANT_ID`        | Azure AD tenant ID                               |
| `AZURE_SUBSCRIPTION_ID`  | Target Azure subscription ID                     |
| `ADMIN_SSH_PUBLIC_KEY`   | SSH public key injected into VM `authorized_keys` |

---

## GH_PAT — Personal Access Token (required by `update-flake-lock`)

### What it is

`GH_PAT` is a GitHub **Personal Access Token** used exclusively by the
`update-flake-lock` workflow.

### Why a PAT and not `GITHUB_TOKEN`

GitHub intentionally suppresses `pull_request` and `push` events for commits
and pull requests that originate from the built-in `GITHUB_TOKEN`.  If
`update-flake-lock` opened its PR with `GITHUB_TOKEN`, the `ci-pr.yml`
workflow would never trigger on that PR — blocking the required status checks
(`Validate NixOS`) and making the PR unmergeable.

A PAT is owned by a real user account, so GitHub treats the PR as a normal
user action and fires all the expected workflow triggers, including `ci-pr.yml`.

### Required scopes

| Token type | Required scope/permission |
|---|---|
| Classic PAT | `repo` (full repository access) |
| Fine-grained PAT | **Contents** — Read & Write; **Pull requests** — Read & Write (scoped to this repository) |

### How to create and add GH_PAT

1. Go to **GitHub → Settings → Developer settings → Personal access tokens**.
2. Choose **Tokens (classic)** → **Generate new token (classic)**.
   - Note: `update-flake-lock PAT` (or similar)
   - Expiration: set to your preferred rotation period (e.g. 90 days)
   - Scopes: ✅ `repo`
3. Click **Generate token** and copy the value immediately (it won't be shown again).
4. In **this repository** go to **Settings → Secrets and variables → Actions**.
5. Click **New repository secret**.
   - Name: `GH_PAT`
   - Value: paste the token
6. Click **Add secret**.

Using the GitHub CLI:

```bash
gh secret set GH_PAT --repo poomnupong/poomlab-azure --body "<paste token here>"
```

### Token rotation

When the PAT expires the `update-flake-lock` workflow will fail at the
`Checkout` step with a `401 Unauthorized` error.  Generate a new token
following the steps above and update the `GH_PAT` secret.

---

## Summary table

| Secret Name              | Used by workflow(s)                     | Notes                              |
|--------------------------|-----------------------------------------|------------------------------------|
| `AZURE_CLIENT_ID`        | `deploy-infra`, `deploy-nixos`, `ci-pr` | Created by bootstrap script        |
| `AZURE_TENANT_ID`        | `deploy-infra`, `deploy-nixos`, `ci-pr` | Created by bootstrap script        |
| `AZURE_SUBSCRIPTION_ID`  | `deploy-infra`, `deploy-nixos`, `ci-pr` | Created by bootstrap script        |
| `ADMIN_SSH_PUBLIC_KEY`   | `deploy-infra`                          | Your SSH public key                |
| `GH_PAT`                 | `update-flake-lock`                     | Classic PAT, `repo` scope — enables `ci-pr.yml` to trigger on auto-generated PRs |
