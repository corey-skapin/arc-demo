using '../main.bicep'

param location = 'australiaeast'
param arcResourceGroup = 'rg-arc-demo'
param infraResourceGroup = 'rg-arc-demo-infra'
param tenantId = '00000000-0000-0000-0000-000000000000'
param deployerPrincipalId = '00000000-0000-0000-0000-000000000000'
param keyVaultName = 'kvarcdemomixed000'
param adminUsername = 'azureuser'
param adminPassword = readEnvironmentVariable('ARC_DEMO_ADMIN_PASSWORD')
param adminEmail = 'demo@example.com'
param namePrefix = 'arc-demo'
param deployArcOnPrem = true
param deployAzureVMs = false
param deployContainerApps = false
param deployAks = false
param onPremFleet = [
  {
    name: 'win-legacy-2012r2'
    role: 'legacy'
    osType: 'Windows'
    osTier: 'WS2012R2'
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2012-R2-Datacenter'
    imageVersion: 'latest'
    deploymentMode: 'azure-vm'
    monitorTier: 'arc-control-plane-only'
    supportsAzureMonitor: false
    supportsVmInsights: false
    supportsChangeTracking: false
    supportsSql: false
    esuEligible: true
  }
  {
    name: 'win-app-2016'
    role: 'app'
    osType: 'Windows'
    osTier: 'WS2016'
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2016-Datacenter'
    imageVersion: 'latest'
    deploymentMode: 'azure-vm'
    monitorTier: 'full-monitor'
    supportsAzureMonitor: true
    supportsVmInsights: true
    supportsChangeTracking: true
    supportsSql: false
    esuEligible: true
  }
  {
    name: 'win-app-2019'
    role: 'app'
    osType: 'Windows'
    osTier: 'WS2019'
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2019-datacenter-gensecond'
    imageVersion: 'latest'
    deploymentMode: 'azure-vm'
    monitorTier: 'full-monitor'
    supportsAzureMonitor: true
    supportsVmInsights: true
    supportsChangeTracking: true
    supportsSql: false
    esuEligible: false
  }
  {
    name: 'win-app-2022'
    role: 'app'
    osType: 'Windows'
    osTier: 'WS2022'
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2022-datacenter-azure-edition'
    imageVersion: 'latest'
    deploymentMode: 'azure-vm'
    monitorTier: 'full-monitor'
    supportsAzureMonitor: true
    supportsVmInsights: true
    supportsChangeTracking: true
    supportsSql: false
    esuEligible: false
  }
  {
    name: 'ws2008r2-represented'
    role: 'legacy'
    osType: 'Windows'
    osTier: 'WS2008R2'
    imagePublisher: 'represented'
    imageOffer: 'not-run'
    imageSku: 'nested-hyperv-or-doc-only'
    imageVersion: 'n/a'
    deploymentMode: 'represent-not-run'
    monitorTier: 'represent-not-run'
    supportsAzureMonitor: false
    supportsVmInsights: false
    supportsChangeTracking: false
    supportsSql: false
    esuEligible: false
  }
]
