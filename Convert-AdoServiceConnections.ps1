# --- Prerequisites ---
<#
Azure CLI & Azure DevOps Extension: Ensure you have the latest CLI installed (az extension add --name azure-devops).
Permissions: You must be an administrator on the targeted service connections and have rights to update the underlying application credentials in your Microsoft Entra tenant (or plan to manually reconcile them if the automated Entra link fails).
Personal Access Token (PAT): A token scoped with Service Connections (Read & Manage) and Project and Team (Read) permissions.
#>

# --- CONFIGURATION ---
$OrganizationUrl = "https://azure.com"
$PAT = "YOUR_PERSONAL_ACCESS_TOKEN"
# ---------------------

# Authenticate with the REST API using your PAT
$B64Pat = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$PAT"))
$Headers = @{
    Authorization = "Basic $B64Pat"
    "Content-Type" = "application/json"
}

Write-Host "Fetching all projects in organization..." -ForegroundColor Cyan
$ProjectsUrl = "$OrganizationUrl/_apis/projects?api-version=7.1"
$ProjectsResponse = Invoke-RestMethod -Uri $ProjectsUrl -Method Get -Headers $Headers

foreach ($Project in $ProjectsResponse.value) {
    Write-Host "`nProcessing Project: $($Project.name)..." -ForegroundColor Blue
    
    # Retrieve all service connections for the project
    $EndpointsUrl = "$OrganizationUrl/$($Project.id)/_apis/serviceendpoint/endpoints?api-version=7.1"
    $EndpointsResponse = Invoke-RestMethod -Uri $EndpointsUrl -Method Get -Headers $Headers
    
    # Filter for WIF connections that are currently pointing to the deprecated Azure DevOps issuer
    $TargetConnections = $EndpointsResponse.value | Where-Object {
        $_.type -eq "azurerm" -and 
        $_.authorization.scheme -eq "WorkloadIdentityFederation" -and
        $_.authorization.parameters.issuer -like "*vstoken.dev.azure.com*"
    }
    
    if ($TargetConnections.Count -eq 0) {
        Write-Host "  No legacy WIF service connections found." -ForegroundColor Gray
        continue
    }
    
    foreach ($Connection in $TargetConnections) {
        Write-Host "  Found legacy connection: '$($Connection.name)' (ID: $($Connection.id))" -ForegroundColor Yellow
        Write-Host "  Current Issuer: $($Connection.authorization.parameters.issuer)" -ForegroundColor Gray
        
        # Construct the payload to initiate the in-place conversion to the Entra ID issuer
        # This toggles the native platform action parameter required for the Entra update flags
        $UpdatePayload = @{
            id = $Connection.id
            name = $Connection.name
            type = $Connection.type
            url = $Connection.url
            authorization = @{
                scheme = $Connection.authorization.scheme
                parameters = @{
                    tenantid = $Connection.authorization.parameters.tenantid
                    serviceprincipalid = $Connection.authorization.parameters.serviceprincipalid
                    # This specific flag forces the API to cycle the authentication structure to Entra ID
                    convertIssuer = $true 
                }
            }
            servicePrincipalObjectId = $Connection.servicePrincipalObjectId
            isReady = $Connection.isReady
        } | ConvertTo-Json -Depth 10
        
        # Execute the update call natively
        $UpdateUrl = "$OrganizationUrl/$($Project.id)/_apis/serviceendpoint/endpoints/$($Connection.id)?api-version=7.1"
        
        try {
            Write-Host "    Sending conversion request to Microsoft Entra issuer..." -ForegroundColor White
            $Result = Invoke-RestMethod -Uri $UpdateUrl -Method Put -Headers $Headers -Body $UpdatePayload
            
            # Re-fetch to evaluate if issuer conversion succeeded
            if ($Result.authorization.parameters.issuer -like "*login.microsoftonline.com*") {
                Write-Host "    [SUCCESS] Successfully converted '$($Connection.name)' to Microsoft Entra issuer!" -ForegroundColor Green
            } else {
                Write-Host "    [WARNING] API request returned, but issuer string did not change. Manual verification needed." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "    [ERROR] Failed to convert '$($Connection.name)' automatically. Error: $_" -ForegroundColor Red
            Write-Host "    Note: If this error is due to permissions on the App Registration, please verify your Entra administrative rights." -ForegroundColor DarkYellow
        }
    }
}

Write-Host "`nMigration process completed." -ForegroundColor Cyan
