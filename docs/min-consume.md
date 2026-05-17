# Min-consume (subscription keep-alive)

The `min-consume` workflows create and then remove a minimal footprint in **every accessible subscription** to keep subscriptions active per policy.

- Deploy workflow: [`.github/workflows/min-consume.yml`](../.github/workflows/min-consume.yml)
- Teardown workflow: [`.github/workflows/min-consume-teardown.yml`](../.github/workflows/min-consume-teardown.yml)
- Shared logic: [`.github/scripts/min-consume.sh`](../.github/scripts/min-consume.sh)

## Schedule

- Deploy: **Sunday 00:00 UTC** (`0 0 * * 0`)
- Teardown: **Tuesday 00:00 UTC** (`0 0 * * 2`) — 48 hours later

## What gets deployed (per subscription)

Region: **West US 3**

- Resource group: `rg-min-consume-westus3`
- VNET: `vnet-min-consume-westus3` (`10.234.0.0/16`)
- Subnet: `snet-min-consume` (`10.234.0.0/24`)
- NSG: `nsg-min-consume-westus3` (SSH allow rule is optional via `MIN_CONSUME_SSH_SOURCE`)
- Public IP: `pip-min-consume-westus3`
- NIC: `nic-min-consume-westus3`
- VM: `vm-min-consume-westus3`
  - Size: `Standard_B4as_v2`
  - Image: auto-resolved latest available Ubuntu LTS non-Pro **x86_64** image in West US 3 (prefers Ubuntu 24.04 LTS, then 22.04 LTS). x86_64 is required because `Standard_B4as_v2` is an x86_64 VM size — Azure rejects ARM64 images on x86_64 VM SKUs.
  - Disk: `Standard_LRS` only

No premium extras are enabled.

## Optional SSH access

By default, no SSH ingress rule is kept open.  
If SSH is required, set `MIN_CONSUME_SSH_SOURCE` (CIDR, e.g. `203.0.113.10/32`) in workflow/repo variables so `AllowSSH` (TCP/22) is created for that source range only.

## Subscription discovery and fallback

The `azure/login@v2` step uses `allow-no-subscriptions: true` so the OIDC login succeeds even when no `subscription-id` is provided. After login, the workflows resolve subscriptions in this order:

1. `workflow_dispatch` input `subscription_ids`
2. Repository variable `MIN_CONSUME_SUBSCRIPTION_IDS`
3. Repository secret `MIN_CONSUME_SUBSCRIPTION_IDS`
4. Automatic discovery with `az account list --all --refresh --query "[?state=='Enabled'].id" -o tsv`

If discovery is blocked and no explicit list is supplied, the workflow fails with an error asking for `subscription_ids` / `MIN_CONSUME_SUBSCRIPTION_IDS`.

### OIDC/RBAC scope requirement for multi-subscription runs

`az account list` only returns subscriptions where the OIDC principal has RBAC access.  
The bootstrap script defaults to subscription-scoped assignment:

- `Contributor` on `/subscriptions/<subscription-id>`

That scope is sufficient for single-subscription workflows, but not for tenant-wide `min-consume`.

To enumerate and deploy across all subscriptions, assign OIDC at a higher scope:

- Recommended: management group scope  
  `/providers/Microsoft.Management/managementGroups/<mg-id>`
- Alternative: tenant root scope (`/`) when management-group scoping is not available

Example bootstrap command:

```bash
./bootstrap/bootstrap.sh \
  --subscription <bootstrap-subscription-id> \
  --oidc-role-scope /providers/Microsoft.Management/managementGroups/<mg-id>
```

## Optional overrides

- `MIN_CONSUME_VM_IMAGE`: explicit image URN override if your subscription needs a specific offer/SKU
- `MIN_CONSUME_ADMIN_SSH_PUBLIC_KEY`: optional SSH key for VM creation (defaults to repository `ADMIN_SSH_PUBLIC_KEY` secret in workflow)

## Manual runs

Both workflows support `workflow_dispatch` and optional `subscription_ids` (comma/newline separated).

Examples:

- `11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222`
- One subscription ID per line
