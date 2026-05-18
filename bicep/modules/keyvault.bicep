// Key Vault for the local admin password used by all demo VMs.

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Key Vault name (must be globally unique)')
param vaultName string

@description('Tenant ID')
param tenantId string

@description('Principal ID of the deploying user (for RBAC role assignment)')
param deployerPrincipalId string

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Key Vault Administrator role
var kvAdminRoleId = '00482a5a-887f-4fb3-b363-3b7fe8e74483'

resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, deployerPrincipalId, kvAdminRoleId)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvAdminRoleId)
  }
}

output vaultName string = kv.name
output vaultUri string = kv.properties.vaultUri
output vaultId string = kv.id
