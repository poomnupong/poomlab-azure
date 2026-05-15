using '../workload.bicep'

param location                = 'southcentralus'
param projectName             = 'plaz'
param gatewayName             = 'gw1'
param vmSize                  = 'Standard_D4ads_v7'
param adminUsername           = 'azureuser'
param adminSshPublicKey       = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')

// Resolved at deploy time from landing-zone-plaz deployment outputs
// and set in $GITHUB_ENV by the "Resolve landing-zone outputs" step.
param subnetId                = readEnvironmentVariable('SUBNET_ID')
param logAnalyticsWorkspaceId = readEnvironmentVariable('LOG_ANALYTICS_WORKSPACE_ID')

// NixOS image version resource ID — resolved by deploy-workload.yml
// from gallery blessed=true tag. Falls back to empty for validation.
param nixosImageId            = readEnvironmentVariable('NIXOS_IMAGE_ID', '')

// Base64-encoded cloud-init customData for Option A host key injection.
// Empty for no-op re-runs where VM already exists with same image.
param customData              = readEnvironmentVariable('CUSTOM_DATA_B64', '')
