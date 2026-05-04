# Repository Secrets Reference

This document describes every repository secret required by the GitHub Actions
workflows in this repository.  All secrets are stored under
**Settings → Secrets and variables → Actions → Secrets**.

For **NixOS VM secrets** (encrypted in git with agenix), see
[`docs/comin-deployment.md`](comin-deployment.md).

---

## Azure OIDC secrets (required by `ci-pr`, `deploy-infra`, and `comin-status`)

These three secrets are created by the [bootstrap script](../bootstrap/bootstrap.sh)
and enable workflows to authenticate to Azure via OpenID Connect — no
long-lived password or certificate is stored.

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `AZURE_CLIENT_ID`        | Application (client) ID of the Entra ID app registration |
| `AZURE_TENANT_ID`        | Azure AD tenant ID                               |
| `AZURE_SUBSCRIPTION_ID`  | Target Azure subscription ID                     |

---

## ADMIN_SSH_PUBLIC_KEY

Your SSH public key, injected into VM `authorized_keys` by `deploy-infra` and
read by `ci-pr` during the `az deployment sub what-if` step (the Bicep template
accepts it as a parameter).  This is **not** related to OIDC — it is a static
value from your local machine.

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `ADMIN_SSH_PUBLIC_KEY`   | Contents of your SSH public key file (e.g. `~/.ssh/id_ed25519.pub`) |

Set it with:

```bash
gh secret set ADMIN_SSH_PUBLIC_KEY --repo poomnupong/poomlab-azure --body "$(cat ~/.ssh/id_ed25519.pub)"
```

---

## GH_PAT — Personal Access Token (required by `update-flake-lock` and `deploy-infra`)

### What it is

`GH_PAT` is a GitHub **Personal Access Token** used by:

- **`update-flake-lock`** — so auto-generated PRs trigger `ci-pr.yml`
- **`deploy-infra`** — to bootstrap Comin on new VMs (passed as an ephemeral
  token for the first `nixos-rebuild`)

The same PAT is also encrypted with agenix and stored in
`nixos/secrets/comin-github-token.age` for ongoing Comin operation on VMs.
When rotating the PAT, update **both** the repository secret and the agenix
file (see [docs/comin-deployment.md](comin-deployment.md) for the rotation
workflow).

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
| Fine-grained PAT (**recommended**) | **Contents** — Read & Write; **Pull requests** — Read & Write; **Commit statuses** — Read & Write (scoped to this repository only) |
| Classic PAT | `repo` (full repository access — grants broader access than needed) |

> **Note:** The PAT now also needs **Commit statuses** R/W permission so that
> Comin's `postDeploymentCommand` can report deployment status back to GitHub.

### How to create and add GH_PAT

A **fine-grained personal access token** is recommended over a classic PAT because
it follows the principle of least privilege — permissions are scoped to only this
repository and limited to the exact capabilities the workflow needs.

#### Fine-grained PAT (recommended)

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**.
2. Click **Generate new token**.
   - Token name: `poomlab-azure PAT` (or similar)
   - Expiration: set to your preferred rotation period (e.g. 90 days)
   - Resource owner: your account (or the org owning this repo)
   - Repository access: **Only select repositories** → choose this repository
   - Permissions → Repository permissions:
     - **Contents** — Read and Write
     - **Pull requests** — Read and Write
     - **Commit statuses** — Read and Write
3. Click **Generate token** and copy the value immediately (it won't be shown again).
4. In **this repository** go to **Settings → Secrets and variables → Actions**.
5. Click **New repository secret**.
   - Name: `GH_PAT`
   - Value: paste the token
6. Click **Add secret**.

> **That's it.** When `deploy-infra` runs, it automatically encrypts the PAT
> with agenix for each VM and commits the `.age` file to the repo. No manual
> `agenix -e` step is needed for initial setup.
>
> For manual rotation later, you can also update the encrypted token locally:
> ```bash
> cd nixos && agenix -e secrets/comin-github-token.age
> git add secrets/comin-github-token.age && git commit -m "chore: update comin token" && git push
> ```

#### Classic PAT (alternative)

If you prefer a classic token, generate one with the `repo` scope. Note that
classic tokens grant access to **all** repositories you can access, so a
fine-grained token is preferred for tighter security.

Using the GitHub CLI:

```bash
gh secret set GH_PAT --repo poomnupong/poomlab-azure --body "<paste token here>"
```

### Token rotation

The `rotate-secrets-reminder` workflow creates a monthly issue reminding you
to check token expiry. When the PAT expires:

1. The `update-flake-lock` workflow will fail with `401 Unauthorized`.
2. Comin on VMs will fail to pull repo changes.

To rotate:
1. Generate a new PAT following the steps above.
2. Update `GH_PAT` repository secret.
3. Update `nixos/secrets/comin-github-token.age` with `agenix -e`.
4. Commit and push — Comin picks up the new token automatically.

---

## Agenix-managed secrets (on VMs, encrypted in git)

These secrets are encrypted with [agenix](https://github.com/ryantm/agenix) and
stored in `nixos/secrets/`. They are decrypted on each VM using the VM's SSH
host key. See [`docs/comin-deployment.md`](comin-deployment.md) for the full
workflow.

| Secret file | Decrypts to | Purpose |
|---|---|---|
| `comin-github-token.age` | `/run/agenix/comin-github-token` | GitHub PAT for Comin (repo pull + commit status + issue creation) |
| `tailscale-authkey.age` | `/run/agenix/tailscale-authkey` | Tailscale auth key for automatic VPN enrollment |

---

## Summary table

| Secret Name              | Used by workflow(s) / component          | Notes                              |
|--------------------------|------------------------------------------|------------------------------------|
| `AZURE_CLIENT_ID`        | `deploy-infra`, `comin-status`, `ci-pr`  | Created by bootstrap script        |
| `AZURE_TENANT_ID`        | `deploy-infra`, `comin-status`, `ci-pr`  | Created by bootstrap script        |
| `AZURE_SUBSCRIPTION_ID`  | `deploy-infra`, `comin-status`, `ci-pr`  | Created by bootstrap script        |
| `ADMIN_SSH_PUBLIC_KEY`   | `deploy-infra`, `ci-pr`                  | Your SSH public key; used by Bicep template and what-if |
| `GH_PAT`                 | `update-flake-lock`, `deploy-infra`      | Fine-grained PAT (Contents + Pull requests + Commit statuses, R/W) — used for PR triggers and Comin bootstrap |
