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
# Fetching Customer ID from the on-premise specific endpoint
$Discovery = Invoke-RestMethod -Method Get -Uri "$SourceHost/api" -Headers $Headers
$CustID = $Discovery.data.user.customer_id

# --- 3. Recursive Data Fetching Function ---
function Get-ContainerData($FolderID) {
    Write-Host "   Processing Container: $FolderID"

    # A. Get the Detailed Folder Profile
    # Required to get validated metadata (custom1-12, class, etc.)
    $ProfileUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$FolderID"
    $ProfileRes = Invoke-RestMethod -Method Get -Uri $ProfileUri -Headers $Headers
    
    # B. Get the Folder Security
    # Required to get default_security and specific user/group access levels
    $SecurityUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$FolderID/security"
    $SecurityRes = Invoke-RestMethod -Method Get -Uri $SecurityUri -Headers $Headers

    # C. Get Subfolders
    $SubUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$FolderID/subfolders"
    $SubRes = Invoke-RestMethod -Method Get -Uri $SubUri -Headers $Headers
    
    # Handle the on-premise 'results' array wrapper
    $Folders = if ($SubRes.data.results) { $SubRes.data.results } else { $SubRes.data }

    $ChildData = foreach ($f in $Folders) {
        # Recursive call to process nested folders
        Get-ContainerData -FolderID $f.id
    }

    return [PSCustomObject]@{
        Profile  = $ProfileRes.data
        Security = $SecurityRes # Includes default_security and the data array of users/groups
        Children = $ChildData
    }
}

# --- 4. Main Export Loop ---
Write-Host "Fetching list of templates from $Library..."
$TemplateUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/templates"
$TmplResponse = Invoke-RestMethod -Method Get -Uri $TemplateUri -Headers $Headers

# Extract results from on-premise data envelope
$Templates = $TmplResponse.data.results
$BackupData = @()

foreach ($Tmpl in $Templates) {
    Write-Host "Starting Export for Template: $($Tmpl.name)"
    
    # Get Root Folders and Root Tabs using Template ID as workspaceId
    $RootFolderUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/workspaces/$($Tmpl.id)/folders"
    $TabUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/workspaces/$($Tmpl.id)/tabs"
    
    $RootFoldersRes = Invoke-RestMethod -Method Get -Uri $RootFolderUri -Headers $Headers
    $TabsRes = Invoke-RestMethod -Method Get -Uri $TabUri -Headers $Headers
    
    $RFolders = if ($RootFoldersRes.data.results) { $RootFoldersRes.data.results } else { $RootFoldersRes.data }
    $RTabs = if ($TabsRes.data.results) { $TabsRes.data.results } else { $TabsRes.data }

    # Map root containers to the detailed profile/security function
    $FullFolderTree = foreach ($rf in $RFolders) { Get-ContainerData -FolderID $rf.id }
    $FullTabTree = foreach ($rt in $RTabs) { Get-ContainerData -FolderID $rt.id }

    $BackupData += [PSCustomObject]@{
        TemplateProfile = $Tmpl
        Folders         = $FullFolderTree
        Tabs            = $FullTabTree
    }
}

# --- 5. Save Final Backup ---
# Increased Depth to 20 to ensure deep nested security/folder objects are captured
$BackupData | ConvertTo-Json -Depth 20 | Out-File $BackupFile
Write-Host "SUCCESS: Full Backup saved to $BackupFile"