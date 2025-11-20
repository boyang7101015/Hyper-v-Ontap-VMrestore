<#!
.SYNOPSIS
    Restores a Hyper-V virtual machine from a NetApp ONTAP snapshot via FlexClone without overwriting existing VMs.
.DESCRIPTION
    Loads a saved VM configuration XML, lets the operator pick an ONTAP snapshot, provisions a FlexClone,
    publishes an SMB3 share for the clone, validates the VM files, and builds a brand-new Hyper-V VM with
    VHDX files attached from the clone. Optional cleanup removes the FlexClone and share when finished.
.NOTES
    Author: Automation generated
    Requirements: Failover Clustering module, Hyper-V module, network access to ONTAP management LIF, access to SMB share
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Prompt for required inputs
$ClusterMgmt = Read-Host "Enter the ONTAP cluster management IP or FQDN"
$ONTAPUser = Read-Host "Enter the ONTAP username"
$ONTAPPassword = Read-Host "Enter the ONTAP password" -AsSecureString

# Allow self-signed certificates
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# Shared backup path
$backupRoot = "\\\\by-hyper-v.bylab.local\\vm_config_bk"

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory)]
        [System.Security.SecureString]$SecureString
    )
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

$plainPassword = Convert-SecureStringToPlainText -SecureString $ONTAPPassword
$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$ONTAPUser:$plainPassword"))
$baseUri = "https://$ClusterMgmt"

function Invoke-OntapApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body
    )
    try {
        $params = @{
            Method = $Method
            Uri = $Uri
            Headers = @{ Authorization = $authHeader }
            ContentType = 'application/json'
        }
        if ($Body) { $params['Body'] = $Body }

        Write-Host "Invoking ONTAP REST: $Method $Uri" -ForegroundColor Green
        return Invoke-RestMethod @params
    } catch {
        Write-Host "REST call failed: $_" -ForegroundColor Red
        throw
    }
}

# Step 1 - Load XML from centralized share
if (-not (Test-Path -Path $backupRoot)) {
    Write-Host "Backup root '$backupRoot' is not accessible." -ForegroundColor Red
    exit 1
}

$xmlFiles = Get-ChildItem -Path $backupRoot -Filter '*.xml' -Recurse
if (-not $xmlFiles) {
    Write-Host "No backup XML files were found under $backupRoot." -ForegroundColor Red
    exit 1
}

$vmNames = $xmlFiles | ForEach-Object { $_.BaseName -replace '_\\d{8}_\\d{6}$','' } | Sort-Object -Unique
Write-Host "Available VMs: $($vmNames -join ', ')" -ForegroundColor Green
$selectedVmName = Read-Host "Enter the VM name to restore"

$vmXmlFiles = $xmlFiles | Where-Object { $_.BaseName -like "${selectedVmName}_*" } | Sort-Object LastWriteTime -Descending
if (-not $vmXmlFiles) {
    Write-Host "No backups found for VM '$selectedVmName'." -ForegroundColor Red
    exit 1
}

Write-Host "Available backups for $selectedVmName:" -ForegroundColor Green
for ($i = 0; $i -lt $vmXmlFiles.Count; $i++) {
    Write-Host "[$i] $($vmXmlFiles[$i].Name)" -ForegroundColor Yellow
}
$selection = Read-Host "Enter the number of the backup to use"
if (-not [int]::TryParse($selection, [ref]$null) -or $selection -lt 0 -or $selection -ge $vmXmlFiles.Count) {
    Write-Host "Invalid selection." -ForegroundColor Red
    exit 1
}

$chosenBackup = $vmXmlFiles[$selection]
Write-Host "Using backup file $($chosenBackup.FullName)" -ForegroundColor Green

[xml]$vmConfig = Get-Content -Path $chosenBackup.FullName
$vmInfo = $vmConfig.VM

# Step 2 - Ask for ONTAP source volume
$sourceVolume = Read-Host "Enter the ONTAP source volume name"

# Step 3 - Select snapshot
$volumeInfo = Invoke-OntapApi -Method 'GET' -Uri "$baseUri/api/storage/volumes?name=$sourceVolume"
if (-not $volumeInfo.records -or -not $volumeInfo.records[0].uuid) {
    Write-Host "Unable to locate volume '$sourceVolume'." -ForegroundColor Red
    exit 1
}
$volumeUuid = $volumeInfo.records[0].uuid

$snapshotsResponse = Invoke-OntapApi -Method 'GET' -Uri "$baseUri/api/storage/volumes/$volumeUuid/snapshots"
$snapshots = $snapshotsResponse.records | Where-Object { $_.name -notlike 'vserver*' -and $_.name -notlike 'snapmirror*' }
if (-not $snapshots) {
    Write-Host "No eligible snapshots found for volume '$sourceVolume'." -ForegroundColor Red
    exit 1
}

Write-Host "Available snapshots:" -ForegroundColor Green
for ($i = 0; $i -lt $snapshots.Count; $i++) {
    Write-Host "[$i] $($snapshots[$i].name)" -ForegroundColor Yellow
}
$snapshotIndex = Read-Host "Enter the snapshot number to clone"
if (-not [int]::TryParse($snapshotIndex, [ref]$null) -or $snapshotIndex -lt 0 -or $snapshotIndex -ge $snapshots.Count) {
    Write-Host "Invalid snapshot selection." -ForegroundColor Red
    exit 1
}
$selectedSnapshot = $snapshots[$snapshotIndex].name

# Step 4 - Create FlexClone
$cloneSuffix = (Get-Date).ToString('fff')
$cloneName = "{0}_clone_{1}" -f $sourceVolume, $cloneSuffix
$cloneBody = @{
    name = $cloneName
    clone = @{ parent_volume = @{ name = $sourceVolume }; parent_snapshot = @{ name = $selectedSnapshot } }
    nas = @{ path = "/$cloneName" }
} | ConvertTo-Json -Depth 5

$cloneResponse = Invoke-OntapApi -Method 'POST' -Uri "$baseUri/api/storage/volumes" -Body $cloneBody
$cloneUuid = $cloneResponse.uuid
if (-not $cloneUuid) {
    Write-Host "FlexClone creation did not return a UUID." -ForegroundColor Red
    exit 1
}
Write-Host "Created FlexClone '$cloneName' with UUID $cloneUuid" -ForegroundColor Green

# Create SMB3 share
$shareName = "clone_$cloneName"
$shareBody = @{
    name = $shareName
    path = "/$cloneName"
} | ConvertTo-Json -Depth 5

$shareResponse = Invoke-OntapApi -Method 'POST' -Uri "$baseUri/api/protocols/smb/shares" -Body $shareBody
$shareUuid = $shareResponse.uuid
Write-Host "Created SMB share '$shareName'" -ForegroundColor Green

# Step 5 - Locate VM folder in FlexClone
$vmFolder = "\\\\$ClusterMgmt\\$shareName\\$($vmInfo.Name)"
if (-not (Test-Path -Path $vmFolder)) {
    Write-Host "VM folder '$vmFolder' not found in clone." -ForegroundColor Red
    exit 1
}

$vhdxFiles = Get-ChildItem -Path $vmFolder -Filter '*.vhdx' -Recurse
if (-not $vhdxFiles) {
    Write-Host "No VHDX files were found under '$vmFolder'." -ForegroundColor Red
    exit 1
}

# Step 6 - Create NEW Hyper-V VM
$defaultNewName = "{0}_Restored" -f $vmInfo.Name
$newVmName = Read-Host "Enter the NEW VM name" -Default $defaultNewName

if (Get-VM -Name $newVmName -ErrorAction SilentlyContinue) {
    Write-Host "A VM named '$newVmName' already exists. Aborting to avoid overwrite." -ForegroundColor Red
    exit 1
}

$newVmParams = @{
    Name = $newVmName
    Generation = [int]$vmInfo.Generation
    MemoryStartupBytes = [int64]$vmInfo.MemoryStartupBytes
    NoVHD = $true
}

Write-Host "Creating new VM '$newVmName'" -ForegroundColor Green
$newVm = New-VM @newVmParams

if ($vmInfo.DynamicMemoryEnabled -eq 'True') {
    Set-VMMemory -VMName $newVmName -DynamicMemoryEnabled $true -MinimumBytes ([int64]$vmInfo.DynamicMemoryMinBytes) -MaximumBytes ([int64]$vmInfo.DynamicMemoryMaxBytes)
}

Set-VMProcessor -VMName $newVmName -Count ([int]$vmInfo.CPU)

# Configure network adapters
foreach ($adapter in $vmInfo.NetworkAdapters.Adapter) {
    $adapterName = $adapter.Name
    $switchName = $adapter.SwitchName
    $mac = $adapter.MacAddress
    $vlan = $adapter.VLAN

    $createdAdapter = Add-VMNetworkAdapter -VMName $newVmName -Name $adapterName -SwitchName $switchName
    if ($mac) { Set-VMNetworkAdapter -VMNetworkAdapter $createdAdapter -StaticMacAddress $mac }
    if ($vlan) { Set-VMNetworkAdapterVlan -VMNetworkAdapter $createdAdapter -Access -VlanId ([int]$vlan) }
}

# Attach disks from clone
foreach ($disk in $vmInfo.Disks.Disk) {
    $leaf = Split-Path -Path $disk.Path -Leaf
    $candidatePath = Join-Path -Path $vmFolder -ChildPath $leaf

    $fileToUse = $candidatePath
    if (-not (Test-Path -Path $candidatePath)) {
        # Fallback: search for matching filename anywhere under VM folder
        $found = Get-ChildItem -Path $vmFolder -Filter $leaf -Recurse | Select-Object -First 1
        if ($found) { $fileToUse = $found.FullName }
    }

    if (-not (Test-Path -Path $fileToUse)) {
        Write-Host "Unable to locate disk '$leaf' for attachment." -ForegroundColor Red
        continue
    }

    Write-Host "Attaching VHDX '$fileToUse'" -ForegroundColor Green
    Add-VMHardDiskDrive -VMName $newVmName -Path $fileToUse -ControllerType $disk.ControllerType -ControllerLocation ([int]$disk.ControllerLocation)
}

Write-Host "Restore complete. Please verify that the VM boots successfully." -ForegroundColor Green

# Step 9 - Optional cleanup
$cleanupChoice = Read-Host "Do you want to delete the FlexClone volume? (Yes/No)"
if ($cleanupChoice -match '^(Yes|Y)$') {
    Write-Host "Removing SMB share '$shareName'" -ForegroundColor Yellow
    try {
        $shareLookup = Invoke-OntapApi -Method 'GET' -Uri "$baseUri/api/protocols/smb/shares?name=$shareName"
        if ($shareLookup.records -and $shareLookup.records[0].uuid) {
            Invoke-OntapApi -Method 'DELETE' -Uri "$baseUri/api/protocols/smb/shares/$($shareLookup.records[0].uuid)"
        }
    } catch {
        Write-Host "Failed to remove SMB share: $_" -ForegroundColor Red
    }

    Write-Host "Deleting FlexClone volume '$cloneName'" -ForegroundColor Yellow
    try {
        Invoke-OntapApi -Method 'DELETE' -Uri "$baseUri/api/storage/volumes/$cloneUuid"
        Write-Host "FlexClone deleted." -ForegroundColor Green
    } catch {
        Write-Host "Failed to delete FlexClone: $_" -ForegroundColor Red
    }
} else {
    Write-Host "FlexClone retained as requested." -ForegroundColor Yellow
}
