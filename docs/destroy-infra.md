# Destroy Infrastructure

The `destroy-infra` workflow
([`.github/workflows/destroy-infra.yml`](../.github/workflows/destroy-infra.yml))
deletes **all** Azure resource groups created by `deploy-infra`. Use it when
you need a clean slate — run `deploy-infra` afterwards to recreate everything.

---

## When to Use

- **Full environment reset** — you want to rebuild all infrastructure from
  scratch (e.g., after a failed deployment or to pick up a new NixOS gallery
  image with a different image definition).
- **Cost savings** — tear down the environment when it's not needed.
- **Testing bootstrap** — verify the `deploy-infra` bootstrap flow works
  end-to-end by destroying and recreating.

> **Warning:** This deletes VMs, disks, networking, the compute gallery, and
> monitoring resources. All data on VM disks is permanently lost. Comin will
> need to be re-bootstrapped via `deploy-infra` after recreation.

---

## How to Run

The workflow is **manual-dispatch only** and requires a confirmation string.

### Via GitHub UI

1. Go to **Actions → destroy-infra → Run workflow**.
2. In the **confirm** field, type `destroy` (exactly).
3. Click **Run workflow**.
4. The `production` environment approval gate will prompt for review
   (if configured with required reviewers).

### Via GitHub CLI

```bash
gh workflow run destroy-infra --field confirm=destroy
```

If the `production` environment has required reviewers, you'll still need
to approve in the GitHub UI.

---

## What Gets Deleted

Resource groups are deleted **sequentially in dependency order**:

| Order | Resource Group | Contents |
|-------|---------------|----------|
| 1 | `rg-plaz-compute-<region>` | VMs, OS disks, NICs |
| 2 | `rg-plaz-gallery-<region>` | Compute Gallery, image definitions, image versions |
| 3 | `rg-plaz-network-<region>` | VNETs, subnets, NSGs, public IPs, NAT gateway |
| 4 | `rg-plaz-monitoring-<region>` | Log Analytics workspace, diagnostic settings |

Compute is deleted first because VMs hold references to network and gallery
resources. Each resource group is deleted with `--no-wait` then polled until
deletion completes (30-minute timeout per group).

---

## Safety Controls

| Control | How It Works |
|---------|-------------|
| **Manual dispatch only** | Cannot be triggered by push or schedule — must be explicitly requested |
| **Confirmation string** | Must type `destroy` — prevents accidental clicks |
| **Environment approval** | Uses the `production` environment, which can require reviewer approval |
| **Concurrency lock** | Shares the `infra-plaz-southcentralus` concurrency group with `deploy-infra` — cannot run simultaneously with a deploy |

---

## After Destruction

1. **Run `deploy-infra`** to recreate all infrastructure:
   ```bash
   gh workflow run deploy-infra --field environment=plaz
   ```
   This will stage the NixOS image, deploy Bicep, bootstrap Comin, and
   **automatically extract the new VM's age key, re-encrypt secrets, and
   commit to the repo.** No manual steps needed.

2. Comin (freshly bootstrapped) picks up the re-encrypted secrets
   automatically on its next poll cycle (~60 seconds).

---

## Troubleshooting

### Deletion times out

If a resource group fails to delete within 30 minutes, the workflow exits
with an error. **Do not run `deploy-infra` until deletion completes.** Check
the Azure portal for the resource group status and retry manually:

```bash
az group delete --name rg-plaz-compute-southcentralus --yes
```

### Resource locks prevent deletion

If someone added a `CanNotDelete` lock to a resource group or resource,
deletion will fail. Remove the lock first:

```bash
az lock delete --name <lock-name> --resource-group <rg-name>
```

### Subscription-level deployments remain

`destroy-infra` only deletes resource groups. The subscription-level
deployment records (`global-plaz`, `landing-zone-plaz`, `deploy-plaz`,
`landing-zone-plaz-sea`, `deploy-plaz-sea`, …) remain in Azure as
metadata. These are harmless and will be overwritten on the next deploy.
To clean them up manually:

```bash
az deployment sub delete --name global-plaz
az deployment sub delete --name landing-zone-plaz
az deployment sub delete --name deploy-plaz
```
