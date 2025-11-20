<#!
.SYNOPSIS
    Cluster-aware export of Hyper-V VM configuration metadata to a centralized NetApp SMB share.
.DESCRIPTION
    Runs only on the active cluster owner node to avoid duplicate exports. Enumerates every
    clustered virtual machine, captures key configuration details (CPU, memory, networking,
    storage), and writes them to XML files on the shared path \\\\by-hyper-v.bylab.local\\vm_config_bk.
    Retains 30 days of history per VM and prunes older files automatically.
.NOTES
    Author: Automation generated
    Requirements: Failover Clustering module, Hyper-V module, access to SMB backup path
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = "\\\\by-hyper-v.bylab.local\\vm_config_bk",
    [int]$RetentionDays = 30
)

$ErrorActionPreference = 'Stop'

Write-Host "Starting Hyper-V VM configuration backup..." -ForegroundColor Green

# Validate cluster ownership
$cluster = Get-Cluster
$owner = $cluster.OwnerNode.Name
$local = $env:COMPUTERNAME

if ($owner -ne $local) {
    Write-Host "Not the cluster owner. Skipping backup." -ForegroundColor Yellow
    return
}

# Ensure backup root exists
if (-not (Test-Path -Path $BackupRoot)) {
    Write-Host "Creating backup root at $BackupRoot" -ForegroundColor Yellow
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
}

# Gather all clustered VMs
$clusterGroups = Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine'
if (-not $clusterGroups) {
    Write-Host "No clustered virtual machines were found." -ForegroundColor Yellow
    return
}

foreach ($group in $clusterGroups) {
    $vmName = $group.Name
    $vmOwnerNode = $group.OwnerNode.Name

    Write-Host "Processing VM '$vmName' currently owned by '$vmOwnerNode'" -ForegroundColor Green

    try {
        $vm = Get-VM -ComputerName $vmOwnerNode -Name $vmName -ErrorAction Stop
    } catch {
        Write-Host "Failed to query VM '$vmName' on node '$vmOwnerNode': $_" -ForegroundColor Red
        continue
    }

    # Determine CSV volume from VM path
    $csvVolume = $null
    if ($vm.Path -match "^C:\\\\\\ClusterStorage\\\\([^\\\\]+)") {
        $csvVolume = $matches[1]
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $vmFolder = Join-Path -Path $BackupRoot -ChildPath $vmName
    if (-not (Test-Path -Path $vmFolder)) {
        New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
    }
    $fileName = "{0}_{1}.xml" -f $vmName, $timestamp
    $outputPath = Join-Path -Path $vmFolder -ChildPath $fileName

    # Build XML document
    $xmlDocument = New-Object System.Xml.XmlDocument
    $xmlDeclaration = $xmlDocument.CreateXmlDeclaration('1.0','UTF-8',$null)
    $xmlDocument.AppendChild($xmlDeclaration) | Out-Null

    $vmElement = $xmlDocument.CreateElement('VM')
    $xmlDocument.AppendChild($vmElement) | Out-Null

    $properties = @{
        'Name' = $vm.Name
        'OwnerNode' = $vmOwnerNode
        'CSVVolume' = $csvVolume
        'Generation' = $vm.Generation
        'CPU' = $vm.ProcessorCount
        'MemoryStartupBytes' = $vm.MemoryStartup
        'DynamicMemoryEnabled' = $vm.DynamicMemoryEnabled
        'DynamicMemoryMinBytes' = $vm.MemoryMinimum
        'DynamicMemoryMaxBytes' = $vm.MemoryMaximum
    }

    foreach ($property in $properties.GetEnumerator()) {
        $element = $xmlDocument.CreateElement($property.Key)
        $element.InnerText = [string]$property.Value
        $vmElement.AppendChild($element) | Out-Null
    }

    # Network adapters section
    $networkAdaptersElement = $xmlDocument.CreateElement('NetworkAdapters')
    $vmElement.AppendChild($networkAdaptersElement) | Out-Null

    $networkAdapters = Get-VMNetworkAdapter -VMName $vmName -ComputerName $vmOwnerNode -ErrorAction SilentlyContinue
    foreach ($adapter in $networkAdapters) {
        $adapterElement = $xmlDocument.CreateElement('Adapter')
        $networkAdaptersElement.AppendChild($adapterElement) | Out-Null

        $adapterProperties = @{
            'Name' = $adapter.Name
            'MacAddress' = $adapter.MacAddress
            'SwitchName' = $adapter.SwitchName
            'VLAN' = ''
        }

        try {
            $vlanInfo = Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -ComputerName $vmOwnerNode -ErrorAction Stop
            if ($vlanInfo) {
                switch ($vlanInfo.Mode) {
                    'Access' { $adapterProperties['VLAN'] = $vlanInfo.AccessVlanId }
                    'Trunk'  { $adapterProperties['VLAN'] = ($vlanInfo.TrunkVlanIdList -join ',') }
                    Default  { $adapterProperties['VLAN'] = '' }
                }
            }
        } catch {
            Write-Host "Unable to read VLAN info for adapter '$($adapter.Name)' on VM '$vmName': $_" -ForegroundColor Yellow
        }

        foreach ($adapterProperty in $adapterProperties.GetEnumerator()) {
            $adapterChild = $xmlDocument.CreateElement($adapterProperty.Key)
            $adapterChild.InnerText = [string]$adapterProperty.Value
            $adapterElement.AppendChild($adapterChild) | Out-Null
        }
    }

    # Disks section
    $disksElement = $xmlDocument.CreateElement('Disks')
    $vmElement.AppendChild($disksElement) | Out-Null

    $disks = Get-VMHardDiskDrive -VMName $vmName -ComputerName $vmOwnerNode -ErrorAction SilentlyContinue
    foreach ($disk in $disks) {
        $diskElement = $xmlDocument.CreateElement('Disk')
        $disksElement.AppendChild($diskElement) | Out-Null

        $diskProperties = @{
            'ControllerType' = $disk.ControllerType
            'ControllerLocation' = $disk.ControllerLocation
            'Path' = $disk.Path
        }

        foreach ($diskProperty in $diskProperties.GetEnumerator()) {
            $diskChild = $xmlDocument.CreateElement($diskProperty.Key)
            $diskChild.InnerText = [string]$diskProperty.Value
            $diskElement.AppendChild($diskChild) | Out-Null
        }
    }

    # Save XML
    $xmlDocument.Save($outputPath)
    Write-Host "Saved configuration for '$vmName' to '$outputPath'" -ForegroundColor Green

    # Retention cleanup
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $vmFolder -Filter "${vmName}_*.xml" | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
        Write-Host "Removing old backup file '$($_.FullName)'" -ForegroundColor Yellow
        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "VM configuration backup completed." -ForegroundColor Green
