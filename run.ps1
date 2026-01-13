param($eventGridEvent, $TriggerMetadata)

Import-Module Az.Resources
if (-not $?) {
    Write-Host "Failed to import Az.Resources module. Exiting script."
    exit 1
}

Import-Module Az.Accounts
if (-not $?) {
    Write-Host "Failed to import Az.Accounts module. Exiting script."
    exit 1
}

# Log the full event for debugging
Write-Host "INFORMATION: Full event details:"
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Get current date/time in Pacific timezone
$date = Get-Date -Format 'M/d/yyyy'
$timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), $timeZone.Id).ToString("hh:mmtt")

# Extract event data
$claims = $eventGridEvent.data.claims
$resourceId = $eventGridEvent.data.resourceUri
$operationName = $eventGridEvent.data.operationName
$subject = $eventGridEvent.subject
$principalType = $eventGridEvent.data.authorization.evidence.principalType

# Define excluded operations
$excludedOperations = @(
    "Microsoft.Resources/tags/write",
    "Microsoft.EventGrid/eventSubscriptions/write",
    "Microsoft.HybridCompute/machines/extensions/write",
    "Microsoft.EventGrid/systemTopics/write",
    "Microsoft.HybridCompute/machines/write",
    "Microsoft.Maintenance/configurationAssignments/write",
    "Microsoft.GuestConfiguration/guestConfigurationAssignments/write",
    "Microsoft.PolicyInsights/PolicyStates/write",
    "Microsoft.Compute/virtualMachines/extensions/write",
    "Microsoft.Compute/virtualMachines/installPatches/action",
    "Microsoft.Compute/virtualMachines/assessPatches/action",
    "Microsoft.PolicyInsights/policyStates/write",
    "Microsoft.PolicyInsights/attestations/write",
    "Microsoft.GuestConfiguration/configurationassignments/write",
    "Microsoft.Maintenance/updates/write",
    "Microsoft.Compute/virtualMachines/updateState/write",
    "Microsoft.Compute/restorePointCollections/restorePoints/write",
    "Microsoft.RecoveryServices/backup/write"
)

# Check for excluded operations
if ($excludedOperations -contains $operationName -or $operationName -like "Microsoft.RecoveryServices/backup/*") {
    Write-Host "Excluded operation type: $operationName. Skipping tagging."
    return
}

# Validate principal type
$allowedPrincipalTypes = @("User", "ServicePrincipal", "ManagedIdentity")
if ($principalType -notin $allowedPrincipalTypes) {
    Write-Host "Event initiated by $principalType. Skipping tagging for resource $resourceId"
    return
}

# Determine creator identity
$name = $claims.name
$email = $claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'

if ($name) {
    $creator = $name
}
elseif ($email) {
    $creator = $email
}
elseif ($principalType -eq "ServicePrincipal" -or $principalType -eq "ManagedIdentity") {
    $appid = $claims.appid
    $creator = "Service Principal ID " + $appid
}
else {
    $creator = "Unknown"
}

# Log extracted information
Write-Host "INFORMATION: Name: $name"
Write-Host "INFORMATION: Email: $email"
Write-Host "INFORMATION: Creator: $creator"
Write-Host "INFORMATION: Resource ID: $resourceId"
Write-Host "INFORMATION: Principal Type: $principalType"
Write-Host "INFORMATION: Date: $date"
Write-Host "INFORMATION: Time PST: $time_PST"
Write-Host "INFORMATION: Operation Name: $operationName"
Write-Host "INFORMATION: Subject: $subject"

# Define included resource types
$includedResourceTypes = @(
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Compute/virtualMachineScaleSets",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Sql/servers",
    "Microsoft.Sql/servers/databases",
    "Microsoft.KeyVault/vaults",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Web/sites",
    "Microsoft.Web/serverfarms",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.OperationalInsights/workspaces",
    "Microsoft.Resources/resourceGroups",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.AppConfiguration/configurationStores",
    "Microsoft.EventHub/namespaces",
    "Microsoft.ServiceBus/namespaces",
    "Microsoft.Relay/namespaces",
    "Microsoft.Cache/Redis",
    "Microsoft.Search/searchServices",
    "Microsoft.SignalRService/SignalR",
    "Microsoft.DataFactory/factories",
    "Microsoft.Logic/workflows",
    "Microsoft.MachineLearningServices/workspaces",
    "Microsoft.Insights/components",
    "Microsoft.Automation/automationAccounts",
    "Microsoft.RecoveryServices/vaults",
    "Microsoft.Network/trafficManagerProfiles"
)

# Get resource type and current tags
if ($resourceId -match "^/subscriptions/[^/]+/resourceGroups/[^/]+$") {
    $resourceType = "Microsoft.Resources/resourceGroups"
    Write-Host "INFORMATION: Resource Type: $resourceType"
    
    try {
        $resourceGroup = Get-AzResourceGroup -ResourceId $resourceId -ErrorAction Stop
        if (-not $resourceGroup) {
            Write-Host "Failed to retrieve resource group. Skipping tagging for resource group $resourceId"
            return
        }
        $currentTags = @{ Tags = $resourceGroup.Tags }
        Write-Host "INFORMATION: Retrieved resource group tags: $($currentTags | ConvertTo-Json)"
    }
    catch {
        Write-Host "ERROR: Failed to get resource group: $($_.Exception.Message)"
        Write-Host "ERROR: Full error: $_"
        return
    }
} 
else {
    try {
        $resource = Get-AzResource -ResourceId $resourceId -ErrorAction Stop
        if (-not $resource) {
            Write-Host "Failed to retrieve resource. Skipping tagging for resource $resourceId"
            return
        }
        $resourceType = $resource.ResourceType
        Write-Host "INFORMATION: Resource Type: $resourceType"
        
        Write-Host "DEBUG: Attempting to get current tags..."
        $currentTags = Get-AzTag -ResourceId $resourceId -ErrorAction Stop
        Write-Host "DEBUG: Current tags retrieved: $($currentTags | ConvertTo-Json -Depth 10)"
    }
    catch {
        Write-Host "ERROR: Failed to get resource or tags: $($_.Exception.Message)"
        Write-Host "ERROR: Full error: $_"
        return
    }
}

# Validate resource type
if (-not $resourceType -or $includedResourceTypes -notcontains $resourceType) {
    Write-Host "Resource type $resourceType is not in the included list. Skipping tagging for resource $resourceId"
    return
}

try {
    Write-Host "DEBUG: Checking for Creator tag..."
    Write-Host "DEBUG: Current tags structure: $($currentTags | ConvertTo-Json -Depth 10)"
    
    if (-not $currentTags -or -not $currentTags.Tags -or -not $currentTags.Tags.ContainsKey("Creator")) {
        Write-Host "INFORMATION: No Creator tag found - setting initial tags while preserving existing tags"
        
        # Initialize with any existing tags
        $tagsToUpdate = @{}
        if ($currentTags -and $currentTags.Tags) {
            Write-Host "DEBUG: Preserving existing tags:"
            $currentTags.Tags.GetEnumerator() | ForEach-Object {
                $tagsToUpdate[$_.Key] = $_.Value
                Write-Host "DEBUG: Preserved tag: $($_.Key) = $($_.Value)"
            }
        }

        # Add our new tags
        $tagsToUpdate["Creator"] = $creator
        $tagsToUpdate["DateCreated"] = $date
        $tagsToUpdate["TimeCreatedInPST"] = $time_PST
        $tagsToUpdate["LastModifiedBy"] = $creator
        $tagsToUpdate["LastModifiedDate"] = $date

        Write-Host "INFORMATION: Merging initial tags: $($tagsToUpdate | ConvertTo-Json)"
        $result = Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge
        Write-Host "DEBUG: Tag update result: $($result | ConvertTo-Json -Depth 10)"
    }
    else {
        Write-Host "INFORMATION: Creator tag exists - only updating LastModifiedBy and LastModifiedDate"
        Write-Host "DEBUG: Existing Creator tag value: $($currentTags.Tags["Creator"])"
        
        $modifiedTags = @{
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
        Write-Host "INFORMATION: Updating LastModified tags: $($modifiedTags | ConvertTo-Json)"
        $result = Update-AzTag -ResourceId $resourceId -Tag $modifiedTags -Operation Merge
        Write-Host "DEBUG: Tag update result: $($result | ConvertTo-Json -Depth 10)"
    }

    Write-Host "INFORMATION: Successfully updated tags for resource $resourceId"
}
catch {
    Write-Host "ERROR: Failed to update tags for resource $resourceId. Error: $($_.Exception.Message)"
    Write-Host "ERROR: Stack Trace: $($_.Exception.StackTrace)"
    Write-Host "ERROR: Full error object: $_"
}
