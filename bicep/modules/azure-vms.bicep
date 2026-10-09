targetScope = 'resourceGroup'

@description('Azure region for the Azure-native VM workload.')
param location string

@description('Common tags for Azure-native VM resources.')
param tags object

@description('Name prefix for Azure-native VM resources.')
param namePrefix string

@description('Subnet ID for Azure-native VM NICs.')
param subnetId string

@description('Admin username for Azure-native VMs.')
param adminUsername string

@description('Admin password for Azure-native VMs.')
@secure()
param adminPassword string

@description('VM SKU for Azure-native VMs.')
param vmSize string

@description('Auto-shutdown time HHmm (24h) in the given timezone.')
param autoShutdownTime string

@description('.NET timezone ID for auto-shutdown.')
param autoShutdownTimezone string

@description('Core Data Collection Rule resource ID that sends AMA performance and event data to the shared Log Analytics workspace.')
param dcrCoreId string

@description('VM Insights Data Collection Rule resource ID that sends InsightsMetrics and dependency data to the shared Log Analytics workspace.')
param dcrVmiId string

var safePrefix = toLower(replace(namePrefix, '_', '-'))
var shortPrefix = take(replace(safePrefix, '-', ''), 9)
var azureVms = [
  {
    name: 'az-${shortPrefix}-01'
    role: 'app'
    osType: 'Windows'
    osTier: 'WS2022'
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2022-datacenter-azure-edition'
    imageVersion: 'latest'
    supportsVmInsights: true
  }
]

module vmMods 'vm.bicep' = [for vm in azureVms: {
  name: 'native-vm-${vm.name}'
  params: {
    vmName: vm.name
    location: location
    tags: union(tags, {
      workload: 'azure-native-vm'
      demoPrefix: namePrefix
      role: vm.role
      ostype: toLower(vm.osType)
      osTier: toLower(vm.osTier)
      monitorTier: 'azure-native-ama'
    })
    vmSize: vmSize
    subnetId: subnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: vm.imagePublisher
    imageOffer: vm.imageOffer
    imageSku: vm.imageSku
    imageVersion: vm.imageVersion
    osType: vm.osType
    autoShutdownTime: autoShutdownTime
    autoShutdownTimezone: autoShutdownTimezone
  }
}]

resource nativeVmResources 'Microsoft.Compute/virtualMachines@2024-11-01' existing = [for vm in azureVms: {
  name: vm.name
}]

resource amaWindows 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = [for vm in azureVms: if (vm.osType == 'Windows') {
  name: '${vm.name}/AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [
    vmMods
  ]
}]

resource dependencyAgentWindows 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = [for vm in azureVms: if (vm.osType == 'Windows' && vm.supportsVmInsights) {
  name: '${vm.name}/DependencyAgentWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitoring.DependencyAgent'
    type: 'DependencyAgentWindows'
    typeHandlerVersion: '9.10'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [
    amaWindows
  ]
}]

resource dcrCoreAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [for (vm, i) in azureVms: {
  name: 'dcra-core-${vm.name}'
  scope: nativeVmResources[i]
  properties: {
    dataCollectionRuleId: dcrCoreId
    description: 'Core Arc demo logs and performance for Azure-native VM ${vm.name}.'
  }
  dependsOn: [
    vmMods
  ]
}]

resource dcrVmiAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [for (vm, i) in azureVms: if (vm.supportsVmInsights) {
  name: 'dcra-vmi-${vm.name}'
  scope: nativeVmResources[i]
  properties: {
    dataCollectionRuleId: dcrVmiId
    description: 'VM Insights data for Azure-native VM ${vm.name}.'
  }
  dependsOn: [
    dependencyAgentWindows
  ]
}]

var coreDcrAssociationIds = [for (vm, i) in azureVms: dcrCoreAssociations[i].id]
var vmiDcrAssociationIds = [for (vm, i) in azureVms: vm.supportsVmInsights ? dcrVmiAssociations[i].id : '']

output vmNames array = [for vm in azureVms: vm.name]
output resourceIds array = [for (vm, i) in azureVms: vmMods[i].outputs.vmId]
output principalIds array = [for (vm, i) in azureVms: vmMods[i].outputs.principalId]
output dcrAssociationIds array = concat(coreDcrAssociationIds, vmiDcrAssociationIds)
