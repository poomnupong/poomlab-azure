# Workflow & Image Architecture Refactor

Status: **Proposed** — tracking design for the split of `deploy-infra` into a
CAF-aligned, image-bake-decoupled pipeline.

## Motivation

The `deploy-infra` workflow currently fuses three concerns that change at very
different cadences and have independent failure modes:

1. **Bicep validation / what-if** — changes per infra PR.
2. **NixOS image staging** — only changes on upstream VHD refresh
   (~weekly) or when the bake recipe changes.
3. **VM deployment + Comin bootstrap** — changes per infra PR; today this is
   where most operational pain lives (long `nixos-rebuild` over `az vm
   run-command`, OIDC token expiration, NSG ephemeral-key dance, 409 conflicts
   on extension lockup).

Mixing them means:

- Every Bicep typo fix pays the cost of "do I need a new image?" logic.
- Every weekly image refresh re-runs Bicep diffs that haven't moved.
- A red badge on `deploy-infra` doesn't tell you which of the three concerns
  failed.
- The heaviest step (image bake) cannot be given its own runner / cache
  strategy without inflating cost on routine PRs.
- The first-boot Comin bootstrap is the source of nearly every failure mode
  documented in `docs/comin-deployment.md` and the run-command troubleshooting
  notes.

## Decisions

### D1. Keep `nixos-azimage-builder` Comin-free

The upstream image stays a vanilla NixOS Azure VHD. Comin (and agenix host-key
provisioning) is layered on top **in this repository** as part of the bake
step. This keeps the upstream image reusable for non-Comin consumers and keeps
all GitOps choices in the consumer repo where they belong.

### D2. Bake Comin into the image; bootstrap goes away

Once Comin is baked, first boot already has `comin.service` running, polling
the configured remote, and ready to apply. The 30–90 minute first-boot
`nixos-rebuild` over `az vm run-command` is **deleted**. `deploy-infra` no
longer needs SSH ingress, ephemeral keys, NSG carve-outs, OIDC re-auth before
long bootstraps, or 409-Conflict retry logic.

The remaining per-VM provisioning concern is the agenix host identity (the
`ssh_host_ed25519_key` that decrypts secrets). Two options, to be decided in
the implementation PR:

- **Option A (preferred):** generate the host key in CI, encrypt to the
  workload identity / Key Vault, and inject via `cloud-init` `customData` on VM
  creation. No SSH from the runner ever.
- **Option B:** one short `az vm run-command` call (seconds, not hours) to
  drop the key, then let Comin take over.

### D3. Stay with Comin

Reassessment with the failure data we now have:

| Tool | Pull/Push | Bootstrap pain | Steady-state pain | Verdict |
|---|---|---|---|---|
| **Comin** | Pull | High *today*, **eliminated by D2** | Low; `comin-status.yml` already proves it | Keep |
| deploy-rs | Push | Low (no agent) | Re-introduces all the runner-in-hot-path problems Comin was chosen to solve | Reject |
| Colmena | Push | Same as deploy-rs | Same as deploy-rs | Reject |
| NixOps | Push | Heavy; wants to own provisioning | Conflicts with Bicep | Reject |
| Cachix Deploy | Pull (SaaS) | Low | Vendor lock + outbound trust + cost | Reject |

The recurring failures have not been Comin's fault — they have been
**bootstrap-of-Comin's** fault, and D2 removes that surface area entirely.
Comin's pull model is the right shape for "small fleet of long-lived hosts
that should self-heal toward `main`".

To keep the door open: Comin and agenix wiring will live behind a single
`nixos/modules/comin.nix`. If Comin disappoints in a new way, swapping to
deploy-rs becomes a localized change to that module plus a workflow swap, not
a re-architecture.

### D4. Split workflows along CAF lines, with a conscious deviation

| Workflow | CAF tier | Owns | Trigger | Heavy? |
|---|---|---|---|---|
| `image-bake` | Platform (shared service) | Layer Comin/agenix onto upstream VHD → publish gallery image version → smoke test → tag as **blessed** | Weekly schedule + `nixos/**` PRs + manual | **Yes** |
| `landing-zone` | Platform | Network RG (vnets, subnets, NSGs, route tables, peering anchors), Key Vault, Compute Gallery, identities, monitoring RG | Manual + `infra/landing-zone/**` | No |
| `deploy-workload` (renamed `deploy-infra`) | Workload | gw1 + future workloads; consumes the latest **blessed** image version; no SSH bootstrap | Per-PR + manual | No |
| `comin-status` | Operations | Production health pulse | Schedule | No |
| `destroy-infra` | Operations | Tear down workload RGs (unchanged) | Manual | No |

**gw1 deviation from CAF:** strictly, a hub NVA belongs in a *connectivity*
landing-zone subscription. We consciously place gw1 on the workload side
because (a) it is the only NVA, (b) it changes more often than a "real"
platform component would, and (c) keeping it in workload preserves the rule
"platform deploys are rare and serious; workload deploys are frequent and
routine" — the rule that gives us the operational savings. If a second
workload appears, gw1 is promoted to a `connectivity` workflow without
rewriting much: the natural seam (the network RG it lives in) is already
platform-managed.

### D5. Smoke testing lives with the bake, in two tiers

The smoke test is the gate that promotes a freshly-baked gallery image
version from "built" to **blessed**. `deploy-workload` only ever sees blessed
versions, so it can assume the image works.

- **Tier 1 — `nixosTest` in QEMU on the runner.** Runs on every
  `image-bake` invocation. Boots the application module set
  (Comin, agenix, base, networking) under the test driver and asserts:
  - The full module set evaluates without option conflicts and the
    system reaches `multi-user.target`.
  - `comin.service` is defined and points at the configured GitOps
    remote (`postDeploymentCommand`, `services.comin.remotes`, etc.).
  - The agenix module activates cleanly (with a fixture-empty
    `age.secrets` to avoid Tier 2 territory).
  - Core wiring contract: `nix-ld`, IP forwarding, sshd, `azureuser`.

  Fast, free, catches module-eval / unit-definition regressions. It
  intentionally does NOT exercise Comin actually fetching from GitHub,
  agenix actually decrypting `.age` files, the upstream Azure hardware
  baseline (`core_pulse.nix` collides with the test driver's own
  bootloader), or waagent (no Azure fabric). Those are Tier 2.

- **Tier 2 — Real Azure smoke (only on publish).** Spin up a throwaway VM in
  a sandbox RG from the new gallery image version, point Comin at a sandbox
  branch with one known commit, wait for the deployment generation to flip,
  assert sshd reachable, tear the RG down. This is the only end-to-end gate
  that confirms "Comin actually pulls and deploys on Azure".

Only an image version that passes both tiers gets the `blessed=true` gallery
tag (or equivalent). `deploy-workload` selects the newest image version with
that tag.

## Out of scope (this refactor)

- Migrating to a connectivity / hub-and-spoke split landing zone — deferred
  until there is a second workload.
- Multi-region — single-region (`southcentralus`) only.
- Replacing Bicep — orthogonal.

## Implementation phases

Each phase is one PR. Each PR is independently revertible.

- [x] **Phase 1 — Tracking PR (this doc).** No behavioral change. Establishes
      shared vocabulary and the rollout plan. *(PR #45, merged.)*
- [x] **Phase 2 — `nixos/modules/comin.nix`.** Extract Comin + agenix wiring
      from `nixos/hosts/gw1/` into a reusable module. No behavior change
      yet — module is imported in the same place. *(No-op: the module was
      already factored into `nixos/modules/comin.nix` and
      `nixos/modules/agenix.nix` during earlier work; `nixos/flake.nix`
      imports them once per host. Confirmed no host-level duplication
      remains. Stale "deploy-infra bootstraps Comin" comments refreshed in
      `nixos/flake.nix` and `nixos/hosts/gw1/default.nix`, and a pointer to
      this doc / PR #45 was added to the top of `nixos/modules/comin.nix`
      so future agents land on the architectural context.)*
- [x] **Phase 3 — `image-bake` workflow.** New workflow that consumes the
      upstream VHD, layers `comin.nix`, publishes a gallery image version,
      and runs Tier 1 smoke (`nixosTest`). Phase 3 tags successful versions
      as `tier1=passed` only; the `blessed=true` tag is reserved for
      versions that also pass Tier 2 (set by Phase 4). Also fixed
      `nixos/flake.nix` so `agenix` and `comin` inputs follow
      `nixpkgs-stable` (matching the `nixosSystem` they feed) instead of
      the unstable `nixpkgs`.
      *(PR #XX, merged.)*
- [x] **Phase 4 — Tier 2 smoke.** Added `smoke-tier2` job to `image-bake.yml`:
      provisions a throwaway VM from the new gallery image version, waits for
      waagent via `az vm get-instance-view`, asserts `comin.service` active via
      run-command and single-attempt SSH, tears down smoke RG, then sets
      `blessed=true` on the gallery image version. (`update-flake-lock.yml`
      already runs `nix flake update` in `image-bake/` alongside `nixos/`, so
      no change was required there for this phase.) *(PR #XX.)*
- [ ] **Phase 5 — `deploy-workload`.** Rename `deploy-infra` →
      `deploy-workload`. Switch image selection to "newest blessed gallery
      image version". Delete the run-command bootstrap, NSG ephemeral
      carve-out, and 409-retry logic. Replace with the chosen agenix
      host-key delivery (D2 Option A or B).
- [ ] **Phase 6 — `landing-zone` workflow.** Extract gallery RG, network RG,
      Key Vault, monitoring into their own workflow with their own
      cadence/triggers.
- [ ] **Phase 7 — Documentation.** Update `README.md`,
      `docs/comin-deployment.md`, and add `docs/image-bake.md` to reflect the
      new model. Mark the run-command troubleshooting sections as
      historical.

## Open questions

1. **Agenix host key delivery (D2 A vs B).** Option A is cleaner but requires
   plumbing `customData` through Bicep and pre-encrypting per-VM. Option B is
   a small, time-bounded `az vm run-command` (seconds) and avoids changing
   the Bicep contract. Recommend revisiting in Phase 5.
2. **Blessed-version selector.** Gallery image-version tags vs a "latest"
   alias vs an output artifact from `image-bake` consumed by
   `deploy-workload` via `workflow_run`. Lean toward gallery tags for
   auditability.
3. **Garbage collection.** How many historical gallery image versions to
   retain. Default proposal: keep last 4, delete older un-blessed versions
   eagerly.
