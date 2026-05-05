// landing-zone.bicep — Platform infrastructure for the plaz environment
//
// Owns: monitoring RG + Log Analytics, network RG + VNET/subnets/NSGs/NAT,
//       gallery RG + Compute Gallery + image definition,
//       keyvault RG + Key Vault kv-plaz-scus.
//
// CAF tier: Platform (shared service).
// Trigger:  Manual or path-filtered push (see landing-zone.yml).
// Cadence:  Rare — only when network topology, gallery definition, or
//           Key Vault config changes.
//
// Outputs consumed by deploy-workload.yml at deploy time:
//   gatewaySubnetId, logAnalyticsWorkspaceId
//
// See docs/architecture-refactor.md D4.

targetScope = 'subscription'

@description('Azure region for all resources')
param location string

@description('Project name used in resource naming')
param projectName string = 'plaz'

@description('VNET address space')
param vnetAddressPrefix string = '192.168.85.0/24'

@description('Gateway subnet address prefix')
param gatewaySubnetPrefix string = '192.168.85.0/28'

@description('Default subnet address prefix')
param defaultSubnetPrefix string = '192.168.85.16/28'

@description('Log Analytics workspace retention in days')
param logRetentionDays int = 30

@description('Source address prefix for SSH access. Leave empty to omit the SSH NSG rule.')
param sshSourceAddressPrefix string = ''

@description('Object ID of the CI service principal for Key Vault Secrets Officer. Leave empty to skip role assignment.')
param ciServicePrincipalObjectId string = ''

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
}

var rgMonitoringName = 'rg-${projectName}-monitoring-${location}'
var rgNetworkName    = 'rg-${projectName}-network-${location}'
var rgGalleryName    = 'rg-${projectName}-gallery-${location}'
var rgKeyVaultName   = 'rg-${projectName}-keyvault-${location}'

resource rgMonitoring 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgMonitoringName
  location: location
  tags: tags
}

resource rgNetwork 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgNetworkName
  location: location
  tags: tags
}

resource rgGallery 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgGalleryName
  location: location
  tags: tags
}

resource rgKeyVault 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgKeyVaultName
  location: location
  tags: tags
}

module monitoring 'modules/monitoring/main.bicep' = {
  name: 'monitoring-deployment'
  scope: rgMonitoring
  params: {
    location: location
    projectName: projectName
    logRetentionDays: logRetentionDays
    tags: tags
  }
}

module networking 'modules/networking/main.bicep' = {
  name: 'networking-deployment'
  scope: rgNetwork
  params: {
    location: location
    projectName: projectName
    vnetAddressPrefix: vnetAddressPrefix
    gatewaySubnetPrefix: gatewaySubnetPrefix
    defaultSubnetPrefix: defaultSubnetPrefix
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    sshSourceAddressPrefix: sshSourceAddressPrefix
    tags: tags
  }
}

module gallery 'modules/gallery/main.bicep' = {
  name: 'gallery-deployment'
  scope: rgGallery
  params: {
    location: location
    projectName: projectName
    tags: tags
  }
}

module keyVault 'modules/keyvault/main.bicep' = {
  name: 'keyvault-deployment'
  scope: rgKeyVault
  params: {
    location: location
    projectName: projectName
    ciServicePrincipalObjectId: ciServicePrincipalObjectId
    tags: tags
  }
}

output monitoringResourceGroup string = rgMonitoringName
output networkResourceGroup    string = rgNetworkName
output galleryResourceGroup    string = rgGalleryName
output keyVaultResourceGroup   string = rgKeyVaultName
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output vnetId                  string = networking.outputs.vnetId
output gatewaySubnetId         string = networking.outputs.gatewaySubnetId
output defaultSubnetId         string = networking.outputs.defaultSubnetId
output galleryName             string = gallery.outputs.galleryName
output imageDefinitionName     string = gallery.outputs.imageDefinitionName
output keyVaultName            string = keyVault.outputs.keyVaultName
output keyVaultId              string = keyVault.outputs.keyVaultId
