<#!
.SYNOPSIS
    Cluster-aware export of Hyper-V VM configuration metadata to a centralized NetApp SMB share.
.DESCRIPTION
    Runs on any cluster node but executes only when the local node owns the core Failover Cluster
    group ("Cluster Group"), which is required for Windows Server 2025 compatibility. Enumerates
    every clustered virtual machine, collects CPU, memory, network, and disk metadata, and writes
    timestamped XML backups to the shared path \\by-hyper-v.bylab.local\vm_config_bk. The script
    maintains 30 days of history per VM and removes older backups automatically without impacting
    running workloads.
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

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Green','Yellow','Red')]
        [string]$Color = 'Green'
    )
    Write-Host $Message -ForegroundColor $Color
}

Write-Status -Message "Starting Hyper-V VM configuration backup..." -Color Green

# Validate core cluster group ownership (Windows Server 2025 requires this method)
try {
    $coreOwner = (Get-ClusterGroup -Name 'Cluster Group').OwnerNode.Name
    $localNode = $env:COMPUTERNAME
} catch {
    Write-Status -Message "Failed to determine core cluster group owner: $_" -Color Red
    exit 1
}

if ($coreOwner -ne $localNode) {
    Write-Status -Message "Not the core cluster owner node. Skipping backup." -Color Yellow
    exit 0
}

# Ensure backup root exists
if (-not (Test-Path -Path $BackupRoot)) {
    try {
        Write-Status -Message "Creating backup root at $BackupRoot" -Color Yellow
        New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    } catch {
        Write-Status -Message "Unable to create or access backup path '$BackupRoot': $_" -Color Red
        exit 1
    }
}

# Gather all clustered VMs
try {
    $clusterGroups = Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine'
} catch {
    Write-Status -Message "Failed to enumerate clustered virtual machines: $_" -Color Red
    exit 1
}

if (-not $clusterGroups) {
    Write-Status -Message "No clustered virtual machines were found." -Color Yellow
    exit 0
}

foreach ($group in $clusterGroups) {
    $vmName = $group.Name
    $vmOwnerNode = $group.OwnerNode.Name
    Write-Status -Message "Processing VM '$vmName' currently owned by '$vmOwnerNode'" -Color Green

    try {
        $vm = Get-VM -ComputerName $vmOwnerNode -Name $vmName -ErrorAction Stop
    } catch {
        Write-Status -Message "Failed to query VM '$vmName' on node '$vmOwnerNode': $_" -Color Red
        continue
    }

    # Determine CSV volume from VM configuration path
    $csvVolume = $null
    if ($vm.Path -match "^C:\\\\ClusterStorage\\\\([^\\\\]+)") {
        $csvVolume = $matches[1]
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $vmFolder = Join-Path -Path $BackupRoot -ChildPath $vmName
    if (-not (Test-Path -Path $vmFolder)) {
        try {
            New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
        } catch {
            Write-Status -Message "Unable to create folder '$vmFolder': $_" -Color Red
            continue
        }
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

    try {
        $networkAdapters = Get-VMNetworkAdapter -VMName $vmName -ComputerName $vmOwnerNode -ErrorAction Stop
    } catch {
        Write-Status -Message "Unable to read network adapters for VM '$vmName': $_" -Color Yellow
        $networkAdapters = @()
    }

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
            Write-Status -Message "Unable to read VLAN info for adapter '$($adapter.Name)' on VM '$vmName': $_" -Color Yellow
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

    try {
        $disks = Get-VMHardDiskDrive -VMName $vmName -ComputerName $vmOwnerNode -ErrorAction Stop
    } catch {
        Write-Status -Message "Unable to read virtual disks for VM '$vmName': $_" -Color Yellow
        $disks = @()
    }

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

    try {
        $xmlDocument.Save($outputPath)
        Write-Status -Message "Saved configuration for '$vmName' to '$outputPath'" -Color Green
    } catch {
        Write-Status -Message "Failed to save XML for VM '$vmName': $_" -Color Red
        continue
    }

    # Retention cleanup
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    try {
        Get-ChildItem -Path $vmFolder -Filter "${vmName}_*.xml" -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Write-Status -Message "Removing old backup file '$($_.FullName)'" -Color Yellow
                Remove-Item -Path $_.FullName -Force -ErrorAction Stop
            }
    } catch {
        Write-Status -Message "Retention cleanup encountered an issue for '$vmName': $_" -Color Yellow
    }
}

Write-Status -Message "VM configuration backup completed." -Color Green
