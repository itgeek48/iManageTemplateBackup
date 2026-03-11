# --- Configuration ---
$SourceHost = "https://your-onprem-server.com"
$SourceClientID = "your_client_id"
$SourceClientSecret = "your_client_secret"
$Username = "admin_user"
$Password = "admin_password"
$Library = "ACTIVE_US"
$BackupFile = "iManage_Templates_Backup.json"

# --- 1. Authentication ---
# (Using your existing working Auth code logic)
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
# On-premise uses 'GET /api' to find the customerId 
$Discovery = Invoke-RestMethod -Method Get -Uri "$SourceHost/api" -Headers $Headers
[cite_start]$CustID = $Discovery.data.user.customer_id # [cite: 7361, 7435]

# --- 3. Recursive Folder Export Function ---
function Get-SubFolders($ParentID) {
    # Endpoint for subfolders 
    $Uri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/folders/$ParentID/subfolders"
    $Result = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers
    $FolderList = @()
    
    # On-premise responses typically wrap the array in a 'results' field 
    $Folders = if ($Result.data.results) { $Result.data.results } else { $Result.data }
    
    foreach ($f in $Folders) {
        $FolderList += [PSCustomObject]@{
            Profile  = $f
            Children = Get-SubFolders -ParentID $f.id
        }
    }
    return $FolderList
}

# --- 4. Main Export Loop ---
# Endpoint to get templates [cite: 7417]
$TemplateUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/templates"
$TmplResponse = Invoke-RestMethod -Method Get -Uri $TemplateUri -Headers $Headers

# On-premise templates are returned in 'data.results' [cite: 7448, 7450]
$Templates = $TmplResponse.data.results
$BackupData = @()

foreach ($Tmpl in $Templates) {
    Write-Host "Exporting On-Prem Template: $($Tmpl.name)"
    
    # Get Root Level Folders [cite: 7428] and Tabs [cite: 7429]
    $RootFolderUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/workspaces/$($Tmpl.id)/folders"
    $TabUri = "$SourceHost/work/api/v2/customers/$CustID/libraries/$Library/workspaces/$($Tmpl.id)/tabs"
    
    $RootFoldersRes = Invoke-RestMethod -Method Get -Uri $RootFolderUri -Headers $Headers
    $TabsRes = Invoke-RestMethod -Method Get -Uri $TabUri -Headers $Headers
    
    # Standardizing on-premise 'results' array handling
    $RFolders = if ($RootFoldersRes.data.results) { $RootFoldersRes.data.results } else { $RootFoldersRes.data }
    $RTabs = if ($TabsRes.data.results) { $TabsRes.data.results } else { $TabsRes.data }

    $FullFolderTree = foreach ($rf in $RFolders) {
        [PSCustomObject]@{
            Profile  = $rf
            Children = Get-SubFolders -ParentID $rf.id
        }
    }

    $BackupData += [PSCustomObject]@{
        Profile = $Tmpl
        Folders = $FullFolderTree
        Tabs    = $RTabs
    }
}

# Save to JSON
$BackupData | ConvertTo-Json -Depth 15 | Out-File $BackupFile
Write-Host "On-Premise Backup Complete: $BackupFile"