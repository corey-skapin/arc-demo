// Network: VNet + subnet + NSG. NAT GW is created separately
// by Activate-ArcDemo.ps1 so it can be torn down during hibernation.

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

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}'
  location: location
  tags: tags
  properties: {
    securityRules: []
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
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output subnetId string = '${vnet.id}/subnets/${subnetName}'
output nsgId string = nsg.id
