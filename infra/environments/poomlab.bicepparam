using '../main.bicep'

param location = 'southcentralus'
param projectName = 'poomlab'
param vmSize = 'Standard_D4ads_v7'
param adminUsername = 'azureuser'
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')
param vnetAddressPrefix = '192.168.85.0/24'
param gatewaySubnetPrefix = '192.168.85.0/28'
param defaultSubnetPrefix = '192.168.85.16/28'
param logRetentionDays = 30
param sshSourceAddressPrefix = '99.7.231.75/32'

// Set this to the resource ID of your custom NixOS image from nixos-azimage-builder
// Example: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/images/<name>'
// Leave empty to use Ubuntu 24.04 LTS as fallback
param nixosImageId = ''
