// workload.bicep — Workload (compute) infrastructure for the plaz environment
//
// Owns: compute RG + VM (gw1) + NIC + public IP + diagnostics.
//
// CAF tier: Workload.
// Trigger:  Per-PR on infra/** changes, or manual dispatch.
// Cadence:  Frequent.
//
// subnetId and logAnalyticsWorkspaceId are resolved at deploy time from the
// landing-zone-plaz deployment outputs by deploy-workload.yml and passed as
// environment variables read by readEnvironmentVariable() in the .bicepparam.
//
// See docs/architecture-refactor.md D4.

targetScope = 'subscription'

@description('Azure region for all resources')
param location string

@description('Project name used in resource naming')
param projectName string = 'plaz'

@description('Gateway short name (e.g. gw1, gw2). Must be unique per gateway VM across regions.')
param gatewayName string = 'gw1'

@description('VM size for the NixOS gateway VM')
param vmSize string = 'Standard_D4ads_v7'

@description('Admin username for the VM')
param adminUsername string = 'azureuser'

@description('SSH public key for VM access')
@secure()
@minLength(1)
param adminSshPublicKey string

@description('Gateway subnet resource ID (from landing-zone deployment outputs)')
param subnetId string

@description('Log Analytics workspace resource ID (from landing-zone deployment outputs)')
param logAnalyticsWorkspaceId string

@description('NixOS gallery image version resource ID (blessed image from image-bake). Empty = VM not deployed.')
param nixosImageId string = ''

@description('Base64-encoded cloud-init customData for first-boot host key injection (Option A). Empty for no-op re-runs.')
param customData string = ''

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
}

var rgComputeName = 'rg-${projectName}-compute-${location}'

resource rgCompute 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgComputeName
  location: location
  tags: tags
}

module compute 'modules/compute/main.bicep' = {
  name: 'compute-deployment'
  scope: rgCompute
  params: {
    location: location
    projectName: projectName
    gatewayName: gatewayName
    vmSize: vmSize
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    subnetId: subnetId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    nixosImageId: nixosImageId
    customData: customData
    tags: tags
  }
}

output computeResourceGroup string = rgComputeName
output vmPublicIp           string = compute.outputs.publicIpAddress
output vmName               string = compute.outputs.vmName
output vmId                 string = compute.outputs.vmId
