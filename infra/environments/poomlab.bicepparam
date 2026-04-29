using '../main.bicep'

param location = 'eastus2'
param projectName = 'poomlab'
param vmSize = 'Standard_D4ads_v7'
param adminUsername = 'azureuser'
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY', '')
param vnetAddressPrefix = '10.0.0.0/16'
param gatewaySubnetPrefix = '10.0.0.0/24'
param defaultSubnetPrefix = '10.0.1.0/24'
param logRetentionDays = 30

// Set this to the resource ID of your custom NixOS image from nixos-azimage-builder
// Example: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/images/<name>'
// Leave empty to use Ubuntu 24.04 LTS as fallback
param nixosImageId = ''
