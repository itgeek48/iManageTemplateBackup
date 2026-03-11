# --- Configuration ---
$TargetHost = "https://target-imanage.com"
$TargetClientID = "your_target_client_id"
$TargetClientSecret = "your_target_client_secret"
$Username = "admin_user"
$Password = "admin_password"
$TargetLibrary = "TARGET_US"
$BackupFile = "iManage_Templates_Backup.json"

# --- 1. Authentication ---
$AuthBody = @{
    username      = $Username
    password      = $Password
    grant_type    = "password"
    client_id     = $TargetClientID
    client_secret = $TargetClientSecret
}
$AuthToken = Invoke-RestMethod -Method Post -Uri "$TargetHost/auth/oauth2/token" -Body $AuthBody
$Headers = @{ 
    "X-Auth-Token" = $AuthToken.access_token
    "Content-Type" = "application/json" 
}

# --- 2. Get Target Customer ID ---
$Discovery = Invoke-RestMethod -Method Get -Uri "$TargetHost/work/api/v2/customers/discovery" -Headers $Headers
$CustID = $Discovery.data.user.customer_id

# --- 3. Recursive Folder Create Function ---
function New-SubFolders($Children, $NewParentID) {
    foreach ($Child in $Children) {
        # Prepare the folder profile by removing read-only/system fields
        $Body = $Child.Profile | Select-Object * -ExcludeProperty id, parent_id, workspace_id, iwl, create_date, edit_date
        
        $Uri = "$TargetHost/work/api/v2/customers/$CustID/libraries/$TargetLibrary/folders/$NewParentID/subfolders"
        $Created = Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json)
        
        # If this folder has its own children, create them using the new ID
        if ($Child.Children) {
            New-SubFolders -Children $Child.Children -NewParentID $Created.data.id
        }
    }
}

# --- 4. Main Import Loop ---
$BackupData = Get-Content $BackupFile | ConvertFrom-Json

foreach ($Item in $BackupData) {
    Write-Host "Restoring Template: $($Item.Profile.name)"
    
    # A. Create the Template Shell
    $TmplBody = $Item.Profile | Select-Object * -ExcludeProperty id, create_date, edit_date, iwl
    $NewTmpl = Invoke-RestMethod -Method Post -Uri "$TargetHost/work/api/v2/customers/$CustID/libraries/$TargetLibrary/templates" -Headers $Headers -Body ($TmplBody | ConvertTo-Json)
    $NewTmplID = $NewTmpl.data.id

    # B. Create Root Tabs
    foreach ($Tab in $Item.Tabs) {
        $TabBody = $Tab | Select-Object * -ExcludeProperty id, workspace_id, iwl
        Invoke-RestMethod -Method Post -Uri "$TargetHost/work/api/v2/customers/$CustID/libraries/$TargetLibrary/workspaces/$NewTmplID/tabs" -Headers $Headers -Body ($TabBody | ConvertTo-Json)
    }

    # C. Create Root Folders and trigger subfolder creation
    foreach ($Folder in $Item.Folders) {
        $FolderBody = $Folder.Profile | Select-Object * -ExcludeProperty id, parent_id, workspace_id, iwl
        $RootCreated = Invoke-RestMethod -Method Post -Uri "$TargetHost/work/api/v2/customers/$CustID/libraries/$TargetLibrary/workspaces/$NewTmplID/folders" -Headers $Headers -Body ($FolderBody | ConvertTo-Json)
        
        if ($Folder.Children) {
            New-SubFolders -Children $Folder.Children -NewParentID $RootCreated.data.id
        }
    }
}
Write-Host "Migration Finished Successfully."