# --- Configuration ---
$SourceHost = "https://source-imanage.com"
$SourceClientID = "your_source_client_id"
$SourceClientSecret = "your_source_client_secret"
$Username = "admin_user"
$Password = "admin_password"
$Library = "ACTIVE_US"
$BackupFile = "iManage_Templates_Backup.json"

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

# --- 2. Get Customer ID ---
$Discovery = Invoke-RestMethod -Method Get -Uri "$SourceHost/work/api/v2/customers/discovery" -Headers $Headers
$CustID = $Discovery.data.user.customer_id

# --- 3. Recursive Folder Export Function ---
function Get-SubFolders($ParentID) {
    $Uri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$ParentID/subfolders"
    $Result = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers
    $FolderList = @()
    foreach ($f in $Result.data) {
        $FolderList += [PSCustomObject]@{
            Profile = $f
            Children = Get-SubFolders -ParentID $f.id # Recursive call for nested folders
        }
    }
    return $FolderList
}

# --- 4. Main Export Loop ---
$Templates = Invoke-RestMethod -Method Get -Uri "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/templates" -Headers $Headers
$BackupData = @()

foreach ($Tmpl in $Templates.data) {
    Write-Host "Exporting Template: $($Tmpl.name)"
    
    # Get Root Level Folders and Tabs
    $RootFolders = Invoke-RestMethod -Method Get -Uri "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/workspaces/$($Tmpl.id)/folders" -Headers $Headers
    $Tabs = Invoke-RestMethod -Method Get -Uri "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/workspaces/$($Tmpl.id)/tabs" -Headers $Headers
    
    # Process Root Folders recursively
    $FullFolderTree = foreach ($rf in $RootFolders.data) {
        [PSCustomObject]@{
            Profile = $rf
            Children = Get-SubFolders -ParentID $rf.id
        }
    }

    $BackupData += [PSCustomObject]@{
        Profile = $Tmpl
        Folders = $FullFolderTree
        Tabs    = $Tabs.data
    }
}

# Save everything to a JSON file
$BackupData | ConvertTo-Json -Depth 15 | Out-File $BackupFile
Write-Host "Export Complete: $BackupFile"