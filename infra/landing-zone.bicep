// landing-zone.bicep — Regional landing zone for one plaz environment
//
// Owns the resources that exist once per region:
//   - monitoring RG + Log Analytics workspace
//   - network RG    + VNET / subnets / NSGs / NAT gateway
//
// Project-wide (region-pinned) resources — the Compute Gallery and the
// project Key Vault — are NOT here; they live in infra/global.bicep and are
// deployed by .github/workflows/global.yml exactly once for the whole project.
// Consumers (image-bake.yml, deploy-workload.yml) read those names from the
// `global-${projectName}` subscription deployment outputs.
//
// CAF tier: Platform (regional).
// Trigger:  Manual or path-filtered push (see landing-zone.yml).
// Cadence:  Rare — only when network topology changes for a region.
//
// Outputs consumed by deploy-workload.yml at deploy time:
//   gatewaySubnetId, logAnalyticsWorkspaceId
//
// See docs/architecture-refactor.md D4.

targetScope = 'subscription'

@description('Azure region for all resources in this landing zone')
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

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
}

var rgMonitoringName = 'rg-${projectName}-monitoring-${location}'
var rgNetworkName    = 'rg-${projectName}-network-${location}'

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

output monitoringResourceGroup string = rgMonitoringName
output networkResourceGroup    string = rgNetworkName
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output vnetId                  string = networking.outputs.vnetId
output gatewaySubnetId         string = networking.outputs.gatewaySubnetId
output defaultSubnetId         string = networking.outputs.defaultSubnetId
