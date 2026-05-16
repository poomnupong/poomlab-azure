# poomlab-azure

IaC repo for Plaz footprint in Azure, deployed via GitHub Actions with OIDC authentication.

## Architecture

This repository uses **Azure Bicep** for infrastructure as code, deploying resources organized into dedicated resource groups within a single Azure subscription.

### Why Bicep over Terraform?

- **No state management** — Bicep deployments are idempotent and use Azure Resource Manager directly. No remote state backend to configure, secure, or worry about drifting.
- **First-class Azure integration** — Bicep is Azure-native, always supports the latest API versions on day one, and has full parity with ARM templates.
- **Mature enough** — Bicep has reached GA, has strong VS Code tooling, and is Microsoft's recommended IaC language for Azure. The `what-if` command provides plan-like previews.
- **Simpler CI/CD** — No need for `terraform init`, state locking, or backend configuration. Just `az deployment` commands.

### Resource Group Layout

Resources are organized into purpose-specific resource groups following Azure Cloud Adoption Framework (CAF) best practices:

| Resource Group | Purpose | Contents |
|---|---|---|
| `rg-plaz-monitoring-<region>` | Monitoring & diagnostics (per region) | Log Analytics workspace, diagnostic settings |
| `rg-plaz-network-<region>` | Networking (per region) | VNETs, subnets, NSGs, public IPs, route tables |
| `rg-plaz-gallery-southcentralus` | Compute Gallery (project-wide, primary region only) | Azure Compute Gallery, image definitions; image versions are replicated to other regions |
| `rg-plaz-keyvault-southcentralus` | Key Vault (project-wide, primary region only) | Key Vault `kv-plaz-scus` — SSH host keys for every host in every region, RBAC for CI SP |
| `rg-plaz-compute-<region>` | Compute workloads (per region) | VMs, disks, NICs |

### Naming Convention

Follows [Azure CAF naming convention](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming):

```
<resource-type-prefix>-<project>-<workload/purpose>-<region-short>[-<instance>]
```

Examples:
- `rg-plaz-network-eastus2` — networking resource group
- `vnet-plaz-hub-eastus2` — hub VNET
- `vm-plaz-gw1-eastus2` — gateway VM
- `pip-plaz-gw1-eastus2` — public IP for gateway VM
- `nsg-plaz-gateway-eastus2` — NSG for gateway subnet
- `log-plaz-main-eastus2` — Log Analytics workspace

### Network Design

A single VNET (`vnet-plaz-hub`) is deployed initially. This VNET is designed to become a **hub VNET** if the topology expands (hub-spoke model). The NixOS gateway VM sits in this hub and can act as a network virtual appliance (NVA) for routing between spokes.

Subnets:
- `snet-gateway` — For the NixOS gateway/NVA VM (192.168.85.0/28, 11 hosts)
- `snet-default` — General purpose (192.168.85.16/28, 11 hosts)
- NAT Gateway attached for outbound internet connectivity
- Remaining space: 192.168.85.32/27 and above reserved for future subnets

### NixOS VM & Flake Hierarchy

This repository uses **two separate Nix flakes**:

- **`image-bake/`** — build-time flake. Layers Comin, agenix, base, and networking modules onto the upstream [nixos-azimage-builder](https://github.com/poomnupong/nixos-azimage-builder) VHD baseline and publishes a gallery image version. The baked image has `comin.service` running from first boot. See [`docs/image-bake.md`](docs/image-bake.md).

- **`nixos/`** — runtime flake consumed by Comin on each VM. Contains host configurations and modules that Comin applies via `nixos-rebuild switch`.

```
image-bake/
├── flake.nix              # Build-time flake (produces gallery-ready VHD)
└── flake.lock

nixos/
├── flake.nix               # Runtime flake with nixosConfigurations output
├── flake.lock              # Refreshed weekly by update-flake-lock workflow
├── hosts/
│   └── gw1/
│       ├── default.nix     # Host-specific config (hostname, networking, firewall)
│       └── hardware.nix    # Azure Gen2 hardware config (NVMe+SCSI, boot loader, Hyper-V)
├── modules/
│   ├── base.nix            # Common: users, SSH authorized keys, Nix settings
│   ├── comin.nix           # Comin GitOps service + status reporting callback
│   ├── agenix.nix          # Agenix secret declarations
│   ├── tailscale.nix       # Tailscale VPN module
│   ├── networking.nix      # IP forwarding, routing (NVA role)
│   └── monitoring.nix      # node_exporter for Azure Monitor
└── secrets/
    ├── secrets.nix         # Age public keys (recipients list)
    ├── comin-github-token.age   # Encrypted GitHub PAT
    └── tailscale-authkey.age    # Encrypted Tailscale auth key
```

Each host under `nixos/hosts/<vmname>/` is self-contained — `default.nix` imports the shared modules and adds host-specific overrides.

## CI/CD Workflows

| Workflow | File | Trigger | Purpose |
|---|---|---|---|
| `ci-pr` | `.github/workflows/ci-pr.yml` | Pull request → `main` | Validation only. Bicep lint + NixOS flake check. |
| `image-bake` | `.github/workflows/image-bake.yml` | Saturday 14:00 UTC + `nixos/**`/`image-bake/**` changes + manual | Builds baked NixOS image with Comin pre-installed. Tier 1 QEMU smoke + Tier 2 real-Azure smoke. Tags `blessed=true` on success. |
| `global` | `.github/workflows/global.yml` | Manual + global Bicep path changes | Deploys project-wide shared services (Compute Gallery, Key Vault) once for the whole project, region-pinned to the primary region. |
| `landing-zone` | `.github/workflows/landing-zone.yml` | Manual + regional Bicep path changes | Deploys regional platform resources (monitoring, VNET/NSGs) — one deployment per region. |
| `deploy-workload` | `.github/workflows/deploy-workload.yml` | Push to `main` on `infra/**` + manual | Deploys gw1. Resolves newest `blessed=true` image. Option A agenix key delivery via cloud-init. No SSH bootstrap. |
| `comin-status` | `.github/workflows/comin-status.yml` | Daily + manual | Health check — Comin status on all VMs. |
| `update-flake-lock` | `.github/workflows/update-flake-lock.yml` | Weekly Monday 08:00 UTC + manual | Updates `nixos/flake.lock` and `image-bake/flake.lock`, opens PR. |
| `rotate-secrets-reminder` | `.github/workflows/rotate-secrets-reminder.yml` | Monthly 1st + manual | Creates GitHub issue with secrets rotation checklist. |
| `destroy-infra` | `.github/workflows/destroy-infra.yml` | Manual only | Deletes all Azure resource groups. |

**Key principle:** `ci-pr` acts as the gate — it runs on every PR and must pass before merging. After merge to `main`, Comin (running on each VM) polls this repo every 60 seconds and applies the new config automatically. No SSH bootstrap is ever needed — Comin is baked into the gallery image and starts on first boot.

## Branch Protection

Branch protection on `main` is strongly recommended to ensure all changes pass validation before reaching production. See [`docs/branch_protection.md`](docs/branch_protection.md) for a complete setup guide, including the required status check names and a GitHub CLI command for scripted configuration.

## NixOS Configuration

> **GitOps via Comin:** All NixOS configuration is driven through this Git
> repository using [Comin](https://github.com/nlewo/comin), a GitOps pull-based
> deployment tool. Comin runs as a systemd service on each VM, polling this repo
> every 60 seconds and running `nixos-rebuild switch` when it detects changes.
> Never run `nix flake update` or `nixos-rebuild` manually on a VM.
>
> Secrets are encrypted with [agenix](https://github.com/ryantm/agenix) and
> stored in git. VMs decrypt them using their SSH host keys.
>
> See [`docs/comin-deployment.md`](docs/comin-deployment.md) for the full
> architecture, secret rotation workflow, and status reporting details.

## Getting Started

### Prerequisites

- Azure CLI (`az`) installed and logged in (`az login`)
- A target Azure subscription where you have **Owner** or **User Access Administrator** role
- GitHub repository admin access (for configuring secrets)
- An SSH public key for VM access

### 1. Bootstrap Azure Environment

The bootstrap script creates all prerequisite Azure resources for OIDC-based GitHub Actions deployment:

```bash
# Login to Azure
az login

# Run bootstrap (idempotent — safe to re-run)
./bootstrap/bootstrap.sh
```

You can override defaults via flags:

```bash
./bootstrap/bootstrap.sh \
  --subscription <subscription-id> \
  --location <region> \
  --github-org <org> \
  --github-repo <repo> \
  --project <project-name>
```

Or via environment variables: `AZURE_SUBSCRIPTION_ID`, `AZURE_LOCATION`, `GITHUB_ORG`, `GITHUB_REPO`, `PROJECT_NAME`.

The script creates:
- Entra ID (AAD) app registration (`<project>-github-oidc`)
- Service principal with **Contributor** role on the subscription
- Federated credentials for OIDC (main branch, pull requests, and `production` environment)

At the end, it prints the values you need for the next step.

### 2. Configure GitHub Actions Secrets

After running the bootstrap script, you must add the following **repository secrets** in GitHub.

Go to **Settings → Secrets and variables → Actions → Secrets** (or use the `gh` CLI) and create:

| Secret Name | Used by | Description |
|---|---|---|
| `AZURE_CLIENT_ID` | all Azure workflows | App registration client ID |
| `AZURE_TENANT_ID` | all Azure workflows | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | all Azure workflows | Target subscription ID |
| `ADMIN_SSH_PUBLIC_KEY` | `deploy-workload`, `ci-pr` | SSH public key injected into VM `authorized_keys` |
| `GH_PAT` | `update-flake-lock`, `deploy-workload` | Fine-grained PAT (Contents + Pull requests + Commit statuses, R/W) |
| `CI_SP_OBJECT_ID` | `global` | Object ID of CI service principal for Key Vault Secrets Officer. Get: `az ad sp show --id "$AZURE_CLIENT_ID" --query id -o tsv` |

See [docs/secrets.md](docs/secrets.md) for full setup instructions for each secret.

Using the GitHub CLI:

```bash
gh secret set AZURE_CLIENT_ID --body "<value from bootstrap output>"
gh secret set AZURE_TENANT_ID --body "<value from bootstrap output>"
gh secret set AZURE_SUBSCRIPTION_ID --body "<value from bootstrap output>"
gh secret set ADMIN_SSH_PUBLIC_KEY --body "$(cat ~/.ssh/id_ed25519.pub)"
gh secret set GH_PAT --body "<your fine-grained PAT>"
CI_SP_OID=$(az ad sp show --id "$AZURE_CLIENT_ID" --query id -o tsv)
gh secret set CI_SP_OBJECT_ID --body "$CI_SP_OID"
```

> **Note:** The workflow also requires a GitHub **environment** named `production` for the deploy job. Create it under **Settings → Environments → New environment** and name it `production`. You can optionally add protection rules (e.g., required reviewers) to gate deployments.

### 3. Deploy Infrastructure

The deployment flow has four steps run in order:

1. **Run `global` workflow** (once for the project, or when gallery / Key Vault config changes) — deploys the project-wide Compute Gallery and Key Vault `kv-plaz-scus`, region-pinned to the primary region (southcentralus).

2. **Run `landing-zone` workflow** (once per region, or whenever a region's network topology changes) — deploys monitoring + VNET/NSGs for that region.

3. **Run `image-bake` workflow** — wait for a `blessed=true` gallery image version to appear. This may already have a blessed version if the schedule has run; otherwise trigger manually.

4. **Run `deploy-workload`** — deploys gw1 from the newest `blessed=true` image. Injects the SSH host key via cloud-init `customData`. Comin starts on first boot and applies the full NixOS config automatically. No SSH bootstrap required.

## Configuration

Key parameters are split across three environment param files:

- `infra/environments/plaz-global.bicepparam` — project-wide shared services (primary region, project name, region code for Key Vault name, CI SP object ID)
- `infra/environments/plaz-landing-zone.bicepparam` — regional platform resources (location, project name, networking CIDRs). One file per region (also `plaz-sea-landing-zone.bicepparam`, …).
- `infra/environments/plaz-workload.bicepparam` — compute resources (VM size, admin username, SSH key, image ID, cloud-init data). One file per region.

All files use `readEnvironmentVariable()` for secrets and dynamic values that are injected by the workflows at deploy time.
