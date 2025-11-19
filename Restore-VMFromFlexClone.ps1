<#
.SYNOPSIS
    Restores a Hyper-V virtual machine from a NetApp ONTAP FlexClone using saved XML metadata.
.DESCRIPTION
    Reads configuration exports from the VMConfigBackup folder, allows the operator to pick a VM
    and configuration timestamp, provisions a FlexClone from a selected snapshot, mounts the data
    via SMB, and rebuilds the VM as a brand-new instance without touching the original VM.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Prompt for required connection details
$ClusterMgmt = Read-Host 'Enter cluster management IP or FQDN'
$ONTAPUser = Read-Host 'Enter ONTAP username'
$ONTAPPassword = Read-Host 'Enter ONTAP password' -AsSecureString
$SourceVolume = Read-Host 'Enter ONTAP source volume hosting the VM folders'

# Bypass TLS certificate validation as required
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-ONTAPRestRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter()][object]$Body,
        [Parameter()][string]$Description
    )

    if ($Description) {
        Write-Host $Description -ForegroundColor Yellow
    }

    try {
        if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 10
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $jsonBody
        } else {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
        }
    } catch {
        Write-Host "REST call failed: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

$plainPassword = Convert-SecureStringToPlainText -SecureString $ONTAPPassword
$basicAuthBytes = [System.Text.Encoding]::UTF8.GetBytes("$ONTAPUser`:$plainPassword")
$basicToken = [Convert]::ToBase64String($basicAuthBytes)
$headers = @{
    Authorization = "Basic $basicToken"
    Accept = 'application/json'
    'Content-Type' = 'application/json'
}
$baseUri = "https://$ClusterMgmt"

# Locate backup folder and available XML files
$scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
if (-not $scriptDirectory) { $scriptDirectory = Get-Location }
$backupFolder = Join-Path -Path $scriptDirectory -ChildPath 'VMConfigBackup'

if (-not (Test-Path -Path $backupFolder)) {
    Write-Host "Backup folder '$backupFolder' does not exist." -ForegroundColor Red
    throw 'No configuration backups were found.'
}

$xmlFiles = Get-ChildItem -Path $backupFolder -Filter '*.xml' -File
if (-not $xmlFiles) {
    Write-Host 'No XML configuration files found in the backup folder.' -ForegroundColor Red
    throw 'No configuration backups available.'
}

$vmOptions = @()
foreach ($file in $xmlFiles) {
    try {
        [xml]$xmlContent = Get-Content -Path $file.FullName
        $vmName = $xmlContent.VM.Name
        if ([string]::IsNullOrWhiteSpace($vmName)) { continue }
        $vmOptions += [pscustomobject]@{ Name = $vmName; File = $file.FullName; Timestamp = $file.LastWriteTime }
    } catch {
        Write-Host "Failed to parse XML file '$($file.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$distinctVmNames = $vmOptions.Name | Sort-Object -Unique
if (-not $distinctVmNames) {
    Write-Host 'No valid VM metadata entries were found.' -ForegroundColor Red
    throw 'Metadata parsing failed.'
}

Write-Host 'Select the VM you want to restore:' -ForegroundColor Yellow
for ($i = 0; $i -lt $distinctVmNames.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i + 1), $distinctVmNames[$i]) -ForegroundColor Green
}

$vmSelection = $null
while (-not ($vmSelection -and $vmSelection -ge 1 -and $vmSelection -le $distinctVmNames.Count)) {
    $vmSelection = Read-Host 'Enter the number of the VM to restore'
    [void][int]::TryParse($vmSelection, [ref]$vmSelection)
}
$selectedVmName = $distinctVmNames[$vmSelection - 1]

$vmFiles = $vmOptions | Where-Object { $_.Name -eq $selectedVmName } | Sort-Object -Property Timestamp -Descending
Write-Host "Select the configuration timestamp for '$selectedVmName':" -ForegroundColor Yellow
for ($j = 0; $j -lt $vmFiles.Count; $j++) {
    Write-Host ("[{0}] {1}" -f ($j + 1), (Get-Item $vmFiles[$j].File).Name) -ForegroundColor Green
}

$configSelection = $null
while (-not ($configSelection -and $configSelection -ge 1 -and $configSelection -le $vmFiles.Count)) {
    $configSelection = Read-Host 'Enter the number of the configuration file'
    [void][int]::TryParse($configSelection, [ref]$configSelection)
}
$selectedConfigPath = $vmFiles[$configSelection - 1].File
[xml]$vmConfig = Get-Content -Path $selectedConfigPath
$vmData = $vmConfig.VM

# Get volume UUID
$encodedVolumeName = [System.Uri]::EscapeDataString($SourceVolume)
$volumeUri = "$baseUri/api/storage/volumes?name=$encodedVolumeName"
$volumeResponse = Invoke-ONTAPRestRequest -Method 'GET' -Uri $volumeUri -Headers $headers -Description "Retrieving UUID for volume '$SourceVolume'"
if (-not $volumeResponse.records) {
    Write-Host "Volume '$SourceVolume' was not found." -ForegroundColor Red
    throw 'Invalid volume name.'
}
$volumeRecord = $volumeResponse.records | Select-Object -First 1
$volumeUuid = $volumeRecord.uuid
$svmName = $volumeRecord.svm.name

# Get snapshots for the volume and filter unsupported names
$snapshotUri = "$baseUri/api/storage/volumes/$volumeUuid/snapshots"
$snapshotResponse = Invoke-ONTAPRestRequest -Method 'GET' -Uri $snapshotUri -Headers $headers -Description 'Retrieving snapshot list'
$availableSnapshots = @()
if ($snapshotResponse.records) {
    $availableSnapshots = $snapshotResponse.records | Where-Object { ($_ .name -notlike 'vserver*') -and ($_ .name -notlike 'snapmirror*') }
}

if (-not $availableSnapshots) {
    Write-Host 'No valid snapshots were returned for the specified volume.' -ForegroundColor Red
    throw 'Snapshot selection failed.'
}

Write-Host 'Select the snapshot to FlexClone:' -ForegroundColor Yellow
for ($k = 0; $k -lt $availableSnapshots.Count; $k++) {
    $snapshotName = $availableSnapshots[$k].name
    $snapshotTime = $availableSnapshots[$k].create_time
    Write-Host ("[{0}] {1} - {2}" -f ($k + 1), $snapshotName, $snapshotTime) -ForegroundColor Green
}
$snapshotSelection = $null
while (-not ($snapshotSelection -and $snapshotSelection -ge 1 -and $snapshotSelection -le $availableSnapshots.Count)) {
    $snapshotSelection = Read-Host 'Enter the number of the snapshot'
    [void][int]::TryParse($snapshotSelection, [ref]$snapshotSelection)
}
$selectedSnapshot = $availableSnapshots[$snapshotSelection - 1]

# Create FlexClone
$cloneName = "{0}_clone_{1}" -f $SourceVolume, (Get-Date).ToString('fff')
$cloneBody = @{
    name = $cloneName
    clone = @{
        parent_volume = @{ name = $SourceVolume }
        parent_snapshot = @{ name = $selectedSnapshot.name }
    }
    nas = @{ path = "/$cloneName" }
}
$cloneResponse = Invoke-ONTAPRestRequest -Method 'POST' -Uri "$baseUri/api/storage/volumes" -Headers $headers -Body $cloneBody -Description "Creating FlexClone '$cloneName'"
$cloneUuid = $cloneResponse.uuid
if (-not $cloneUuid) {
    Write-Host 'Failed to obtain FlexClone UUID from the response.' -ForegroundColor Red
    throw 'FlexClone creation failed.'
}

# Create SMB share for clone
$shareName = "clone_$cloneName"
$shareBody = @{
    name = $shareName
    path = "/$cloneName"
    svm = @{ name = $svmName }
}
$shareResponse = Invoke-ONTAPRestRequest -Method 'POST' -Uri "$baseUri/api/protocols/smb/shares" -Headers $headers -Body $shareBody -Description "Creating SMB share '$shareName'"
$shareUuid = $shareResponse.uuid
if (-not $shareUuid) {
    Write-Host 'Failed to obtain SMB share UUID from the response.' -ForegroundColor Red
    throw 'SMB share creation failed.'
}

$sharePath = "\\$svmName\$shareName"
$vmFolderPath = Join-Path -Path $sharePath -ChildPath $selectedVmName

if (-not (Test-Path -Path $vmFolderPath)) {
    Write-Host "VM folder '$vmFolderPath' was not found on the FlexClone." -ForegroundColor Red
    throw 'VM data folder missing on FlexClone.'
}

$vhdxFiles = Get-ChildItem -Path $vmFolderPath -Filter '*.vhdx' -File -Recurse
if (-not $vhdxFiles) {
    Write-Host 'No VHDX files were discovered inside the VM folder.' -ForegroundColor Red
    throw 'No disks found on FlexClone.'
}
$vhdxLookup = @{}
foreach ($diskFile in $vhdxFiles) {
    $vhdxLookup[$diskFile.Name.ToLower()] = $diskFile.FullName
}

# Prepare VM creation parameters
$originalVmName = $vmData.Name
$targetVmName = $originalVmName
if (Get-VM -Name $targetVmName -ErrorAction SilentlyContinue) {
    $targetVmName = "{0}-Restore-{1}" -f $originalVmName, (Get-Date).ToString('yyyyMMddHHmmss')
    Write-Host "Existing VM named '$originalVmName' detected. New VM will be created as '$targetVmName'." -ForegroundColor Yellow
}

$vmGeneration = [int]$vmData.Generation
$memoryStartupBytes = [int64]$vmData.MemoryStartupBytes
$cpuCount = [int]$vmData.CPU
$dynamicMemoryEnabled = [System.Convert]::ToBoolean($vmData.DynamicMemoryEnabled)
$memoryMinBytes = [int64]$vmData.DynamicMemoryMinBytes
$memoryMaxBytes = [int64]$vmData.DynamicMemoryMaxBytes

Write-Host "Creating new VM '$targetVmName'" -ForegroundColor Yellow
$null = New-VM -Name $targetVmName -Generation $vmGeneration -MemoryStartupBytes $memoryStartupBytes -NoVHD
Set-VMProcessor -VMName $targetVmName -Count $cpuCount
Set-VMMemory -VMName $targetVmName -DynamicMemoryEnabled:$dynamicMemoryEnabled -MinimumBytes $memoryMinBytes -MaximumBytes $memoryMaxBytes -StartupBytes $memoryStartupBytes

# Rebuild network configuration
Get-VMNetworkAdapter -VMName $targetVmName | ForEach-Object { Remove-VMNetworkAdapter -VMNetworkAdapter $_ }

$networkAdapters = @()
if ($vmData.NetworkAdapters.Adapter) {
    if ($vmData.NetworkAdapters.Adapter -is [System.Array]) {
        $networkAdapters = $vmData.NetworkAdapters.Adapter
    } else {
        $networkAdapters = @($vmData.NetworkAdapters.Adapter)
    }
}

foreach ($adapter in $networkAdapters) {
    $switchName = $adapter.SwitchName
    try {
        $null = Get-VMSwitch -Name $switchName -ErrorAction Stop
    } catch {
        Write-Host "Virtual switch '$switchName' was not found. Skipping adapter '$($adapter.Name)'." -ForegroundColor Yellow
        continue
    }

    $newAdapter = Add-VMNetworkAdapter -VMName $targetVmName -SwitchName $switchName -Name $adapter.Name
    if (-not [string]::IsNullOrWhiteSpace($adapter.MacAddress)) {
        Set-VMNetworkAdapter -VMNetworkAdapter $newAdapter -StaticMacAddress $adapter.MacAddress
    }

    if (-not [string]::IsNullOrWhiteSpace($adapter.VLAN)) {
        if ($adapter.VLAN -match ',') {
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $newAdapter -Trunk -AllowedVlanIdList $adapter.VLAN
        } else {
            $vlanId = 0
            if ([int]::TryParse($adapter.VLAN, [ref]$vlanId) -and $vlanId -gt 0) {
                Set-VMNetworkAdapterVlan -VMNetworkAdapter $newAdapter -Access -VlanId $vlanId
            }
        }
    }
}

# Attach disks from FlexClone
$diskEntries = @()
if ($vmData.Disks.Disk) {
    if ($vmData.Disks.Disk -is [System.Array]) {
        $diskEntries = $vmData.Disks.Disk
    } else {
        $diskEntries = @($vmData.Disks.Disk)
    }
}

foreach ($diskEntry in $diskEntries) {
    $controllerType = $diskEntry.ControllerType
    $controllerLocationValue = $diskEntry.ControllerLocation
    $controllerNumber = 0
    $controllerSlot = 0

    if ($controllerLocationValue -match ':') {
        $parts = $controllerLocationValue -split ':'
        if ($parts.Count -ge 2) {
            [void][int]::TryParse($parts[0], [ref]$controllerNumber)
            [void][int]::TryParse($parts[1], [ref]$controllerSlot)
        }
    } else {
        [void][int]::TryParse($controllerLocationValue, [ref]$controllerSlot)
    }

    $originalDiskPath = $diskEntry.Path
    $diskFileName = Split-Path -Path $originalDiskPath -Leaf
    $lowerName = $diskFileName.ToLower()
    $resolvedDiskPath = $null
    if ($vhdxLookup.ContainsKey($lowerName)) {
        $resolvedDiskPath = $vhdxLookup[$lowerName]
    } else {
        $fallbackPath = Join-Path -Path $vmFolderPath -ChildPath $diskFileName
        if (Test-Path -Path $fallbackPath) {
            $resolvedDiskPath = $fallbackPath
        }
    }

    if (-not $resolvedDiskPath) {
        Write-Host "Disk file '$diskFileName' could not be located on the FlexClone. Skipping this disk." -ForegroundColor Yellow
        continue
    }

    Write-Host "Attaching disk '$diskFileName' from '$resolvedDiskPath'" -ForegroundColor Green
    Add-VMHardDiskDrive -VMName $targetVmName -ControllerType $controllerType -ControllerNumber $controllerNumber -ControllerLocation $controllerSlot -Path $resolvedDiskPath
}

Write-Host 'Restore complete. Please verify that the VM boots successfully.' -ForegroundColor Green

# Optional cleanup
$cleanupChoice = Read-Host "Do you want to delete the FlexClone volume? Please confirm that no virtual machines are currently running on this volume. (Y/N)"
if ($cleanupChoice -match '^[Yy]') {
    if ($shareUuid) {
        Invoke-ONTAPRestRequest -Method 'DELETE' -Uri "$baseUri/api/protocols/smb/shares/$shareUuid" -Headers $headers -Description "Deleting SMB share '$shareName'" | Out-Null
        Write-Host "SMB share '$shareName' deleted." -ForegroundColor Green
    }
    if ($cloneUuid) {
        Invoke-ONTAPRestRequest -Method 'DELETE' -Uri "$baseUri/api/storage/volumes/$cloneUuid" -Headers $headers -Description "Deleting FlexClone '$cloneName'" | Out-Null
        Write-Host "FlexClone '$cloneName' deleted." -ForegroundColor Green
    }
} else {
    Write-Host 'FlexClone has been retained as requested.' -ForegroundColor Yellow
}
