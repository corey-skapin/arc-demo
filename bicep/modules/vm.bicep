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

@description('OS disk tier. Use Standard SSD for new OS disks; HDD is an explicit retained-lab choice with migration required before 8 September 2028.')
@allowed(['Standard_LRS', 'StandardSSD_LRS'])
param osDiskStorageAccountType string = 'StandardSSD_LRS'

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

@description('Image version')
param imageVersion string = 'latest'

@description('OS type: Windows or Linux')
@allowed(['Windows', 'Linux'])
param osType string

@description('Auto-shutdown time HHmm (24h) in the given timezone')
param autoShutdownTime string

@description('.NET timezone ID for auto-shutdown')
param autoShutdownTimezone string

@description('Optional data disks, each { name, lun, sizeGb, storageAccountType, caching }. Every disk is a standalone managed disk named <vmName>-<name> attached with createOption Attach, so a redeploy converges on an existing disk instead of detaching or recreating it.')
param dataDisks array = []

@description('Optional explicit VM security type, for example Standard for nested virtualization (Trusted Launch blocks it). Empty leaves the property unset, which keeps existing deployments unchanged.')
@allowed(['', 'Standard', 'TrustedLaunch'])
param securityType string = ''

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

resource dataDisk 'Microsoft.Compute/disks@2024-03-02' = [for disk in dataDisks: {
  name: '${vmName}-${disk.name}'
  location: location
  tags: tags
  sku: { name: disk.?storageAccountType ?? 'StandardSSD_LRS' }
  properties: {
    creationData: { createOption: 'Empty' }
    diskSizeGB: disk.sizeGb
  }
}]

// A null dataDisks leaves the property out of the request, so VMs without declared disks are unchanged.
var attachedDataDisks = [for (disk, i) in dataDisks: {
  lun: disk.lun
  name: dataDisk[i].name
  createOption: 'Attach'
  caching: disk.?caching ?? 'None'
  deleteOption: 'Detach'
  managedDisk: { id: dataDisk[i].id }
}]

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: empty(securityType) ? null : { securityType: securityType }
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
        version: imageVersion
      }
      osDisk: {
        // Disk name intentionally omitted so Azure auto-generates one. Hardcoding
        // it as ${vmName}-osdisk works on a fresh deploy but blocks any delta
        // update because Azure refuses to rename the OS disk of an existing VM.
        createOption: 'FromImage'
        managedDisk: { storageAccountType: osDiskStorageAccountType }
      }
      dataDisks: empty(dataDisks) ? null : attachedDataDisks
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
output vmName string = vm.name
output principalId string = vm.identity.principalId
