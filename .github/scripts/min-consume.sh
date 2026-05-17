#!/usr/bin/env bash

set -euo pipefail

MODE=${1:-}
if [ -z "$MODE" ]; then
  echo "usage: $0 <deploy|teardown>" >&2
  exit 2
fi

LOCATION="${MIN_CONSUME_LOCATION:-westus3}"
RG_NAME="${MIN_CONSUME_RESOURCE_GROUP:-rg-min-consume-westus3}"
VNET_NAME="${MIN_CONSUME_VNET_NAME:-vnet-min-consume-westus3}"
SUBNET_NAME="${MIN_CONSUME_SUBNET_NAME:-snet-min-consume}"
NSG_NAME="${MIN_CONSUME_NSG_NAME:-nsg-min-consume-westus3}"
PIP_NAME="${MIN_CONSUME_PUBLIC_IP_NAME:-pip-min-consume-westus3}"
NIC_NAME="${MIN_CONSUME_NIC_NAME:-nic-min-consume-westus3}"
VM_NAME="${MIN_CONSUME_VM_NAME:-vm-min-consume-westus3}"
VNET_PREFIX="${MIN_CONSUME_VNET_PREFIX:-10.234.0.0/16}"
SUBNET_PREFIX="${MIN_CONSUME_SUBNET_PREFIX:-10.234.0.0/24}"
VM_SIZE="${MIN_CONSUME_VM_SIZE:-Standard_B4as_v2}"
VM_IMAGE="${MIN_CONSUME_VM_IMAGE:-}"
ADMIN_USERNAME="${MIN_CONSUME_ADMIN_USERNAME:-azureuser}"
SSH_SOURCE_PREFIX="${MIN_CONSUME_SSH_SOURCE:-}"
ADMIN_SSH_PUBLIC_KEY="${MIN_CONSUME_ADMIN_SSH_PUBLIC_KEY:-}"

resolve_subscription_ids() {
  local discovered

  if [ -n "${SUBSCRIPTION_IDS:-}" ]; then
    printf '%s\n' "$SUBSCRIPTION_IDS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF' | sort -u
    return 0
  fi

  if discovered=$(az account list --query "[?state=='Enabled'].id" -o tsv 2>/dev/null) && [ -n "$discovered" ]; then
    printf '%s\n' "$discovered" | awk 'NF' | sort -u
    return 0
  fi

  cat >&2 <<'MSG'
::error::Unable to auto-discover subscriptions with `az account list`.
::error::Provide an explicit list via workflow_dispatch input `subscription_ids`
::error::or repository variable/secret `MIN_CONSUME_SUBSCRIPTION_IDS`.
MSG
  return 1
}

resolve_vm_image() {
  local candidate

  if [ -n "$VM_IMAGE" ]; then
    echo "$VM_IMAGE"
    return 0
  fi

  # x86_64 images only: Standard_B4as_v2 is an x86_64 (AMD) VM size and
  # Azure requires the image architecture to match the VM size architecture.
  for candidate in \
    "Canonical:ubuntu-24_04-lts:server:latest" \
    "Canonical:0001-com-ubuntu-server-noble:24_04-lts:latest" \
    "Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"; do
    if az vm image show --location "$LOCATION" --urn "$candidate" --output none 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  echo "::error::Could not resolve a supported Ubuntu LTS non-Pro x86_64 image in $LOCATION." >&2
  echo "::error::Set MIN_CONSUME_VM_IMAGE to a valid URN if your subscription has different image availability." >&2
  return 1
}

ensure_vm_deployed() {
  local subscription_id=$1

  az account set --subscription "$subscription_id"

  echo "==> [$subscription_id] ensuring resource group"
  az group create --name "$RG_NAME" --location "$LOCATION" --output none

  if ! az network vnet show --resource-group "$RG_NAME" --name "$VNET_NAME" --output none 2>/dev/null; then
    echo "==> [$subscription_id] creating VNET + subnet"
    az network vnet create \
      --resource-group "$RG_NAME" \
      --name "$VNET_NAME" \
      --address-prefixes "$VNET_PREFIX" \
      --subnet-name "$SUBNET_NAME" \
      --subnet-prefixes "$SUBNET_PREFIX" \
      --output none
  fi

  if ! az network nsg show --resource-group "$RG_NAME" --name "$NSG_NAME" --output none 2>/dev/null; then
    echo "==> [$subscription_id] creating NSG"
    az network nsg create --resource-group "$RG_NAME" --name "$NSG_NAME" --location "$LOCATION" --output none
  fi

  if [ -n "$SSH_SOURCE_PREFIX" ]; then
    echo "==> [$subscription_id] ensuring SSH rule from $SSH_SOURCE_PREFIX"
    if az network nsg rule show --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" --name AllowSSH --output none 2>/dev/null; then
      az network nsg rule delete --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" --name AllowSSH
    fi
    az network nsg rule create \
      --resource-group "$RG_NAME" \
      --nsg-name "$NSG_NAME" \
      --name AllowSSH \
      --priority 1000 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "$SSH_SOURCE_PREFIX" \
      --source-port-ranges '*' \
      --destination-address-prefixes '*' \
      --destination-port-ranges 22 \
      --output none
  elif az network nsg rule show --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" --name AllowSSH --output none 2>/dev/null; then
    echo "==> [$subscription_id] removing existing SSH rule (MIN_CONSUME_SSH_SOURCE is empty)"
    az network nsg rule delete --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" --name AllowSSH
  fi

  if ! az network public-ip show --resource-group "$RG_NAME" --name "$PIP_NAME" --output none 2>/dev/null; then
    echo "==> [$subscription_id] creating public IP"
    az network public-ip create \
      --resource-group "$RG_NAME" \
      --name "$PIP_NAME" \
      --location "$LOCATION" \
      --sku Basic \
      --version IPv4 \
      --output none
  fi

  if ! az network nic show --resource-group "$RG_NAME" --name "$NIC_NAME" --output none 2>/dev/null; then
    echo "==> [$subscription_id] creating NIC"
    az network nic create \
      --resource-group "$RG_NAME" \
      --name "$NIC_NAME" \
      --location "$LOCATION" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME" \
      --network-security-group "$NSG_NAME" \
      --public-ip-address "$PIP_NAME" \
      --output none
  fi

  if az vm show --resource-group "$RG_NAME" --name "$VM_NAME" --output none 2>/dev/null; then
    echo "==> [$subscription_id] VM already exists, nothing to create"
    return 0
  fi

  echo "==> [$subscription_id] creating VM"
  VM_CREATE_ARGS=(
    --resource-group "$RG_NAME"
    --name "$VM_NAME"
    --location "$LOCATION"
    --nics "$NIC_NAME"
    --size "$VM_SIZE"
    --image "$RESOLVED_VM_IMAGE"
    --admin-username "$ADMIN_USERNAME"
    --authentication-type ssh
    --storage-sku Standard_LRS
    --os-disk-size-gb 30
    --output none
  )
  if [ -n "$ADMIN_SSH_PUBLIC_KEY" ]; then
    VM_CREATE_ARGS+=(--ssh-key-values "$ADMIN_SSH_PUBLIC_KEY")
  else
    VM_CREATE_ARGS+=(--generate-ssh-keys)
  fi
  az vm create "${VM_CREATE_ARGS[@]}"
}

teardown_subscription() {
  local subscription_id=$1

  az account set --subscription "$subscription_id"

  if ! az group show --name "$RG_NAME" --output none 2>/dev/null; then
    echo "==> [$subscription_id] resource group $RG_NAME not found, skipping"
    return 0
  fi

  echo "==> [$subscription_id] deleting resource group $RG_NAME"
  az group delete --name "$RG_NAME" --yes --no-wait
}

main() {
  mapfile -t subscriptions < <(resolve_subscription_ids)

  if [ "${#subscriptions[@]}" -eq 0 ]; then
    echo "::error::No subscriptions were provided or discovered." >&2
    exit 1
  fi

  echo "Subscriptions targeted: ${#subscriptions[@]}"
  printf '  - %s\n' "${subscriptions[@]}"

  case "$MODE" in
    deploy)
      for subscription_id in "${subscriptions[@]}"; do
        az account set --subscription "$subscription_id"
        RESOLVED_VM_IMAGE=$(resolve_vm_image)
        echo "Using VM image for deployment: $RESOLVED_VM_IMAGE"
        ensure_vm_deployed "$subscription_id"
      done
      ;;
    teardown)
      for subscription_id in "${subscriptions[@]}"; do
        teardown_subscription "$subscription_id"
      done
      ;;
    *)
      echo "unknown mode: $MODE" >&2
      echo "usage: $0 <deploy|teardown>" >&2
      exit 2
      ;;
  esac
}

main "$@"
