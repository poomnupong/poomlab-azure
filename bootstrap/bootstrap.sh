#!/usr/bin/env bash
#
# bootstrap.sh — Idempotent bootstrap for Azure OIDC + management resources
#
# This script creates:
#   1. Entra ID app registration for GitHub Actions OIDC
#   2. Federated credentials for main branch and PR workflows
#   3. Resource groups (monitoring, network, compute)
#   4. Role assignments (Contributor on subscription)
#
# Prerequisites:
#   - Azure CLI installed and logged in
#   - Sufficient permissions (Owner or User Access Administrator on subscription)
#
# Usage:
#   ./bootstrap/bootstrap.sh [--subscription <sub-id>] [--location <region>] [--github-org <org>] [--github-repo <repo>]
#
set -euo pipefail

# ------------------------------------------------------------------
# Defaults (override via flags or environment variables)
# ------------------------------------------------------------------
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
LOCATION="${AZURE_LOCATION:-southcentralus}"
PROJECT_NAME="${PROJECT_NAME:-poomlab}"
GITHUB_ORG="${GITHUB_ORG:-poomnupong}"
GITHUB_REPO="${GITHUB_REPO:-poomlab-azure}"
APP_DISPLAY_NAME="${PROJECT_NAME}-github-oidc"

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --location)     LOCATION="$2"; shift 2 ;;
    --github-org)   GITHUB_ORG="$2"; shift 2 ;;
    --github-repo)  GITHUB_REPO="$2"; shift 2 ;;
    --project)      PROJECT_NAME="$2"; APP_DISPLAY_NAME="${2}-github-oidc"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ------------------------------------------------------------------
# Validate prerequisites
# ------------------------------------------------------------------
if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) is not installed." >&2
  exit 1
fi

if ! az account show &>/dev/null; then
  echo "ERROR: Not logged in to Azure CLI. Run 'az login' first." >&2
  exit 1
fi

# If no subscription provided, use the current default
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  echo "Using current subscription: $SUBSCRIPTION_ID"
fi

az account set --subscription "$SUBSCRIPTION_ID"

echo "============================================================"
echo " PoomLab Azure Bootstrap"
echo "============================================================"
echo " Subscription : $SUBSCRIPTION_ID"
echo " Location     : $LOCATION"
echo " Project      : $PROJECT_NAME"
echo " GitHub       : $GITHUB_ORG/$GITHUB_REPO"
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# 1. Entra ID App Registration (idempotent)
# ------------------------------------------------------------------
echo ">>> Step 1: Entra ID App Registration"

APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "$APP_ID" || "$APP_ID" == "None" ]]; then
  echo "    Creating app registration: $APP_DISPLAY_NAME"
  APP_ID=$(az ad app create --display-name "$APP_DISPLAY_NAME" --query appId -o tsv)
  echo "    Created app: $APP_ID"
else
  echo "    App registration already exists: $APP_ID"
fi

# Get object ID for the app
APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

# ------------------------------------------------------------------
# 2. Service Principal (idempotent)
# ------------------------------------------------------------------
echo ">>> Step 2: Service Principal"

SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>/dev/null || true)

if [[ -z "$SP_ID" || "$SP_ID" == "None" ]]; then
  echo "    Creating service principal..."
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo "    Created SP: $SP_ID"
else
  echo "    Service principal already exists: $SP_ID"
fi

# ------------------------------------------------------------------
# 3. Federated Credentials for OIDC (idempotent)
# ------------------------------------------------------------------
echo ">>> Step 3: Federated Credentials"

create_federated_credential() {
  local name="$1"
  local subject="$2"
  local description="$3"

  existing=$(az ad app federated-credential list --id "$APP_OBJECT_ID" --query "[?name=='$name'].name" -o tsv 2>/dev/null || true)

  if [[ -z "$existing" ]]; then
    echo "    Creating federated credential: $name"
    az ad app federated-credential create --id "$APP_OBJECT_ID" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"audiences\": [\"api://AzureADTokenExchange\"],
      \"description\": \"$description\"
    }" --only-show-errors -o none
  else
    echo "    Federated credential already exists: $name"
  fi
}

create_federated_credential \
  "github-actions-main" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main" \
  "GitHub Actions deployments from main branch"

create_federated_credential \
  "github-actions-pr" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request" \
  "GitHub Actions PR validation"

create_federated_credential \
  "github-actions-env-production" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:production" \
  "GitHub Actions production environment deployments"

# ------------------------------------------------------------------
# 4. Role Assignment — Contributor on subscription (idempotent)
# ------------------------------------------------------------------
echo ">>> Step 4: Role Assignment"

EXISTING_ROLE=$(az role assignment list \
  --assignee "$SP_ID" \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  --query "[0].id" -o tsv 2>/dev/null || true)

if [[ -z "$EXISTING_ROLE" || "$EXISTING_ROLE" == "None" ]]; then
  echo "    Assigning Contributor role on subscription..."
  az role assignment create \
    --assignee-object-id "$SP_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID" \
    --only-show-errors -o none
  echo "    Role assigned."
else
  echo "    Contributor role already assigned."
fi

# ------------------------------------------------------------------
# 5. Resource Groups (idempotent)
# ------------------------------------------------------------------
echo ">>> Step 5: Resource Groups"

create_resource_group() {
  local rg_name="$1"
  existing=$(az group exists --name "$rg_name" 2>/dev/null || echo "false")
  if [[ "$existing" == "true" ]]; then
    echo "    Resource group already exists: $rg_name"
  else
    echo "    Creating resource group: $rg_name"
    az group create --name "$rg_name" --location "$LOCATION" --tags \
      project="$PROJECT_NAME" \
      managedBy="github-actions" \
      repository="$GITHUB_ORG/$GITHUB_REPO" \
      --only-show-errors -o none
  fi
}

RG_MONITORING="rg-${PROJECT_NAME}-monitoring-${LOCATION}"
RG_NETWORK="rg-${PROJECT_NAME}-network-${LOCATION}"
RG_COMPUTE="rg-${PROJECT_NAME}-compute-${LOCATION}"

create_resource_group "$RG_MONITORING"
create_resource_group "$RG_NETWORK"
create_resource_group "$RG_COMPUTE"

# ------------------------------------------------------------------
# 6. Summary
# ------------------------------------------------------------------
TENANT_ID=$(az account show --query tenantId -o tsv)

echo ""
echo "============================================================"
echo " Bootstrap Complete!"
echo "============================================================"
echo ""
echo " Add these as GitHub repository secrets/variables:"
echo ""
echo "   AZURE_CLIENT_ID      = $APP_ID"
echo "   AZURE_TENANT_ID      = $TENANT_ID"
echo "   AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
echo ""
echo " Resource Groups:"
echo "   Monitoring : $RG_MONITORING"
echo "   Network    : $RG_NETWORK"
echo "   Compute    : $RG_COMPUTE"
echo ""
echo " Next steps:"
echo "   1. Set the above values as GitHub repository secrets"
echo "   2. Push to main to trigger the deployment workflow"
echo "============================================================"
