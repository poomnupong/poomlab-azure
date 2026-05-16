// keyvault/main.bicep — Key Vault for platform secrets
//
// Stores per-VM SSH host private keys injected via cloud-init customData
// (Phase 5 Option A agenix host key delivery).
//
// Uses Azure RBAC (enableRbacAuthorization = true).
// CI service principal gets Key Vault Secrets Officer (data plane) and
// Key Vault Contributor (management plane, for JIT firewall allowlist).

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('Short region code used to keep the (globally unique) Key Vault name distinct across regions (e.g. scus, sea).')
param regionCode string

@description('Object ID of the CI service principal for Key Vault Secrets Officer role assignment. Leave empty to skip.')
param ciServicePrincipalObjectId string = ''

@description('Resource tags')
param tags object

var keyVaultName = 'kv-${projectName}-${regionCode}'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Public endpoint stays reachable, but the firewall denies by default.
    // deploy-workload.yml temporarily adds the GitHub-hosted runner's egress
    // IP to networkAcls.ipRules for the duration of `az keyvault secret set`
    // and removes it again in an always() cleanup step. AzureServices bypass
    // keeps Azure-internal callers (e.g. ARM deployments) working.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

// Key Vault Secrets Officer — allows CI SP to write/read secrets (data plane)
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

// Key Vault Contributor — allows CI SP to update networkAcls.ipRules
// (management plane) so it can JIT-allowlist the runner IP. Does NOT grant
// data-plane access; that still goes through Secrets Officer + RBAC.
var kvContributorRoleId = 'f25e0fa2-a7c8-4377-a976-54943a77a395'

resource ciSecretsOfficerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(ciServicePrincipalObjectId)) {
  name: guid(keyVault.id, ciServicePrincipalObjectId, kvSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: ciServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource ciKvContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(ciServicePrincipalObjectId)) {
  name: guid(keyVault.id, ciServicePrincipalObjectId, kvContributorRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvContributorRoleId)
    principalId: ciServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultName string = keyVault.name
output keyVaultId   string = keyVault.id
output keyVaultUri  string = keyVault.properties.vaultUri
