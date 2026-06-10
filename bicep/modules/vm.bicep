// Deploys a single VM and its NIC, plus an auto-shutdown schedule.
// The OS image and OS-specific settings are caller-supplied.

@description('VM name')
param vmName string

@description('Azure region')
param location string

@description('Resource tags (caller should include role + ostype)')
param tags object

@description('VM SKU')
param vmSize string

@description('Subnet ID to attach the NIC to')
param subnetId string

@description('Admin username')
param adminUsername string

@description('Admin password (use Key Vault reference in the params file)')
@secure()
param adminPassword string

@description('Image publisher')
param imagePublisher string

@description('Image offer')
param imageOffer string

@description('Image SKU')
param imageSku string

@description('OS type: Windows or Linux')
@allowed(['Windows', 'Linux'])
param osType string

@description('Auto-shutdown time HHmm (24h) in the given timezone')
param autoShutdownTime string

@description('.NET timezone ID for auto-shutdown')
param autoShutdownTimezone string

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: osType == 'Windows' ? { enableAutomaticUpdates: true, provisionVMAgent: true } : null
      linuxConfiguration: osType == 'Linux' ? { disablePasswordAuthentication: false, provisionVMAgent: true } : null
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: autoShutdownTime }
    timeZoneId: autoShutdownTimezone
    targetResourceId: vm.id
    notificationSettings: { status: 'Disabled', timeInMinutes: 30 }
  }
}

output vmId string = vm.id
output principalId string = vm.identity.principalId
