targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
@allowed(['eastus', 'eastus2', 'westus', 'westus2', 'westus3'])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

param apiServiceName string = ''
param apiUserAssignedIdentityName string = ''
param applicationInsightsName string = ''
param logAnalyticsName string = ''
param resourceGroupName string = ''
param storageAccountName string = ''

param cosmosDatabaseName string = 'dev-snippet-db'
param cosmosContainerName string = 'code-snippets'

@allowed(['gpt-4o'])
param chatModelName string = 'gpt-4o'

@allowed(['text-embedding-3-small'])
param embeddingModelName string = 'text-embedding-3-small'

import * as regionSelector from './app/util/region-selector.bicep'
var abbrs = loadJsonContent('./abbreviations.json')

var resourcePrefix = 'snippy'
var labInstance = last(split(environmentName, '-'))
var resourceToken = 'snippymcplab${labInstance}'
var tags = { 'azd-env-name': environmentName }
var functionAppName = !empty(apiServiceName) ? apiServiceName : '${abbrs.webSitesFunctions}api-${resourceToken}'
var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'

var storageAccountActualName = !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : 'rg-snippymcplab'  
  location: location  
  tags: tags
}

// User assigned managed identity to be used by the function app
module apiUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'apiUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    name: !empty(apiUserAssignedIdentityName) ? apiUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}api-${resourceToken}'
  }
}

// Backing storage for Azure Functions api
module storage 'br/public:avm/res/storage/storage-account:0.8.3' = {
  name: 'storage'
  scope: rg
  params: {
    name: storageAccountActualName
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    blobServices: {
      containers: [{name: deploymentStorageContainerName}, {name: 'snippets'}]
    }
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

var StorageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var StorageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'

// Allow access from api to blob storage using a managed identity
module blobRoleAssignmentApi 'app/rbac/storage-access.bicep' = {
  name: 'blobRoleAssignmentapi'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: StorageBlobDataOwner
    principalID: apiUserAssignedIdentity.outputs.principalId
  }
}

// Allow access from api to queue storage using a managed identity
module queueRoleAssignmentApi 'app/rbac/storage-access.bicep' = {
  name: 'queueRoleAssignmentapi'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: StorageQueueDataContributor
    principalID: apiUserAssignedIdentity.outputs.principalId
  }
}

// Monitor application with Azure Monitor
module monitoring 'app/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
  }
}

var MonitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher role ID

// Allow access from api to application insights using a managed identity
module appInsightsRoleAssignmentApi './app/rbac/appinsights-access.bicep' = {
  name: 'appInsightsRoleAssignmentapi'
  scope: rg
  params: {
    appInsightsName: monitoring.outputs.applicationInsightsName
    roleDefinitionID: MonitoringMetricsPublisher
    principalID: apiUserAssignedIdentity.outputs.principalId
  }
}

// Azure OpenAI for embeddings
module openai './app/ai/cognitive-services.bicep' = {
  name: 'openai'
  scope: rg
  params: {
    location: regionSelector.getAiServicesRegion(location, chatModelName, embeddingModelName)
    tags: tags
    chatModelName: chatModelName
    aiServicesName: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    embeddingModelName: embeddingModelName
  }
}




// Azure Cosmos DB for snippet storage
module cosmosDb './app/cosmos-db.bicep' = {
  name: 'cosmosDb'
  scope: rg
  params: { 
    location: location
    tags: tags
    accountName: '${abbrs.documentDBDatabaseAccounts}${resourceToken}'
    databaseName: cosmosDatabaseName
    containerName: cosmosContainerName
    dataContributorIdentityIds: [
      apiUserAssignedIdentity.outputs.principalId
      deployer().objectId
    ]
  }
}


// Azure AI Hub and Project for code analysis
module aiProject './app/ai/ai-project.bicep' = {
  name: 'aiProject'
  scope: rg
  params: {
    location: regionSelector.getAiServicesRegion(location, chatModelName, embeddingModelName)
    tags: tags
    aiHubName: '${abbrs.machineLearningServicesWorkspaces}hub-${resourceToken}'
    aiProjectName: '${abbrs.machineLearningServicesWorkspaces}proj-${resourceToken}'
    storageAccountId: storage.outputs.resourceId
    keyVaultName: '${abbrs.keyVaultVaults}${resourceToken}'
    aiServicesEndpoint: openai.outputs.aiServicesEndpoint
    aiServicesId: openai.outputs.aiServicesId
    aiServicesName: openai.outputs.aiServicesName
  }
}

// Allow access from api to AI Project
var AzureAiDeveloper = '64702f94-c441-49e6-a78b-ef80e0188fee'
module aiProjectRoleAssignmentApi 'app/rbac/ai-project-access.bicep' = {
  name: 'aiProjectRoleAssignmentApi'
  scope: rg
  params: {
    aiProjectName: aiProject.outputs.aiProjectName
    roleDefinitionId: AzureAiDeveloper
    principalId: apiUserAssignedIdentity.outputs.principalId
  }
}

module api './app/api.bicep' = {
  name: 'api'
  scope: rg
  params: {
    name: functionAppName
    location: regionSelector.getFlexConsumptionRegion(location)
    tags: tags
    resourceToken: resourceToken
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    storageAccountName: storage.outputs.name
    deploymentStorageContainerName: deploymentStorageContainerName
    identityId: apiUserAssignedIdentity.outputs.resourceId
    identityClientId: apiUserAssignedIdentity.outputs.clientId
    aiServicesId: openai.outputs.aiServicesId
    appSettings: {
      COSMOS_ENDPOINT: cosmosDb.outputs.documentEndpoint
      COSMOS_DATABASE_NAME: cosmosDatabaseName
      COSMOS_CONTAINER_NAME: cosmosContainerName
      BLOB_CONTAINER_NAME: 'snippet-backups'
      EMBEDDING_MODEL_DEPLOYMENT_NAME: openai.outputs.embeddingDeploymentName
      AGENTS_MODEL_DEPLOYMENT_NAME: 'gpt-4o'
      COSMOS_VECTOR_TOP_K: '30'
      PROJECT_CONNECTION_STRING: aiProject.outputs.projectConnectionString
      AZURE_OPENAI_ENDPOINT: openai.outputs.aiServicesEndpoint
      AZURE_CLIENT_ID: apiUserAssignedIdentity.outputs.clientId
    }
  }
  dependsOn: [
    blobRoleAssignmentApi
    queueRoleAssignmentApi
    appInsightsRoleAssignmentApi
    aiProjectRoleAssignmentApi
  ]
}

// ==================================
// Outputs
// ==================================
// Define outputs needed specifically for configuring local.settings.json
// Use 'azd env get-values' to retrieve these after provisioning.
// WARNING: Secrets (Keys, Connection Strings) are output directly and will be visible in deployment history.
// Output names directly match the corresponding keys in local.settings.json for easier mapping.

@description('Cosmos DB endpoint. Output name matches the COSMOS_ENDPOINT key in local settings.')
output COSMOS_ENDPOINT string = cosmosDb.outputs.documentEndpoint

@description('Connection string for the Azure AI Project. Output name matches the PROJECT_CONNECTION_STRING key in local settings.')
output PROJECT_CONNECTION_STRING string = aiProject.outputs.projectConnectionString

@description('Endpoint for Azure OpenAI services. Output name matches the AZURE_OPENAI_ENDPOINT key in local settings.')
output AZURE_OPENAI_ENDPOINT string = openai.outputs.azureOpenAIServiceEndpoint

@description('Primary key for Azure OpenAI services. Output name matches the AZURE_OPENAI_KEY key in local settings.')
// @secure() - issue with latest bicep version, set secure in cognitive services module
output AZURE_OPENAI_KEY string = openai.outputs.primaryKey

@description('Name of the deployed Azure Function App.')
output AZURE_FUNCTION_NAME string = api.outputs.SERVICE_API_NAME // Function App Name

@description('Connection string for the Azure Storage Account. Output name matches the AzureWebJobsStorage key in local settings.')
output AZUREWEBJOBSSTORAGE string = storage.outputs.primaryBlobEndpoint
