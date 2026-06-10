// Three Data Collection Rules:
//   - dcr-arc-demo:        perf counters, Win events, Linux syslog
//   - dcr-vminsights:      InsightsMetrics + ServiceMap
//   - dcr-changetracking:  CT extension config (files/software/registry/services/inventory)

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Log Analytics workspace resource ID')
param workspaceId string

@description('Log Analytics workspace name (used inside the DCR as the destination name)')
param workspaceName string

resource dcrCore 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-arc-demo'
  location: location
  tags: tags
  properties: {
    description: 'Core perf + events + syslog for the Arc demo fleet'
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounters'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor Information(_Total)\\% Processor Time'
            '\\Memory\\% Committed Bytes In Use'
            '\\Memory\\Available MBytes'
            '\\LogicalDisk(_Total)\\% Free Space'
            '\\Network Interface(*)\\Bytes Total/sec'
            '\\Processor(*)\\% Processor Time'
            '\\Memory(*)\\AvailableMemory'
            '\\Memory(*)\\PercentUsedMemory'
            '\\Logical Disk(*)\\FreeSpacePercentage'
            '\\Network(*)\\TotalBytesTransmitted'
            '\\Network(*)\\TotalBytesReceived'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'winEvents'
          streams: ['Microsoft-Event']
          xPathQueries: [
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Security!*[System[(band(Keywords,4503599627370496))]]'
          ]
        }
      ]
      syslog: [
        {
          name: 'linuxSyslog'
          streams: ['Microsoft-Syslog']
          facilityNames: ['auth', 'authpriv', 'cron', 'daemon', 'kern', 'syslog', 'user']
          logLevels: ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: workspaceName
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      { streams: ['Microsoft-Perf'],   destinations: [workspaceName] }
      { streams: ['Microsoft-Event'],  destinations: [workspaceName] }
      { streams: ['Microsoft-Syslog'], destinations: [workspaceName] }
    ]
  }
}

resource dcrVmi 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-vminsights'
  location: location
  tags: tags
  properties: {
    description: 'VM Insights DCR (perf + map)'
    dataSources: {
      performanceCounters: [
        {
          name: 'VMInsightsPerfCounters'
          streams: ['Microsoft-InsightsMetrics']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: ['\\VmInsights\\DetailedMetrics']
        }
      ]
      extensions: [
        {
          name: 'DependencyAgentDataSource'
          streams: ['Microsoft-ServiceMap']
          extensionName: 'DependencyAgent'
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'VMInsightsPerf-Logs-Dest'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      { streams: ['Microsoft-InsightsMetrics'], destinations: ['VMInsightsPerf-Logs-Dest'] }
      { streams: ['Microsoft-ServiceMap'],      destinations: ['VMInsightsPerf-Logs-Dest'] }
    ]
  }
}

resource dcrCt 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: 'dcr-changetracking'
}

output dcrCoreId string = dcrCore.id
output dcrVmiId string = dcrVmi.id
output dcrCtId string = dcrCt.id
