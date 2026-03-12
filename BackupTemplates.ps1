# --- Configuration ---
$SourceHost = "https://your-onprem-server.com"
$SourceClientID = "your_client_id"
$SourceClientSecret = "your_client_secret"
$Username = "admin_user"
$Password = "admin_password"
$Library = "ACTIVE_US"
$BackupFile = "iManage_Full_Templates_Backup.json"

# --- 1. Authentication ---
$AuthBody = @{ 
    username      = $Username
    password      = $Password
    grant_type    = "password"
    client_id     = $SourceClientID
    client_secret = $SourceClientSecret 
}
$AuthToken = Invoke-RestMethod -Method Post -Uri "$SourceHost/auth/oauth2/token" -Body $AuthBody
$Headers = @{ "X-Auth-Token" = $AuthToken.access_token }

# --- 2. On-Premise Discovery ---
# Uses the on-premise specific endpoint to find the customer_id
$Discovery = Invoke-RestMethod -Method Get -Uri "$SourceHost/api" -Headers $Headers
$CustID = $Discovery.data.user.customer_id

# --- 3. Recursive Data Fetching Function ---
function Get-ContainerData($FolderID) {
    Write-Host "   Processing Container: $FolderID"

    # A. Get Detailed Folder Profile 
    # Returns metadata like custom1-12, class, and subclass aliases
    $ProfileUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$FolderID"
    $ProfileRes = Invoke-RestMethod -Method Get -Uri $ProfileUri -Headers $Headers
    
    # B. Get Folder Security
    # Returns default_security (inherit/private/etc.) and the user/group access list
    $SecurityUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$FolderID/security"
    $SecurityRes = Invoke-RestMethod -Method Get -Uri $SecurityUri -Headers $Headers

    # C. Get Sub-containers (Folders/Tabs)
    # Using the Library Folders endpoint with container_id returns all nested items
    $SubUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders?container_id=$FolderID"
    $SubRes = Invoke-RestMethod -Method Get -Uri $SubUri -Headers $Headers
    
    # Standardizing response handling for on-premise results array
    $Children = if ($SubRes.data.results) { $SubRes.data.results } else { $SubRes.data }

    $ChildData = foreach ($child in $Children) {
        # Recurse through the tree
        Get-ContainerData -FolderID $child.id
    }

    return [PSCustomObject]@{
        Profile  = $ProfileRes.data
        Security = $SecurityRes
        Children = $ChildData
    }
}

# --- 4. Main Export Loop ---
Write-Host "Fetching all templates from library: $Library..."
$TemplateUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/templates"
$TmplResponse = Invoke-RestMethod -Method Get -Uri $TemplateUri -Headers $Headers

$Templates = if ($TmplResponse.data.results) { $TmplResponse.data.results } else { $TmplResponse.data }
$BackupData = @()

foreach ($Tmpl in $Templates) {
    Write-Host "Starting Export for Template: $($Tmpl.name)"
    
    # Consolidated call to get all root-level containers (folders and tabs)
    $RootContainersUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders?container_id=$($Tmpl.id)"
    $RootContainersRes = Invoke-RestMethod -Method Get -Uri $RootContainersUri -Headers $Headers
    
    $RootItems = if ($RootContainersRes.data.results) { $RootContainersRes.data.results } else { $RootContainersRes.data }

    # Iterate through root items to fetch profiles, security, and sub-items
    $FullContainerTree = foreach ($item in $RootItems) { 
        Get-ContainerData -FolderID $item.id 
    }

    $BackupData += [PSCustomObject]@{
        TemplateProfile = $Tmpl
        Containers      = $FullContainerTree
    }
}

# --- 5. Save Final Backup ---
# Depth is set to 20 to ensure deeply nested JSON objects are fully serialized
$BackupData | ConvertTo-Json -Depth 20 | Out-File $BackupFile
Write-Host "SUCCESS: Comprehensive Template Backup saved to $BackupFile"