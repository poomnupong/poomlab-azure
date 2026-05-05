// main.bicep — Subscription-level orchestrator
// Deploys all resource groups and modules for the plaz environment

targetScope = 'subscription'

// =====================================================================
// Parameters
// =====================================================================

@description('Azure region for all resources')
param location string

@description('Project name used in resource naming')
param projectName string = 'plaz'

@description('VM size for the NixOS gateway VM')
param vmSize string = 'Standard_D4ads_v7'

@description('Admin username for the VM')
param adminUsername string = 'azureuser'

@description('SSH public key for VM access')
@secure()
@minLength(1)
param adminSshPublicKey string

@description('VNET address space')
param vnetAddressPrefix string = '192.168.85.0/24'

@description('Gateway subnet address prefix')
param gatewaySubnetPrefix string = '192.168.85.0/28'

@description('Default subnet address prefix')
param defaultSubnetPrefix string = '192.168.85.16/28'

@description('Log Analytics workspace retention in days')
param logRetentionDays int = 30

@description('Custom NixOS image resource ID (gallery image version from nixos-azimage-builder).  When empty the VM is not deployed — the stage-image workflow job populates this automatically.')
param nixosImageId string = ''

@description('Source address prefix for SSH access (e.g. your public IP in CIDR notation). Leave empty to omit the SSH rule.')
param sshSourceAddressPrefix string = ''

@description('Base64-encoded cloud-init customData for first-boot host key injection (Option A agenix key delivery). Contains the SSH host private key — must be treated as a secret. Leave empty for no-op deploys where VM already exists.')
@secure()
param customData string = ''

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
var rgGalleryName = 'rg-${projectName}-gallery-${location}'

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

resource rgGallery 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgGalleryName
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

module gallery 'modules/gallery/main.bicep' = {
  name: 'gallery-deployment'
  scope: rgGallery
  params: {
    location: location
    projectName: projectName
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
    customData: customData
    tags: tags
  }
}

// =====================================================================
// Outputs
// =====================================================================

output monitoringResourceGroup string = rgMonitoringName
output networkResourceGroup string = rgNetworkName
output computeResourceGroup string = rgComputeName
output galleryResourceGroup string = rgGalleryName
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output vnetId string = networking.outputs.vnetId
output galleryName string = gallery.outputs.galleryName
output imageDefinitionName string = gallery.outputs.imageDefinitionName
output vmPublicIp string = compute.outputs.publicIpAddress
output vmName string = compute.outputs.vmName
