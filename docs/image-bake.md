# Image Bake Pipeline

This document describes the `image-bake` workflow and the `image-bake/` Nix
flake that build a gallery-ready NixOS Azure image with Comin pre-installed.

See `docs/architecture-refactor.md` for the design decisions (D1–D5) that
motivated this pipeline.

## Overview

The upstream [nixos-azimage-builder](https://github.com/poomnupong/nixos-azimage-builder)
produces a vanilla NixOS Azure VHD on a weekly schedule. The `image-bake`
pipeline layers poomlab-azure modules on top and publishes the result to the
Azure Compute Gallery as a gallery image version.

```
nixos-azimage-builder (upstream, via core_pulse.nix input)
          │
          ▼
  image-bake/flake.nix
  ├── core_pulse.nix       (Azure hardware baseline: NVMe+SCSI, GRUB-EFI, waagent)
  ├── nixos/modules/base.nix
  ├── nixos/modules/comin.nix    ← Comin baked in from first boot
  ├── nixos/modules/agenix.nix
  └── nixos/modules/networking.nix
          │
          ▼  nix build → .vhd → gzip → Azure Compute Gallery
  gallery image version
  ├── Tier 1 smoke (nixosTest / QEMU)  →  tag: tier1=passed
  └── Tier 2 smoke (real Azure VM)     →  tag: blessed=true
          │
          ▼
  deploy-workload.yml  (consumes newest blessed=true version)
```

## Trigger Cadence

| Trigger | Jobs run |
|---|---|
| PR touching `nixos/**`, `image-bake/**`, or the workflow file | `build` only (Tier 1 QEMU smoke, no Azure cost) |
| Push to `main` (same paths) | `build` → `publish` → `smoke-tier2` |
| Saturday 14:00 UTC schedule | `build` → `publish` → `smoke-tier2` |
| Manual `workflow_dispatch` | `build` → `publish` → `smoke-tier2` |

## Jobs

### `build` — Build & Tier 1 Smoke

Runs on every trigger. No Azure credentials needed.

1. `nix build .#plazImage` — produces a `.vhd` under `image-bake/result/`
2. `nix build .#checks.x86_64-linux.smokeTest` — boots the image in QEMU
   and asserts:
   - `multi-user.target` reached
   - `nix-ld.service` active (required for Azure VM extensions)
   - `comin.service` unit is defined and references `github.com/poomnupong/poomlab-azure`
   - `net.ipv4.ip_forward = 1` (NVA role)
   - `sshd.service` running
   - `azureuser` account exists
   - `nix --version` succeeds
3. Compresses VHD to `.vhd.gz` and uploads as a GitHub Actions artifact (main branch only).

### `publish` — Publish to Gallery

Runs on `main` branch only. Requires Azure OIDC (`production` environment).

1. Ensures the Compute Gallery exists (managed by `global.yml`).
2. Downloads `.vhd.gz` artifact from `build`.
3. Stages VHD to a managed disk, uploads via AzCopy, creates gallery image version.
4. Polls until replication completes.
5. Tags `tier1=passed` on the gallery image version.

### `smoke-tier2` — Real Azure Smoke

Runs only after `publish` succeeds, on `main` branch only.

1. Provisions a throwaway VM (`rg-plaz-smoke-<run_id>`) from the new gallery image version.
2. Waits for waagent `displayStatus == "Ready"`.
3. Asserts `comin.service` active via `az vm run-command invoke` with a `TIER2_OK` sentinel.
4. Single-attempt SSH assert (`nixos-version && systemctl is-active comin`).
5. Tears down the sandbox RG unconditionally (even on failure).
6. Tags `blessed=true tier2=passed` on the gallery image version.

## `image-bake/flake.nix` Structure

The flake defines three outputs:

- `packages.x86_64-linux.plazImage` — gallery-ready VHD (`nixos-generators` `azure` format)
- `packages.x86_64-linux.default` — alias for `plazImage`
- `checks.x86_64-linux.smokeTest` — `nixosTest` that boots `appModules` in QEMU

Two module sets:

- **`appModules`** — poomlab-azure application modules (base, comin, agenix, networking). Shared between image build and Tier 1 smoke test to guarantee test exercises the same code as the image.
- **`plazModules`** — `appModules` + `core_pulse.nix` (Azure hardware baseline from `nixos-azimage-builder`) + `virtualisation.azure.agent.enable = true`. Used only for the baked image; `core_pulse.nix` is excluded from the smoke test because its Azure-specific bootloader/filesystem options conflict with QEMU's nixosTest plumbing.

## Versioning

Gallery image version format: `YYYYMMDD.HHMM.0`
Derived from the build timestamp (`date -u +%Y%m%d.%H%M`) with `.0` appended to
satisfy the three-part `Major.Minor.Patch` format required by Azure Compute Gallery.

## Blessed Version Selection

`deploy-workload.yml` resolves the image to deploy at runtime:

```bash
az sig image-version list \
  --resource-group "$GALLERY_RG" \
  --gallery-name "$GALLERY_NAME" \
  --gallery-image-definition "$IMAGE_DEF" \
  --query "[?tags.blessed=='true'] | sort_by(@, &publishingProfile.publishedDate) | [-1].id" \
  -o tsv
```

If no `blessed=true` version exists, the deploy fails fast with a clear error.

## Garbage Collection

After tagging a new `blessed=true` version, older un-blessed versions are deleted eagerly. The last 4 blessed versions are retained; older blessed versions are untagged and may be deleted.
