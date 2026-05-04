# Comin Deployment Model

This document describes the GitOps pull-based deployment model used for NixOS
VMs in this repository. It replaces the previous push-based `deploy-nixos.yml`
approach.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                          │
│                                                                     │
│  nixos/                    .github/workflows/                       │
│  ├── flake.nix             ├── deploy-infra.yml  (bootstrap)       │
│  ├── modules/              ├── comin-status.yml  (health check)    │
│  │   ├── comin.nix         ├── rotate-secrets-reminder.yml         │
│  │   ├── agenix.nix        └── update-flake-lock.yml               │
│  │   └── ...                                                        │
│  └── secrets/                                                       │
│      ├── secrets.nix       (age public keys / recipients)          │
│      ├── comin-github-token.age                                     │
│      └── tailscale-authkey.age                                      │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ polls every 60s
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure VM (gw1)                              │
│                                                                     │
│  Comin service        → pulls repo, runs nixos-rebuild switch      │
│  Agenix               → decrypts .age secrets using SSH host key   │
│  postDeploymentCommand → reports commit status / creates issues     │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ reports status
                           ▼
                  GitHub Commit Status API
                  GitHub Issues API (on failure)
```

## How It Works

### 1. Bootstrap (one-time, via `deploy-infra.yml`)

When `deploy-infra` creates or recreates a VM:

1. The workflow writes the GitHub PAT to `/run/agenix/comin-github-token`
   (temporary bootstrap — agenix takes over after first rebuild).
2. Runs `nixos-rebuild switch --flake github:<repo>?dir=nixos#gw1` once.
3. This first apply installs Comin + agenix + all modules.
4. Comin takes over immediately — it is self-sustaining from this point.

### 2. Ongoing Deployment (automatic, via Comin)

After bootstrap, the flow is fully automatic:

1. You push config changes to `main` (via PR → merge).
2. Comin (running on each VM) polls this repo every 60 seconds.
3. When it detects a new commit, it runs `nixos-rebuild switch`.
4. The `postDeploymentCommand` reports status back to GitHub:
   - **Success**: sets a green commit status (`comin/<hostname>`).
   - **Failure**: sets a red commit status AND creates a GitHub issue.

### 3. Health Monitoring (`comin-status.yml`)

The `comin-status` workflow provides fallback visibility:

- **Automatic**: runs daily at 06:00 UTC.
- **Manual**: trigger via `workflow_dispatch`.
- **After infra deploy**: triggered by `deploy-infra` completion.

It uses `az vm run-command invoke` to check if the Comin systemd service
is active on each VM.

## Secret Management with Agenix

### How Agenix Works

- Secrets are encrypted with [age](https://age-encryption.org/) and stored
  as `.age` files in `nixos/secrets/`.
- The encryption recipients are listed in `nixos/secrets/secrets.nix`.
- Each VM decrypts secrets using its SSH host key (converted to an age key).
- You (the admin) also have an age key for re-encrypting (if your SSH key
  is ed25519).

### File Structure

```
nixos/secrets/
├── secrets.nix              # Recipients list (age public keys)
├── comin-github-token.age   # Encrypted GitHub PAT for Comin
└── tailscale-authkey.age    # Encrypted Tailscale auth key
```

### Initial Setup — Fully Automated

**No manual steps are required.** When `deploy-infra` creates a VM:

1. The bootstrap step writes the PAT and runs `nixos-rebuild switch`
   (installs Comin + agenix).
2. The auto-setup step then:
   - Extracts the VM's SSH host ed25519 public key via `az vm run-command`
   - Converts it to an age public key using `ssh-to-age`
   - Derives the admin's age public key from `ADMIN_SSH_PUBLIC_KEY` (if ed25519)
   - Updates `nixos/secrets/secrets.nix` with the real keys
   - Encrypts `GH_PAT` → `comin-github-token.age` using `age`
   - Commits and pushes to `main`
3. Comin (now running on the VM) pulls the commit with properly encrypted
   secrets. Agenix decrypts them using the VM's SSH host key.

**The only manual prerequisite:** set the `GH_PAT` repository secret.

### Rotating a Secret (100% Git Workflow)

1. Edit the secret locally:
   ```bash
   cd nixos && agenix -e secrets/comin-github-token.age
   ```
   This decrypts → opens in `$EDITOR` → re-encrypts on save.

2. Commit and push:
   ```bash
   git add secrets/comin-github-token.age
   git commit -m "chore: rotate GitHub PAT"
   git push
   ```

3. Comin pulls the new commit → agenix decrypts on the VM → services
   restart with the new secret.

> **Note:** To use `agenix -e` locally, you need your SSH private key
> (`~/.ssh/id_ed25519`) and `ADMIN_SSH_PUBLIC_KEY` must be ed25519. Set
> `AGENIX_IDENTITY=~/.ssh/id_ed25519` if needed.

### Rotating the GitHub PAT

1. Generate a new fine-grained PAT on GitHub with these permissions:
   - **Contents** — Read & Write
   - **Pull requests** — Read & Write
   - **Commit statuses** — Read & Write
2. Update the `GH_PAT` repository secret:
   ```bash
   gh secret set GH_PAT --body "<new-token>"
   ```
3. **Option A (hands-free):** Run `deploy-infra` — it will re-encrypt the PAT
   automatically and commit the updated `.age` file.
4. **Option B (git workflow):** Update the agenix-encrypted token locally:
   ```bash
   cd nixos && agenix -e secrets/comin-github-token.age
   # Paste the new PAT, save
   ```
   Commit, push, merge. Comin picks it up automatically.

### Rotating the VM's Age Key (Rare)

Only needed if a VM is compromised or rebuilt:

1. Rebuild VM via `deploy-infra` (new SSH host keys generated).
2. `deploy-infra` automatically extracts the new age key, re-encrypts
   secrets, and commits to the repo. **No manual steps needed.**
3. If you prefer manual control:
   ```bash
   ssh-keyscan <vm-ip> 2>/dev/null | nix run nixpkgs#ssh-to-age
   ```
   Update `nixos/secrets/secrets.nix`, run `agenix -r`, commit and push.

## Status Reporting

### Commit Statuses

Every deployment (successful or failed) posts a commit status to GitHub
via the `postDeploymentCommand` in `nixos/modules/comin.nix`.

- **Context**: `comin/<hostname>` (e.g., `comin/gw1`)
- **State**: `success` or `failure`
- **Visible on**: every commit on `main`, merge commits, and in PR histories.

### Failure Issues

When a deployment fails, the `postDeploymentCommand` also creates a
GitHub issue with:

- Title: `🔴 Comin deploy failed on <hostname> — <sha-short>`
- Body: error message + last 100 lines of Comin journal logs
- Labels: `deploy-failure`, `automated`

### Rotation Reminders

The `rotate-secrets-reminder` workflow runs monthly (1st of each month)
and creates an issue with a checklist for reviewing all secrets.

## Workflows Summary

| Workflow | Trigger | Purpose |
|---|---|---|
| `deploy-infra` | Push to `main` on `infra/**`, or manual | Deploys Azure infra + bootstraps Comin on new VMs |
| `comin-status` | Daily, manual, or after deploy-infra | Health check — queries Comin status on all VMs |
| `ci-pr` | Pull request → `main` | Validation gate (Bicep + NixOS flake check) |
| `update-flake-lock` | Weekly or manual | Updates `flake.lock` and opens a PR |
| `rotate-secrets-reminder` | Monthly or manual | Creates issue reminding to rotate secrets |

## Adding a New VM

1. Create `nixos/hosts/<vmname>/` with `default.nix` and `hardware.nix`.
2. Add an entry in `nixos/flake.nix` under `nixosConfigurations` (include
   `comin.nixosModules.comin`, `./modules/comin.nix`,
   `agenix.nixosModules.default`, `./modules/agenix.nix`).
3. Add the VM's age public key to `nixos/secrets/secrets.nix`.
4. Re-encrypt secrets: `cd nixos && agenix -r`.
5. Add a bootstrap step in `deploy-infra.yml` for the new VM.
6. Add a status check job in `comin-status.yml`.
