// keyvault.bicep — Subscription-level orchestrator for the CI Key Vault
//
// Deployed by deploy-infra.yml before the main infrastructure.
// Creates a Key Vault that stores the deployment SSH keypair:
//   - ssh-deploy-private-key  (read by deploy-nixos via OIDC — never a GitHub secret)
//   - ssh-deploy-public-key   (injected into the VM by main.bicep at creation time)
//
// The keypair is generated once by deploy-infra.yml and reused on every
// subsequent run.  No manual key management is required.

targetScope = 'subscription'

// =====================================================================
// Parameters
// =====================================================================

@description('Azure region for all resources')
param location string

@description('Project name used in resource naming')
param projectName string = 'plaz'

@description('Object ID of the CI service principal that needs Key Vault Secrets Officer access')
param ciServicePrincipalObjectId string

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
}

// =====================================================================
// Variables
// =====================================================================

var rgSecurityName = 'rg-${projectName}-security-${location}'

// =====================================================================
// Resource Group
// =====================================================================

resource rgSecurity 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgSecurityName
  location: location
  tags: tags
}

// =====================================================================
// Module Deployment
// =====================================================================

module keyvault 'modules/keyvault/main.bicep' = {
  name: 'keyvault-deployment'
  scope: rgSecurity
  params: {
    location: location
    projectName: projectName
    ciServicePrincipalObjectId: ciServicePrincipalObjectId
    tags: tags
  }
}

// =====================================================================
// Outputs
// =====================================================================

output securityResourceGroup string = rgSecurityName
output keyVaultName string = keyvault.outputs.keyVaultName
output keyVaultUri string = keyvault.outputs.keyVaultUri
