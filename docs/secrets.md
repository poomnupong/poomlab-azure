# Repository Secrets Reference

This document describes every repository secret required by the GitHub Actions
workflows in this repository.  All secrets are stored under
**Settings → Secrets and variables → Actions → Secrets**.

For **NixOS VM secrets** (encrypted in git with agenix), see
[`docs/comin-deployment.md`](comin-deployment.md).

---

## Azure OIDC secrets (required by all Azure workflows)

These secrets are created by the [bootstrap script](../bootstrap/bootstrap.sh)
and enable workflows to authenticate to Azure via OpenID Connect — no
long-lived password or certificate is stored.

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `AZURE_CLIENT_ID`        | Application (client) ID of the Entra ID app registration |
| `AZURE_TENANT_ID`        | Azure AD tenant ID                               |
| `AZURE_SUBSCRIPTION_ID`  | Target Azure subscription ID                     |
| `CI_SP_OBJECT_ID`        | Object ID of the CI service principal, used by `global` to assign the Key Vault Secrets Officer and Key Vault Contributor roles. Get: `az ad sp show --id "$AZURE_CLIENT_ID" --query id -o tsv` |

---

## ADMIN_SSH_PUBLIC_KEY

### Repo file (NixOS / Comin)

Admin SSH public keys are committed to `nixos/keys/admin.pub` — one key per
line, blank lines and `#` comments ignored.  `base.nix` reads this file at Nix
eval time and populates `openssh.authorizedKeys.keys` for the `azureuser`
account on every host.

Because Comin evaluates the Nix expression purely from repo contents on the
host, the key **must** live in the repo.  A GitHub secret alone would be wiped
on the first `nixos-rebuild switch`.

Multiple keys are supported — just add one key per line:

```text
ssh-ed25519 AAAA... alice@workstation
ssh-ed25519 AAAA... bob@laptop
```

After editing, commit and push.  Comin will apply the change automatically.

### GitHub secret (Azure / Bicep)

The `ADMIN_SSH_PUBLIC_KEY` **secret** is still required by the `deploy-workload`
and `ci-pr` workflows.  The Bicep template injects it into the Azure VM's
`linuxConfiguration.ssh.publicKeys` at creation time — before NixOS or Comin
run.  Keep the secret in sync with the first key in `nixos/keys/admin.pub`.

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `ADMIN_SSH_PUBLIC_KEY`   | Contents of your SSH public key file (e.g. `~/.ssh/id_ed25519.pub`) |

Set it with:

```bash
gh secret set ADMIN_SSH_PUBLIC_KEY --repo poomnupong/poomlab-azure --body "$(cat ~/.ssh/id_ed25519.pub)"
```

### Bootstrap checklist

1. Generate (or locate) your SSH key pair:
   ```bash
   ssh-keygen -t ed25519 -C "yourname@host"
   ```
2. Paste your **public** key into `nixos/keys/admin.pub` and commit.
3. Set the GitHub secret to the same value:
   ```bash
   gh secret set ADMIN_SSH_PUBLIC_KEY --repo poomnupong/poomlab-azure \
     --body "$(cat ~/.ssh/id_ed25519.pub)"
   ```
4. Push — Comin will deploy the key to all running hosts.

---

## GH_PAT — Personal Access Token (required by `update-flake-lock` and `deploy-workload`)

### What it is

`GH_PAT` is a GitHub **Personal Access Token** used by:

- **`update-flake-lock`** — so auto-generated PRs trigger `ci-pr.yml`
- **`deploy-workload`** — to commit updated agenix secrets (`secrets.nix` + `.age`
  files) after re-encrypting for the new host key

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

> **Note:** The PAT needs **Commit statuses** R/W permission so that
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

`nixos/secrets/secrets.nix` (the recipients list) is auto-updated by
`deploy-workload` when a new VM is created — no manual `agenix -r` step is
needed for initial setup.

`tailscale-authkey.age` is initially written with a placeholder value and must
be re-encrypted with a real Tailscale auth key after first deploy.

---

## Key Vault secrets

The Key Vault `kv-plaz-scus` (in `rg-plaz-keyvault-southcentralus`) stores
secrets that are injected into VMs at creation time. It is project-wide
(region-pinned to the primary region) and managed by the `global` workflow;
hosts in every region share the same vault, with one secret per host.

| Secret name | Purpose |
|---|---|
| `gw1-ssh-host-ed25519-key` | Private SSH host key for gw1, generated by `deploy-workload` in CI and passed via cloud-init `customData` on VM creation |
| `gw2-ssh-host-ed25519-key` | Private SSH host key for gw2 (plaz-sea), generated and stored the same way |

These secrets are managed entirely by `deploy-workload` — no manual steps are
needed.

The vault firewall defaults to **Deny** (`networkAcls.defaultAction: 'Deny'`
in `infra/modules/keyvault/main.bicep`) with `bypass: 'AzureServices'`, so ARM
deployments and other Azure-internal callers still work. The `deploy-workload`
workflow temporarily adds the GitHub-hosted runner's egress IP to
`networkAcls.ipRules` for the duration of `az keyvault secret set`, then
removes it in an `always()` cleanup step. The CI service principal therefore
needs **Key Vault Contributor** (management plane) in addition to **Key Vault
Secrets Officer** (data plane); both are assigned by `infra/modules/keyvault/main.bicep`.

---

## Summary table

| Secret Name              | Used by workflow(s) / component                  | Notes                              |
|--------------------------|--------------------------------------------------|------------------------------------|
| `AZURE_CLIENT_ID`        | all Azure workflows                              | Created by bootstrap script        |
| `AZURE_TENANT_ID`        | all Azure workflows                              | Created by bootstrap script        |
| `AZURE_SUBSCRIPTION_ID`  | all Azure workflows                              | Created by bootstrap script        |
| `CI_SP_OBJECT_ID`        | `global`                                         | Object ID for Key Vault Secrets Officer + Contributor roles; get via `az ad sp show` |
| `ADMIN_SSH_PUBLIC_KEY`   | `deploy-workload`, `ci-pr`                       | Azure VM initial provisioning; keep in sync with `nixos/keys/admin.pub` |
| `GH_PAT`                 | `update-flake-lock`, `deploy-workload`           | Fine-grained PAT (Contents + Pull requests + Commit statuses, R/W) |
