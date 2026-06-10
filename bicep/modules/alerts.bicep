// Action Group (email) + Scheduled Query Alert Rule for "host missing heartbeat > 10 min".

@description('Azure region (use global for action groups; alert rule needs a real region)')
param location string

@description('Resource tags')
param tags object

@description('Log Analytics workspace resource ID — alert query runs against this')
param workspaceId string

@description('Email address to notify on alerts')
param adminEmail string

@description('Name prefix used for AG / alert names')
param namePrefix string = 'arc-demo'

resource ag 'Microsoft.Insights/actionGroups@2024-10-01-preview' = {
  name: 'ag-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(replace(namePrefix, '-', ''), 12)
    enabled: true
    emailReceivers: [
      {
        name: 'admin-email'
        emailAddress: adminEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource alert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${namePrefix}-host-missing-heartbeat'
  location: location
  tags: tags
  properties: {
    displayName: 'Arc Demo — Host missing heartbeat (>10 min)'
    description: 'Fires when an Arc-monitored host has had no heartbeat for over 10 minutes.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [workspaceId]
    criteria: {
      allOf: [
        {
          query: 'Heartbeat | summarize LastSeen = max(TimeGenerated) by Computer | where LastSeen < ago(10m)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ag.id]
    }
  }
}

output actionGroupId string = ag.id
output alertRuleId string = alert.id
