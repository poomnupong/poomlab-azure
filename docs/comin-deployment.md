# Comin Deployment Model

This document describes the GitOps pull-based deployment model used for NixOS
VMs in this repository.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                          │
│                                                                     │
│  image-bake/               nixos/                                   │
│  └── flake.nix             ├── flake.nix                            │
│  (build-time flake)        ├── modules/                             │
│                            │   ├── comin.nix                        │
│  .github/workflows/        │   ├── agenix.nix                       │
│  ├── image-bake.yml        │   └── ...                              │
│  ├── landing-zone.yml      └── secrets/                             │
│  ├── deploy-workload.yml       ├── secrets.nix                      │
│  ├── comin-status.yml          ├── comin-github-token.age           │
│  ├── rotate-secrets-reminder.yml└── tailscale-authkey.age           │
│  └── update-flake-lock.yml                                          │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ polls every 60s
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure VM (gw1-scus)                          │
│                                                                     │
│  Comin service (baked in image) → pulls repo, nixos-rebuild switch │
│  cloud-init (first boot)        → writes SSH host key from customData│
│  Agenix                         → decrypts .age secrets using host key│
│  postDeploymentCommand          → reports commit status / issues    │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ reports status
                           ▼
                  GitHub Commit Status API
                  GitHub Issues API (on failure)
```

## How It Works

### 1. First Boot (automatic)

When `deploy-workload` creates the VM, cloud-init (via Bicep `osProfile.customData`)
writes `/etc/ssh/ssh_host_ed25519_key` at first boot. Comin is already installed
in the image and starts immediately, polls this repo, and runs
`nixos-rebuild switch`. Agenix decrypts secrets using the now-present host key.
No `az vm run-command` bootstrap is needed.

### 2. Ongoing Deployment (automatic, via Comin)

After first boot, the flow is fully automatic:

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

It uses read-only instance-view queries before inspecting Comin on running VMs
through `az vm run-command invoke`. Each gateway receives an explicit Actions
summary. Stopped, deallocated, or absent gateways are **not checked**; a green
workflow with skipped gateways does not establish fleet health. Monitoring
never starts a gateway.

Service activity alone does not prove authenticated GitOps is working.
Running-VM reports distinguish current fetch/deployment evidence from a merely
active service, and report authentication or observation failures explicitly.

## Secret Management with Agenix

### How Agenix Works

- Secrets are encrypted with [age](https://age-encryption.org/) and stored
  as `.age` files in `nixos/secrets/`.
- The encryption recipients are listed in `nixos/secrets/secrets.nix`.
- Each VM decrypts secrets using its SSH host key (converted to an age key
  via `ssh-to-age`).
- The VM's SSH host key (`/etc/ssh/ssh_host_ed25519_key`) is the only
  decryption key — `ADMIN_SSH_PUBLIC_KEY` is unrelated (it's for SSH login).

### File Structure

```
nixos/secrets/
├── secrets.nix              # Recipients list (age public keys)
├── comin-github-token.age   # Encrypted GitHub PAT for Comin
└── tailscale-authkey.age    # Encrypted Tailscale auth key
```

### Initial Setup — Fully Automated

**No manual steps are required.** When `deploy-workload` creates a VM:

1. `deploy-workload` generates a fresh ed25519 host key pair in CI.
2. Stores the private key in Key Vault `kv-plaz-scus`
   (secret `gw1-scus-ssh-host-ed25519-key`).
3. Re-encrypts agenix secrets for the new recipient, commits
   `secrets.nix` + `.age` files to `main`.
4. Passes the private key as base64 `customData` to Bicep.
5. On VM first boot, cloud-init writes the private key to
   `/etc/ssh/ssh_host_ed25519_key`.
6. Comin starts, pulls config, and agenix decrypts secrets using the
   now-present host key.

**The only manual prerequisite:** set the `GH_PAT` and `CI_SP_OBJECT_ID`
repository secrets and run `global` once (creates the Compute Gallery +
Key Vault for the whole project), then `landing-zone` once per region,
before `deploy-workload`.

### Rotating a Secret

To rotate secrets, edit locally with `agenix -e`:

```bash
# Add your own age key to secrets.nix if not already present
cat ~/.ssh/id_ed25519.pub | ssh-to-age
# Add the resulting age1... key to nixos/secrets/secrets.nix
cd nixos
# Re-encrypt all secrets for the updated recipient list
agenix -r
# Edit a specific secret
agenix -e secrets/comin-github-token.age
git add secrets/ && git commit -m "chore: rotate secret" && git push
```

### Rotating the GitHub PAT

1. Generate a new fine-grained PAT on GitHub with these permissions:
   - **Contents** — Read & Write
   - **Pull requests** — Read & Write
   - **Commit statuses** — Read & Write
   - **Issues** — Read & Write (for failure reporting)
2. Update the `GH_PAT` repository secret:
   ```bash
   gh secret set GH_PAT --repo poomnupong/poomlab-azure
   ```
   Enter the token at the hidden prompt, not as a command argument.
3. Separately update the agenix-encrypted token using an authorized identity:
   ```bash
   cd nixos && agenix -e secrets/comin-github-token.age
   # Paste the new PAT, save
   ```
   Preserve the existing recipients. Commit the encrypted change through a
   reviewed PR. Running VMs can fetch it automatically only while their current
   token still authenticates. Do not start stopped gateways.

### Recovering after token expiration

Updating `GH_PAT` fixes CI's credential, not the encrypted file or a VM's
in-memory/on-disk credential. An expired token can prevent Comin from fetching
the commit containing its own replacement. Do not treat a green CI smoke run
as proof that existing gateways have recovered.

1. Refresh the Actions secret and separately prepare/review the encrypted
   `comin-github-token.age` update for the existing recipients.
2. Keep stopped gateways stopped until their owner approves a maintenance
   window and an out-of-band recovery operation.
3. For an approved running gateway, use an authenticated administrative channel
   (the existing Azure Run Command mechanism or approved SSH access) to install
   a temporary replacement at Comin's **effective** access-token path. Inspect
   the active service/configuration first: a baked-image bootstrap uses
   `/etc/comin-bootstrap-token`, while configured hosts normally use
   `/run/agenix/comin-github-token`.
4. Deliver credentials using the approved secret-management channel, without
   command-line arguments, diagnostic tracing, logs, or unencrypted artifacts.
   Ensure root-only ownership/mode, then restart Comin after approval. Do not
   assume changing a file reconfigures a running process.
5. Verify an authenticated fetch and successful application of the reviewed
   encrypted-token commit, and confirm that agenix manages the persisted
   replacement. Remove any temporary bootstrap copy only after the effective
   token path has transitioned and recovery is verified.

This is an operator-run break-glass procedure, not part of daily health checks.
If the approved recovery channel or required identity is unavailable, stop and
escalate rather than starting/rebuilding VMs or exposing the token.

### Rotating the VM's Age Key (Rare)

Only needed if a VM is compromised or rebuilt:

1. Rebuild VM via `deploy-workload` (new SSH host keys generated automatically).
2. `deploy-workload` automatically generates a new ed25519 key pair, stores
   it in Key Vault, re-encrypts agenix secrets for the new recipient, and
   commits to the repo. **No manual steps needed.**
3. If you prefer manual control:
   ```bash
   ssh-keyscan <vm-ip> 2>/dev/null | nix run nixpkgs#ssh-to-age
   ```
   Update `nixos/secrets/secrets.nix`, run `agenix -r`, commit and push.

## Status Reporting

### Commit Statuses

Every deployment (successful or failed) posts a commit status to GitHub
via the `postDeploymentCommand` in `nixos/modules/comin.nix`.

- **Context**: `comin/<hostname>` (e.g., `comin/gw1-scus`)
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
| `image-bake` | Saturday 14:00 UTC + `nixos/**`/`image-bake/**` changes + manual | Builds baked NixOS image, Tier 1 + Tier 2 smoke, tags `blessed=true` |
| `global` | Manual + global Bicep path changes | Deploys project-wide shared services (Compute Gallery, Key Vault) once for the whole project, region-pinned to the primary region |
| `landing-zone` | Manual + regional Bicep path changes | Deploys regional platform resources (monitoring, networking) — one deployment per region |
| `deploy-workload` | Push to `main` on `infra/**` + manual | Deploys per-region gateway VMs (gw1-scus/gw1-sea) from blessed image; injects host key via cloud-init; no SSH bootstrap |
| `comin-status` | Daily + manual | Health check — queries Comin status on all VMs |
| `ci-pr` | Pull request → `main` | Validation gate (Bicep lint + NixOS flake check) |
| `update-flake-lock` | Weekly Monday 08:00 UTC + manual | Updates `nixos/flake.lock` and `image-bake/flake.lock`, opens PR |
| `rotate-secrets-reminder` | Monthly 1st + manual | Creates issue reminding to rotate secrets |

## Adding a New VM

1. Create `nixos/hosts/<vmname>/` with `default.nix` and `hardware.nix`.
2. Add an entry in `nixos/flake.nix` under `nixosConfigurations` (include
   `comin.nixosModules.comin`, `./modules/comin.nix`,
   `agenix.nixosModules.default`, `./modules/agenix.nix`).
3. Add a VM block in `infra/workload.bicep` for the new VM.
4. Add `deploy-workload.yml` steps for the new VM (resolve image, generate
   host key, deploy).
5. Add a status check job in `comin-status.yml`.
6. Run `global` if a new region is being added (so the gallery image
   versions can replicate there). Run `landing-zone` for any new region.
7. Run `deploy-workload` to create the VM — host key and agenix secrets are
   handled automatically.

## Known Issues / Future Work

- **`tailscale-authkey.age`** is written with a placeholder; must be
  re-encrypted with a real Tailscale auth key after first deploy.

- **Tier 2 smoke test runner** requires `Contributor` on the subscription
  (creates a real Azure VM in a sandbox RG `rg-plaz-smoke-<run_id>`).

- **Gallery retention:** keeping the last 4 blessed versions is a proposed
  policy, not implemented automatic deletion. Cleanup currently targets
  temporary staging/smoke resources. See
  [`docs/image-bake.md`](image-bake.md) for details.
