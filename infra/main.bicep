// main.bicep — Subscription-level orchestrator
// Deploys all resource groups and modules for the poomlab environment

targetScope = 'subscription'

// =====================================================================
// Parameters
// =====================================================================

@description('Azure region for all resources')
param location string

@description('Project name used in resource naming')
param projectName string = 'poomlab'

@description('VM size for the NixOS gateway VM')
param vmSize string = 'Standard_D4ads_v7'

@description('Admin username for the VM')
param adminUsername string = 'azureuser'

@description('SSH public key for VM access')
@secure()
param adminSshPublicKey string

@description('VNET address space')
param vnetAddressPrefix string = '192.168.85.0/24'

@description('Gateway subnet address prefix')
param gatewaySubnetPrefix string = '192.168.85.0/26'

@description('Default subnet address prefix')
param defaultSubnetPrefix string = '192.168.85.64/26'

@description('Allowed source IP for SSH access. Default allows all — restrict for production.')
param sshSourceAddressPrefix string = '*'

@description('Log Analytics workspace retention in days')
param logRetentionDays int = 30

@description('Custom NixOS image resource ID (from nixos-azimage-builder)')
param nixosImageId string = ''

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
}

// =====================================================================
// Variables
// =====================================================================

var rgMonitoringName = 'rg-${projectName}-monitoring-${location}'
var rgNetworkName = 'rg-${projectName}-network-${location}'
var rgComputeName = 'rg-${projectName}-compute-${location}'

// =====================================================================
// Resource Groups
// =====================================================================

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

resource rgCompute 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgComputeName
  location: location
  tags: tags
}

// =====================================================================
// Module Deployments
// =====================================================================

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

module compute 'modules/compute/main.bicep' = {
  name: 'compute-deployment'
  scope: rgCompute
  params: {
    location: location
    projectName: projectName
    vmSize: vmSize
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    subnetId: networking.outputs.gatewaySubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    nixosImageId: nixosImageId
    tags: tags
  }
}

// =====================================================================
// Outputs
// =====================================================================

output monitoringResourceGroup string = rgMonitoringName
output networkResourceGroup string = rgNetworkName
output computeResourceGroup string = rgComputeName
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output vnetId string = networking.outputs.vnetId
output vmPublicIp string = compute.outputs.publicIpAddress
output vmName string = compute.outputs.vmName
