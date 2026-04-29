# poomlab-azure

IaC repo for PoomLab footprint in Azure, deployed via GitHub Actions with OIDC authentication.

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
| `rg-poomlab-monitoring-<region>` | Monitoring & diagnostics | Log Analytics workspace, diagnostic settings |
| `rg-poomlab-network-<region>` | Networking | VNETs, subnets, NSGs, public IPs, route tables |
| `rg-poomlab-compute-<region>` | Compute workloads | VMs, disks, NICs |

### Naming Convention

Follows [Azure CAF naming convention](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming):

```
<resource-type-prefix>-<project>-<workload/purpose>-<region-short>[-<instance>]
```

Examples:
- `rg-poomlab-network-eastus2` — networking resource group
- `vnet-poomlab-hub-eastus2` — hub VNET
- `vm-poomlab-gw1-eastus2` — gateway VM
- `pip-poomlab-gw1-eastus2` — public IP for gateway VM
- `nsg-poomlab-gateway-eastus2` — NSG for gateway subnet
- `log-poomlab-main-eastus2` — Log Analytics workspace

### Network Design

A single VNET (`vnet-poomlab-hub`) is deployed initially. This VNET is designed to become a **hub VNET** if the topology expands (hub-spoke model). The NixOS gateway VM sits in this hub and can act as a network virtual appliance (NVA) for routing between spokes.

Subnets:
- `snet-gateway` — For the NixOS gateway/NVA VM (192.168.85.0/28, 11 hosts)
- `snet-default` — General purpose (192.168.85.16/28, 11 hosts)
- NAT Gateway attached for outbound internet connectivity
- Remaining space: 192.168.85.32/27 and above reserved for future subnets

### NixOS VM & Flake Hierarchy

The NixOS VM uses a custom image from [nixos-azimage-builder](https://github.com/poomnupong/nixos-azimage-builder). Recommended flake hierarchy:

```
nixos-config/
├── flake.nix              # Top-level flake
├── flake.lock
├── hosts/
│   └── gw1/
│       ├── default.nix    # Host-specific config (hostname, networking, tailscale)
│       └── hardware.nix   # Azure-specific hardware config
├── modules/
│   ├── base.nix           # Common base config (users, ssh, nix settings)
│   ├── tailscale.nix      # Tailscale module
│   ├── networking.nix     # Network appliance / routing config
│   └── monitoring.nix     # Azure monitoring agent, log forwarding
└── overlays/              # Custom package overlays
```

The flake should reference the `nixos-azimage-builder` repo as an input for the base image configuration, then layer host-specific and role-specific modules on top.

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
- Resource groups for monitoring, networking, and compute

At the end, it prints the values you need for the next step.

### 2. Configure GitHub Actions Secrets

After running the bootstrap script, you must add the following **repository secrets** in GitHub so the workflow can authenticate to Azure via OIDC.

Go to **Settings → Secrets and variables → Actions → Secrets** (or use the `gh` CLI) and create:

| Secret Name              | Value                                      | Source                          |
|--------------------------|--------------------------------------------|---------------------------------|
| `AZURE_CLIENT_ID`       | Application (client) ID of the app registration | Printed by bootstrap script     |
| `AZURE_TENANT_ID`       | Azure AD tenant ID                         | Printed by bootstrap script     |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription ID               | Printed by bootstrap script     |
| `ADMIN_SSH_PUBLIC_KEY`   | Your SSH public key (e.g. contents of `~/.ssh/id_ed25519.pub`) | Your local machine |

Using the GitHub CLI:

```bash
gh secret set AZURE_CLIENT_ID --body "<value from bootstrap output>"
gh secret set AZURE_TENANT_ID --body "<value from bootstrap output>"
gh secret set AZURE_SUBSCRIPTION_ID --body "<value from bootstrap output>"
gh secret set ADMIN_SSH_PUBLIC_KEY --body "$(cat ~/.ssh/id_ed25519.pub)"
```

> **Note:** The workflow also requires a GitHub **environment** named `production` for the deploy job. Create it under **Settings → Environments → New environment** and name it `production`. You can optionally add protection rules (e.g., required reviewers) to gate deployments.

### 3. Deploy Infrastructure

Push to `main` branch or manually trigger the workflow:

```bash
git push origin main
```

The GitHub Actions workflow (`deploy-infra`) will:
1. Authenticate to Azure via OIDC (no long-lived secrets)
2. Validate the Bicep templates
3. Run `what-if` preview showing planned changes
4. Deploy Bicep templates (only on push to `main` or manual dispatch)

## Configuration

Key parameters are in `infra/environments/poomlab.bicepparam`:

- `location` — Azure region for all resources (checked-in environment/workflow target: `southcentralus`)
- `projectName` — Project identifier used in naming (default: `poomlab`)
- `vmSize` — VM SKU (default: `Standard_D4ads_v7`)
- `adminUsername` — VM admin user
- `adminSshPublicKey` — SSH public key for VM access
