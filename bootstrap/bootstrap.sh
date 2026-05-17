#!/usr/bin/env bash
#
# bootstrap.sh — Idempotent bootstrap for Azure OIDC + management resources
#
# This script creates:
#   1. Entra ID app registration for GitHub Actions OIDC
#   2. Federated credentials for main branch and PR workflows
#   3. Resource groups (monitoring, network, compute)
#   4. Role assignment for CI identity (default: Contributor on tenant root)
#
# Prerequisites:
#   - Azure CLI installed and logged in
#   - Sufficient permissions (Owner or User Access Administrator on the target scope)
#
# Usage:
#   ./bootstrap/bootstrap.sh [--subscription <sub-id>] [--location <region>] [--github-org <org>] [--github-repo <repo>] [--oidc-role-scope <scope>] [--oidc-role-name <role>]
#
# Optional environment variables:
#   AZURE_OIDC_ROLE_SCOPE  RBAC scope for OIDC role assignment (default: /)
#   AZURE_OIDC_ROLE_NAME   RBAC role name for OIDC principal (default: Contributor)
#
# Limitations:
#   - Default scope (/) is tenant root and requires elevated RBAC to assign roles there.
#   - Prefer management group scope for least privilege:
#       /providers/Microsoft.Management/managementGroups/<mg-id>
#
set -euo pipefail

# ------------------------------------------------------------------
# Defaults (override via flags or environment variables)
# ------------------------------------------------------------------
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
LOCATION="${AZURE_LOCATION:-southcentralus}"
PROJECT_NAME="${PROJECT_NAME:-plaz}"
GITHUB_ORG="${GITHUB_ORG:-poomnupong}"
GITHUB_REPO="${GITHUB_REPO:-poomlab-azure}"
APP_DISPLAY_NAME="${PROJECT_NAME}-github-oidc"
OIDC_ROLE_SCOPE="${AZURE_OIDC_ROLE_SCOPE:-}"
OIDC_ROLE_NAME="${AZURE_OIDC_ROLE_NAME:-Contributor}"

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
    --oidc-role-scope) OIDC_ROLE_SCOPE="$2"; shift 2 ;;
    --oidc-role-name) OIDC_ROLE_NAME="$2"; shift 2 ;;
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

if [[ -z "$OIDC_ROLE_SCOPE" ]]; then
  OIDC_ROLE_SCOPE="/"
fi

echo "============================================================"
echo " Plaz Azure Bootstrap"
echo "============================================================"
echo " Subscription : $SUBSCRIPTION_ID"
echo " Location     : $LOCATION"
echo " Project      : $PROJECT_NAME"
echo " GitHub       : $GITHUB_ORG/$GITHUB_REPO"
echo " OIDC Role    : $OIDC_ROLE_NAME @ $OIDC_ROLE_SCOPE"
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
  local issuer="https://token.actions.githubusercontent.com"
  local existing_id
  local is_match
  local match_query
  local payload

  existing_id=$(az ad app federated-credential list \
    --id "$APP_OBJECT_ID" \
    --query "[?name=='$name'] | [0].id" -o tsv 2>/dev/null || true)

  payload=$(cat <<EOF
{
  "name": "$name",
  "issuer": "$issuer",
  "subject": "$subject",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "$description"
}
EOF
)

  if [[ -z "$existing_id" || "$existing_id" == "None" ]]; then
    echo "    Creating federated credential: $name"
    az ad app federated-credential create \
      --id "$APP_OBJECT_ID" \
      --parameters "$payload" \
      --only-show-errors -o none
  else
    # Ensure the existing credential still matches the desired trust config.
    match_query="[?name=='$name' && issuer=='$issuer' && subject=='$subject' && description=='$description' && length(audiences)==\`1\` && audiences[0]=='api://AzureADTokenExchange'] | length(@)"
    is_match=$(az ad app federated-credential list \
      --id "$APP_OBJECT_ID" \
      --query "$match_query" \
      -o tsv 2>/dev/null || echo "0")
    if [[ "$is_match" == "1" ]]; then
      echo "    Federated credential already correct: $name"
    else
      echo "    Updating federated credential: $name"
      az ad app federated-credential update \
        --id "$APP_OBJECT_ID" \
        --federated-credential-id "$existing_id" \
        --parameters "$payload" \
        --only-show-errors -o none
    fi
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
# 4. Role Assignment (idempotent)
# ------------------------------------------------------------------
echo ">>> Step 4: Role Assignment"

get_role_assignment_count() {
  # Avoid extra Microsoft Graph lookups; we only need assignment count here.
  az role assignment list \
    --assignee-object-id "$SP_ID" \
    --fill-principal-name false \
    --role "$OIDC_ROLE_NAME" \
    --scope "$OIDC_ROLE_SCOPE" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0"
}

EXISTING_ROLE_COUNT=$(get_role_assignment_count)

if [[ "$EXISTING_ROLE_COUNT" == "0" ]]; then
  echo "    Assigning $OIDC_ROLE_NAME role on $OIDC_ROLE_SCOPE..."
  if az role assignment create \
    --assignee-object-id "$SP_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$OIDC_ROLE_NAME" \
    --scope "$OIDC_ROLE_SCOPE" \
    --only-show-errors -o none; then
    echo "    Role assigned."
  else
    EXISTING_ROLE_COUNT=$(get_role_assignment_count)
    if [[ "$EXISTING_ROLE_COUNT" == "0" ]]; then
      echo "ERROR: Failed to assign $OIDC_ROLE_NAME at $OIDC_ROLE_SCOPE." >&2
      exit 1
    fi
    echo "    Role assignment already present (detected after create attempt)."
  fi
else
  echo "    $OIDC_ROLE_NAME role already assigned at $OIDC_ROLE_SCOPE."
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
echo "   AZURE_OIDC_ROLE_NAME  = $OIDC_ROLE_NAME"
echo "   AZURE_OIDC_ROLE_SCOPE = $OIDC_ROLE_SCOPE"
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
