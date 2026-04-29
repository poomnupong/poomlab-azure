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
- `vm-poomlab-nixgw-eastus2` — NixOS gateway VM
- `pip-poomlab-nixgw-eastus2` — public IP for gateway VM
- `nsg-poomlab-nixgw-eastus2` — NSG for gateway VM
- `log-poomlab-main-eastus2` — Log Analytics workspace

### Network Design

A single VNET (`vnet-poomlab-hub`) is deployed initially. This VNET is designed to become a **hub VNET** if the topology expands (hub-spoke model). The NixOS gateway VM sits in this hub and can act as a network virtual appliance (NVA) for routing between spokes.

Subnets:
- `snet-gateway` — For the NixOS gateway/NVA VM (192.168.85.0/26, 62 hosts)
- `snet-default` — General purpose (192.168.85.64/26, 62 hosts)
- Remaining space: 192.168.85.128/25 reserved for future subnets

### NixOS VM & Flake Hierarchy

The NixOS VM uses a custom image from [nixos-azimage-builder](https://github.com/poomnupong/nixos-azimage-builder). Recommended flake hierarchy:

```
nixos-config/
├── flake.nix              # Top-level flake
├── flake.lock
├── hosts/
│   └── nixgw/
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

- Azure CLI (`az`) installed
- A target Azure subscription
- GitHub repository admin access (for OIDC federation setup)

### 1. Bootstrap Azure Environment

The bootstrap script creates all prerequisite Azure resources for OIDC-based GitHub Actions deployment:

```bash
# Login to Azure
az login

# Run bootstrap (idempotent — safe to re-run)
./bootstrap/bootstrap.sh
```

This creates:
- Entra ID (AAD) app registration with federated credentials for GitHub Actions OIDC
- Resource groups for monitoring, networking, and compute
- Sets GitHub repository secrets for the workflow

### 2. Deploy Infrastructure

Push to `main` branch or manually trigger the workflow:

```bash
git push origin main
```

The GitHub Actions workflow will:
1. Authenticate via OIDC (no secrets stored)
2. Run `what-if` preview
3. Deploy Bicep templates

## Configuration

Key parameters are in `infra/environments/poomlab.bicepparam`:

- `location` — Azure region for all resources (default: `eastus2`)
- `projectName` — Project identifier used in naming (default: `poomlab`)
- `vmSize` — VM SKU (default: `Standard_D4ads_v7`)
- `adminUsername` — VM admin user
- `adminSshPublicKey` — SSH public key for VM access
