// Subscription-scope cost budget filtered to the two demo RGs.

targetScope = 'subscription'

@description('Monthly budget amount in subscription currency')
param amount int

@description('Email for budget notifications')
param adminEmail string

@description('Arc resource group name')
param arcResourceGroup string

@description('Infra resource group name')
param infraResourceGroup string

@description('Budget start date (must be first of a month, ISO)')
param startDate string = utcNow('yyyy-MM-01')

@description('Budget end date (2 years out, must be first of a month, ISO)')
param endDate string = '${string(int(substring(utcNow('yyyy'), 0, 4)) + 2)}-${utcNow('MM')}-01'

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'budget-arc-demo'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
      endDate: endDate
    }
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: [arcResourceGroup, infraResourceGroup]
      }
    }
    notifications: {
      Actual_50: {
        enabled: true, operator: 'GreaterThan', threshold: 50
        contactEmails: [adminEmail], thresholdType: 'Actual'
      }
      Actual_80: {
        enabled: true, operator: 'GreaterThan', threshold: 80
        contactEmails: [adminEmail], thresholdType: 'Actual'
      }
      Actual_100: {
        enabled: true, operator: 'GreaterThan', threshold: 100
        contactEmails: [adminEmail], thresholdType: 'Actual'
      }
      Forecast_100: {
        enabled: true, operator: 'GreaterThan', threshold: 100
        contactEmails: [adminEmail], thresholdType: 'Forecasted'
      }
    }
  }
}

output budgetId string = budget.id
