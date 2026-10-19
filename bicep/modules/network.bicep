// Fresh deployment needs explicit outbound before VM extensions run.
// Preserve an existing lifecycle-created NAT; hibernation can still delete it.

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Name prefix used for vnet/nsg names')
param namePrefix string = 'arc-demo'

@description('Subnet name')
param subnetName string = 'snet-vms'

@description('Address space')
param addressPrefix string = '10.50.0.0/16'

@description('Subnet prefix')
param subnetPrefix string = '10.50.1.0/24'

@description('Optional existing NAT Gateway resource ID to attach to the subnet (preserves Activate-ArcDemo state on re-deploy)')
param existingNatGatewayId string = ''

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (empty(existingNatGatewayId)) {
  name: 'pip-natgw-${namePrefix}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (empty(existingNatGatewayId)) {
  name: 'natgw-${namePrefix}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [{ id: publicIp!.id }]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namePrefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: { id: nsg.id }
          natGateway: { id: empty(existingNatGatewayId) ? natGateway!.id : existingNatGatewayId }
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output subnetId string = '${vnet.id}/subnets/${subnetName}'
output nsgId string = nsg.id
