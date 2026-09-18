# Region lifecycle

`infra/regions.json` is the region-membership registry. The remaining region
is `plaz` / `southcentralus` / `gw1-scus`. Southeast Asia is retired.

## Turn a gateway off or on

In **Actions > gateway-power > Run workflow**, select **main**, enter one
enabled environment (currently `plaz`), and choose:

| Action | Effect |
|---|---|
| `status` | Read-only Azure power state; no start or deployment |
| `deallocate` | Stop the gateway and release compute allocation |
| `start` | Start the existing gateway and verify that Azure reports running |

Equivalent CLI dispatches:

```bash
gh workflow run gateway-power.yml --ref main -f environment=plaz -f action=status
gh workflow run gateway-power.yml --ref main -f environment=plaz -f action=deallocate
gh workflow run gateway-power.yml --ref main -f environment=plaz -f action=start
```

Start/deallocate are idempotent and serialized with regional deployment and
cleanup. A missing gateway cannot be started; provision its enabled region
first. Ambiguous/transitional states and Azure access errors fail explicitly.

Deallocation stops VM compute charges, **not all regional charges**: disks,
public IPs, NAT gateways, monitoring, and image replicas may still cost money.
`stopped` without deallocation can still incur compute charges. Normal
workload deployment preserves both stopped and deallocated gateways before
image selection, recreation, or host-key rotation. Explicitly start a paused
gateway before requesting infrastructure/image reconciliation.

Azure `running` does not prove the gateway or Comin is healthy. Run
`comin-status` after starting. Its encrypted fleet GitHub credential must also
be current; replacing the Actions `GH_PAT` does not rotate the `.age` file.

## Add a region

1. Copy the primary environment's landing-zone/workload `.bicepparam` files
   to `<env>-landing-zone.bicepparam` and `<env>-workload.bicepparam`. Set both
   locations to the new Azure location, choose a supported VM SKU, a unique
   gateway name, and non-overlapping network prefixes.
2. Copy `nixos/hosts/gw1-scus/` to the new gateway name, update the hostname
   and regional configuration, and register it in `nixos/flake.nix`.
3. Add its unique `env`, `location`, `gateway`, `regionCode`, and
   `enabled: true` registry entry. Keep exactly one enabled primary.
4. Merge after validation. Registry changes trigger image baking/replication
   as well as workload discovery. New gateways are created only from a
   succeeded, blessed image already targeting their region. If none exists,
   deployment reports the deferred creation instead of rotating keys or
   submitting an invalid VM deployment.
5. Wait for `image-bake` and the following `deploy-workload`. Successful bake
   completion retries **missing** gateways; it does not rebuild running ones
   or turn stopped ones on. Superseded upstream completions are ignored so
   old definitions cannot restore a region removed by a newer commit.
6. Confirm `gateway-power/status` and `comin-status`. After a failed bake or
   deployment, fix the reported error and rerun it; an explicit
   `deploy-workload` dispatch for the environment also retries provisioning.

The workflows generate/register the new host's age recipient and preserve
other active recipients. Do not invent a public key for the new gateway.

## Remove a secondary region

**Destructive:** set `enabled: false` or remove its registry entry and merge.
This is not the way to temporarily turn it off.

The push workflow compares previous/current enabled locations and deletes
only the retired region's exact `rg-plaz-compute-<location>`,
`rg-plaz-network-<location>`, and `rg-plaz-monitoring-<location>` groups,
including their contents. It then removes that location from existing image
versions' replication targets, retaining image versions, tags, other targets,
replica counts/storage settings, and shared gallery/Key Vault resources.
Replica cleanup is serialized with image baking; the Azure replica-deletion
safety opt-in is restored to its prior effective value after cleanup.

For complete source retirement, also remove the two regional parameter files,
host configuration, NixOS flake registration, and future age recipient entry.
Disabling keeps those files available, but manual deploy/power operations
require re-enabling the region first. Re-adding a removed region follows the
normal add process.

Primary-region retirement is refused: shared services need a separately
planned migration. Never use `destroy-infra` to remove one region.

Deletion is push-driven, not triggered by an ordinary manual deploy. If it
fails, inspect Azure and **rerun the original push run's failed jobs**, which
retains the removal diff. Confirm all three groups are absent and no image
targets the retired location before considering retirement complete.

Retired host-key secrets and existing encrypted secret blobs are retained.
Removing an age recipient declaration does not re-encrypt or revoke access
to old ciphertext; see [Secrets](secrets.md).
