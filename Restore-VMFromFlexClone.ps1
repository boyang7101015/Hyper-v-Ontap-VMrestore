<#!
.SYNOPSIS
    Restores a Hyper-V virtual machine from a NetApp ONTAP snapshot via FlexClone without overwriting existing VMs.
.DESCRIPTION
    Loads a saved VM configuration XML from the centralized backup share, guides the operator through selecting
    an ONTAP snapshot, provisions a FlexClone and SMB3 share, verifies VM files inside the clone, and builds a
    brand-new Hyper-V VM with disks attached over SMB. The script never modifies existing VMs and offers optional
    cleanup to remove the FlexClone and share when finished.
.NOTES
    Author: Automation generated
    Requirements: Failover Clustering module, Hyper-V module, network access to ONTAP management LIF, access to SMB share
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Green','Yellow','Red')]
        [string]$Color = 'Green'
    )
    Write-Host $Message -ForegroundColor $Color
}

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

# Shared backup path
$backupRoot = "\\\\by-hyper-v.bylab.local\\vm_config_bk"

# Prompt for required inputs
$ClusterMgmt = Read-Host "Enter the ONTAP cluster management IP or FQDN"
$ONTAPUser = Read-Host "Enter the ONTAP username"
$ONTAPPassword = Read-Host "Enter the ONTAP password" -AsSecureString

# Allow self-signed certificates
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

$plainPassword = Convert-SecureStringToPlainText -SecureString $ONTAPPassword
$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($ONTAPUser):$plainPassword"))
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

        Write-Status -Message "Invoking ONTAP REST: $Method $Uri" -Color Green
        return Invoke-RestMethod @params
    } catch {
        Write-Status -Message "REST call failed: $_" -Color Red
        throw
    }
}

# Step 1 — Select VM XML metadata
if (-not (Test-Path -Path $backupRoot)) {
    Write-Status -Message "Backup root '$backupRoot' is not accessible." -Color Red
    exit 1
}

$xmlFiles = Get-ChildItem -Path $backupRoot -Filter '*.xml' -Recurse
if (-not $xmlFiles) {
    Write-Status -Message "No backup XML files were found under $backupRoot." -Color Red
    exit 1
}

$vmNames = $xmlFiles | ForEach-Object { $_.BaseName -replace '_\d{8}_\d{6}$','' } | Sort-Object -Unique
Write-Status -Message "Available VMs: $($vmNames -join ', ')" -Color Green
$selectedVmName = Read-Host "Enter the VM name to restore"

$vmXmlFiles = $xmlFiles | Where-Object { $_.BaseName -like "${selectedVmName}_*" } | Sort-Object LastWriteTime -Descending
if (-not $vmXmlFiles) {
    Write-Status -Message "No backups found for VM '$selectedVmName'." -Color Red
    exit 1
}

Write-Status -Message "Available backups for $($selectedVmName):" -Color Green
for ($i = 0; $i -lt $vmXmlFiles.Count; $i++) {
    Write-Status -Message "[$i] $($vmXmlFiles[$i].Name)" -Color Yellow
}
$selection = Read-Host "Enter the number of the backup to use"
[int]$selectionValue = -1
if (-not [int]::TryParse($selection, [ref]$selectionValue) -or $selectionValue -lt 0 -or $selectionValue -ge $vmXmlFiles.Count) {
    Write-Status -Message "Invalid selection." -Color Red
    exit 1
}

$chosenBackup = $vmXmlFiles[$selectionValue]
Write-Status -Message "Using backup file $($chosenBackup.FullName)" -Color Green

[xml]$vmConfig = Get-Content -Path $chosenBackup.FullName
$vmInfo = $vmConfig.VM

# Step 2 — Ask for ONTAP source volume
$sourceVolume = Read-Host "Enter the ONTAP source volume name"

# Step 3 — Select snapshot (after filtering)
$volumeInfo = Invoke-OntapApi -Method 'GET' -Uri "$baseUri/api/storage/volumes?name=$sourceVolume"
if (-not $volumeInfo.records -or -not $volumeInfo.records[0].uuid) {
    Write-Status -Message "Unable to locate volume '$sourceVolume'." -Color Red
    exit 1
}
$volumeUuid = $volumeInfo.records[0].uuid

$snapshotsResponse = Invoke-OntapApi -Method 'GET' -Uri "$baseUri/api/storage/volumes/$volumeUuid/snapshots"
$snapshots = $snapshotsResponse.records | Where-Object { $_.name -notlike 'vserver*' -and $_.name -notlike 'snapmirror*' }
if (-not $snapshots) {
    Write-Status -Message "No eligible snapshots found for volume '$sourceVolume'." -Color Red
    exit 1
}

Write-Status -Message "Available snapshots:" -Color Green
for ($i = 0; $i -lt $snapshots.Count; $i++) {
    Write-Status -Message "[$i] $($snapshots[$i].name)" -Color Yellow
}
$snapshotSelection = Read-Host "Enter the number of the snapshot to use"
[int]$snapshotValue = -1
if (-not [int]::TryParse($snapshotSelection, [ref]$snapshotValue) -or $snapshotValue -lt 0 -or $snapshotValue -ge $snapshots.Count) {
    Write-Status -Message "Invalid snapshot selection." -Color Red
    exit 1
}
$selectedSnapshot = $snapshots[$snapshotValue].name

# Step 4 — Create FlexClone volume
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
    Write-Status -Message "FlexClone creation did not return a UUID." -Color Red
    exit 1
}
Write-Status -Message "Created FlexClone '$cloneName' with UUID $cloneUuid" -Color Green

# Step 5 — Create SMB3 share for FlexClone
$shareName = "clone_$cloneName"
$shareBody = @{ name = $shareName; path = "/$cloneName" } | ConvertTo-Json -Depth 5
$shareResponse = Invoke-OntapApi -Method 'POST' -Uri "$baseUri/api/protocols/smb/shares" -Body $shareBody
$shareUuid = $shareResponse.uuid
Write-Status -Message "Created SMB share '$shareName'" -Color Green

# Step 6 — Locate VM folder in FlexClone
$vmFolder = "\\\\$ClusterMgmt\\$shareName\\$($vmInfo.Name)"
if (-not (Test-Path -Path $vmFolder)) {
    Write-Status -Message "VM folder '$vmFolder' not found in clone." -Color Red
    exit 1
}

$vhdxFiles = Get-ChildItem -Path $vmFolder -Filter '*.vhdx' -Recurse
if (-not $vhdxFiles) {
    Write-Status -Message "No VHDX files were found under '$vmFolder'." -Color Red
    exit 1
}

# Step 7 — Create NEW Hyper-V VM (never modify existing VM)
$defaultNewName = "{0}_Restored" -f $vmInfo.Name
$namePrompt = "Enter the NEW VM name [press Enter for $defaultNewName]"
$newVmName = Read-Host $namePrompt
if ([string]::IsNullOrWhiteSpace($newVmName)) { $newVmName = $defaultNewName }

if (Get-VM -Name $newVmName -ErrorAction SilentlyContinue) {
    Write-Status -Message "A VM named '$newVmName' already exists. Aborting to avoid overwrite." -Color Red
    exit 1
}

$newVmParams = @{
    Name = $newVmName
    Generation = [int]$vmInfo.Generation
    MemoryStartupBytes = [int64]$vmInfo.MemoryStartupBytes
    NoVHD = $true
}

Write-Status -Message "Creating new VM '$newVmName'" -Color Green
$newVm = New-VM @newVmParams

if ($vmInfo.DynamicMemoryEnabled -eq 'True') {
    Set-VMMemory -VMName $newVmName -DynamicMemoryEnabled $true -MinimumBytes ([int64]$vmInfo.DynamicMemoryMinBytes) -MaximumBytes ([int64]$vmInfo.DynamicMemoryMaxBytes)
} else {
    Set-VMMemory -VMName $newVmName -DynamicMemoryEnabled $false -StartupBytes ([int64]$vmInfo.MemoryStartupBytes)
}

Set-VMProcessor -VMName $newVmName -Count ([int]$vmInfo.CPU)

# Configure network adapters
foreach ($adapter in $vmInfo.NetworkAdapters.Adapter) {
    $adapterName = $adapter.Name
    $switchName = $adapter.SwitchName
    $mac = $adapter.MacAddress
    $vlan = [string]$adapter.VLAN

    $createdAdapter = Add-VMNetworkAdapter -VMName $newVmName -Name $adapterName -SwitchName $switchName
    if ($mac) { Set-VMNetworkAdapter -VMNetworkAdapter $createdAdapter -StaticMacAddress $mac }

    if ($vlan) {
        if ($vlan -like '*,*' -or $vlan -match ',') {
            $allowed = $vlan -split ',' | ForEach-Object { [int]$_ }
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $createdAdapter -Trunk -AllowedVlanIdList $allowed -NativeVlanId 0
        } else {
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $createdAdapter -Access -VlanId ([int]$vlan)
        }
    }
}

# Attach disks from clone
foreach ($disk in $vmInfo.Disks.Disk) {
    $leaf = Split-Path -Path $disk.Path -Leaf
    $candidatePath = Join-Path -Path $vmFolder -ChildPath $leaf

    $fileToUse = $candidatePath
    if (-not (Test-Path -Path $candidatePath)) {
        $found = Get-ChildItem -Path $vmFolder -Filter $leaf -Recurse | Select-Object -First 1
        if ($found) { $fileToUse = $found.FullName }
    }

    if (-not (Test-Path -Path $fileToUse)) {
        Write-Status -Message "Unable to locate disk '$leaf' for attachment." -Color Red
        continue
    }

    Write-Status -Message "Attaching VHDX '$fileToUse'" -Color Green
    Add-VMHardDiskDrive -VMName $newVmName -Path $fileToUse -ControllerType $disk.ControllerType -ControllerLocation ([int]$disk.ControllerLocation)
}

Write-Status -Message "Restore complete. Please verify that the VM boots successfully." -Color Green

# Step 9 — Optional cleanup
$cleanupChoice = Read-Host "Do you want to delete the FlexClone volume? Please confirm that no virtual machines are currently running on this volume. (Yes/No)"
if ($cleanupChoice -match '^(Yes|Y)$') {
    Write-Status -Message "Removing SMB share '$shareName'" -Color Yellow
    try {
        $shareLookup = Invoke-OntapApi -Method 'GET' -Uri "$baseUri/api/protocols/smb/shares?name=$shareName"
        if ($shareLookup.records -and $shareLookup.records[0].uuid) {
            Invoke-OntapApi -Method 'DELETE' -Uri "$baseUri/api/protocols/smb/shares/$($shareLookup.records[0].uuid)"
        }
    } catch {
        Write-Status -Message "Failed to remove SMB share: $_" -Color Red
    }

    Write-Status -Message "Deleting FlexClone volume '$cloneName'" -Color Yellow
    try {
        Invoke-OntapApi -Method 'DELETE' -Uri "$baseUri/api/storage/volumes/$cloneUuid"
        Write-Status -Message "FlexClone deleted." -Color Green
    } catch {
        Write-Status -Message "Failed to delete FlexClone: $_" -Color Red
    }
} else {
    Write-Status -Message "FlexClone retained as requested." -Color Yellow
}
