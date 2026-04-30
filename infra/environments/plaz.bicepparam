using '../main.bicep'

param location = 'southcentralus'
param projectName = 'plaz'
param vmSize = 'Standard_D4ads_v7'
param adminUsername = 'azureuser'
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')
param vnetAddressPrefix = '192.168.85.0/24'
param gatewaySubnetPrefix = '192.168.85.0/28'
param defaultSubnetPrefix = '192.168.85.16/28'
param logRetentionDays = 30
param sshSourceAddressPrefix = '99.7.231.75/32'

// NixOS image version resource ID — provided by the stage-image workflow job.
// Falls back to empty string for validation-only runs (VM will not be deployed).
param nixosImageId = readEnvironmentVariable('NIXOS_IMAGE_ID', '')
