@description('Region of the existing vault and VNet.')
param location string
param namePrefix string
param vaultName string
param vnetName string
param subnetName string = 'snet-vms'
param secretName string = 'arc-onboarding-client-secret'

@description('Only for first initialization; never redeploy a placeholder over an initialized secret.')
param initializeSecretScope bool = false

@description('Existing parent system-assigned principal IDs. No identities are created.')
param readerPrincipalIds array

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: vaultName
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: subnetName
}
resource secret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' existing = {
  parent: vault
  name: secretName
}
module placeholder 'private-secret-placeholder.bicep' = if (initializeSecretScope) {
  name: 'onboarding-secret-scope'
  params: {
    vaultName: vaultName
    secretName: secretName
    purpose: 'arc-demo-private-onboarding'
  }
}
resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${namePrefix}-onboarding-kv'
  location: location
  tags: { managedBy: 'arc-demo-private-onboarding' }
  properties: {
    customNetworkInterfaceName: 'pe-${namePrefix}-onboarding-kv-nic'
    subnet: { id: subnet.id }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}
resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: { managedBy: 'arc-demo-private-onboarding' }
}
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'link-${namePrefix}-onboarding-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}
resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: { privateDnsZoneId: zone.id }
      }
    ]
  }
}
var readerRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in readerPrincipalIds: {
  scope: secret
  name: guid(secret.id, principalId, readerRoleId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
  dependsOn: [placeholder]
}]
output privateEndpointId string = endpoint.id
output privateDnsZoneId string = zone.id
output linkId string = link.id
output zoneGroupId string = zoneGroup.id
output readerAssignmentIds array = [for (principalId, i) in readerPrincipalIds: readers[i].id]
