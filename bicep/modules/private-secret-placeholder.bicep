param vaultName string
param secretName string
param purpose string

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: vaultName
}
resource placeholder 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: vault
  name: secretName
  tags: {
    purpose: purpose
    state: 'initialization-pending'
  }
  properties: {
    value: 'NONSECRET_INITIALIZATION_PENDING'
    contentType: 'Nonsecret disabled bootstrap marker'
    attributes: { enabled: false }
  }
}
