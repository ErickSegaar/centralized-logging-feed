[CmdletBinding()]
param(
    $SubscriptionId,
    $ResourceGroupName,
    $ResourceGroupLocation,
    $EventhubNamespaceName,
    $KeyvaultName,
    $StorageAccountName
)

$appregistrationName = "LoggingFeed"

az login
az account set --subscription $SubscriptionId

#Create the resource group
az group create `
    --name $ResourceGroupName `
    --location $ResourceGroupLocation

#create appregistration with serviceprinciple and custom credential
$credentialDescription = "Logger"
$appregistration = ConvertFrom-json $( $(az ad app create --display-name $appregistrationName ) -join '')
az ad sp create --id $appregistration.appId
#Check if secret already exists, otherwise a potential multitude of same credential will be created
$clientSecret = $(ConvertFrom-json $( $(az ad app credential list `--id $appregistration.appId) -join '') ) | 
                                            where-object customKeyIdentifier -eq $credentialDescription
if  (-not $clientSecret)
{
    Write-Output "Client Secret not found with the name: $credentialDescription. Creating new Client Secret"
    $clientSecret = ConvertFrom-json $( $(az ad app credential reset `
                                            --id $appregistrationName `
                                            --credential-description $credentialDescription `
                                            --append ) -join '')
}
else {
    Write-Output "Using existing Client Secret"
}

#Create the eventhub
az eventhubs namespace create `
    --name $EventhubNamespaceName `
    --resource-group $ResourceGroupName `
    --location $ResourceGroupLocation `
    --sku Standard `
    --enable-auto-inflate `
    --maximum-throughput-units 20

$sharedAccessPolicyName = "DataReader"
az eventhubs namespace authorization-rule create `
    --resource-group $ResourceGroupName `
    --namespace-name $EventhubNamespaceName `
    --name $sharedAccessPolicyName `
    --rights Listen

az eventhubs namespace authorization-rule create `
    --resource-group $ResourceGroupName `
    --namespace-name $EventhubNamespaceName `
    --name DataWriter `
    --rights Send Manage Listen

$sharedAccessPolicy = ConvertFrom-json $( $(az eventhubs namespace authorization-rule keys list `
                                            --namespace-name $EventhubNamespaceName `
                                            --name $sharedAccessPolicyName `
                                            --resource-group $ResourceGroupName ) -join '' )

#create keyvault
az keyvault create `
    --location $ResourceGroupLocation `
    --name $KeyvaultName `
    --resource-group $ResourceGroupName

#add hub secrest
$secretnameEventHubName = "EventHubKey"
az keyvault secret set `
    --name $secretnameEventHubName `
    --vault-name $KeyvaultName `
    --value $sharedAccessPolicy.primaryKey

$eventhubSecret = ConvertFrom-Json $( $(az keyvault secret set-attributes `
                                            --content-type $sharedAccessPolicyName `
                                            --name $secretnameEventHubName `
                                            --vault-name $KeyvaultName  ) -join '' )

#add storage secrets
$secretnameADApplicationKeyName = "AzureADapplicationKey"
#if the clientsecret is created the password will be filled, when it existed then password won't exist and value will be null
if ($clientSecret.password){
    az keyvault secret set `
        --name $secretnameADApplicationKeyName `
        --vault-name $KeyvaultName `
        --value $clientSecret.password

    $ADApplicationSecret = ConvertFrom-Json $( $(az keyvault secret set-attributes `
                                                    --content-type $appregistration.appId `
                                                    --name $secretnameADApplicationKeyName `
                                                    --vault-name $KeyvaultName ) -join '')
}
else{
    $ADApplicationSecret = ConvertFrom-Json $( $( az keyvault secret show `
                                                    --name AzureADapplicationKey `
                                                    --vault-name $KeyvaultName ) -join '')
    if (-not $ADApplicationSecret)
    {
        write-error "Client secret already created without corresponding vault secret. Manually remove the application registration client secret $credentialDescription and rerun this script."
        exit 1
    }
}

#add access for application trough the policy
az keyvault set-policy `
    --name $KeyvaultName `
    --spn $appregistration.appId `
    --secret-permissions get `
    --resource-group $ResourceGroupName `

#Setup storage account for continuous export
az storage account create `
    --name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --location $ResourceGroupLocation `
    --sku Standard_LRS

$tenantid = ConvertFrom-Json $( $( az account get-access-token ) -join '') | Select-Object tenant

Write-Output "TenantId: $($tenantid.tenant)"
Write-Output "Application ID: $($appregistration.appId)"
Write-Output "Application Key: $(if ($clientSecret.password) { $($clientSecret.password) } else { $($ADApplicationSecret.value) } )"
Write-Output "Event Hub Namespace: $EventhubNamespaceName"
Write-Output "Event Hub Policy Name: $sharedAccessPolicyName" 
Write-Output "Event Hub Primary Key: $($sharedAccessPolicy.primaryKey)" 
Write-Output "Key Vault Name: $KeyvaultName"
Write-Output "Event Hub Key Secret Name: $secretnameEventHubName"
Write-Output "Event Hub Key Secret Version: $($eventhubSecret.id.split('/') | Select-Object -Last 1)"
Write-Output "Application Key Secret Name: $secretnameADApplicationKeyName "
Write-Output "Application Key Secret Version: $($ADApplicationSecret.id.split('/') | Select-Object -Last 1)"