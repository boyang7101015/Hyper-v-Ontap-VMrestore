<#
.SYNOPSIS
    Exports Hyper-V VM configuration metadata to XML and maintains 30-day retention.
.DESCRIPTION
    Collects configuration details for every VM on the host and writes them to XML files
    under a VMConfigBackup folder that sits alongside the script. Files older than
    30 days are purged automatically.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    # Determine backup directory relative to this script
    $scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    if (-not $scriptDirectory) {
        $scriptDirectory = Get-Location
    }
    $backupFolder = Join-Path -Path $scriptDirectory -ChildPath 'VMConfigBackup'

    if (-not (Test-Path -Path $backupFolder)) {
        Write-Host "Creating backup directory at $backupFolder" -ForegroundColor Yellow
        New-Item -Path $backupFolder -ItemType Directory | Out-Null
    }

    $virtualMachines = Get-VM
    if (-not $virtualMachines) {
        Write-Host 'No virtual machines were found on this host.' -ForegroundColor Yellow
    }

    foreach ($vm in $virtualMachines) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $fileName = "{0}_{1}.xml" -f $vm.Name, $timestamp
        $outputPath = Join-Path -Path $backupFolder -ChildPath $fileName

        Write-Host "Exporting configuration for VM '$($vm.Name)'" -ForegroundColor Green

        $xmlDocument = New-Object System.Xml.XmlDocument
        $xmlDeclaration = $xmlDocument.CreateXmlDeclaration('1.0','UTF-8',$null)
        $xmlDocument.AppendChild($xmlDeclaration) | Out-Null

        $vmElement = $xmlDocument.CreateElement('VM')
        $xmlDocument.AppendChild($vmElement) | Out-Null

        $properties = @{
            'Name' = $vm.Name
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

        $networkAdapters = Get-VMNetworkAdapter -VM $vm -ErrorAction SilentlyContinue
        foreach ($adapter in $networkAdapters) {
            $adapterElement = $xmlDocument.CreateElement('Adapter')
            $networkAdaptersElement.AppendChild($adapterElement) | Out-Null

            $adapterProperties = @{
                'Name' = $adapter.Name
                'MacAddress' = $adapter.MacAddress
                'SwitchName' = $adapter.SwitchName
                'VLAN' = ''
            }

            $vlanInfo = $null
            try {
                $vlanInfo = Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -ErrorAction Stop
            } catch {
                $vlanInfo = $null
            }

            if ($vlanInfo) {
                if ($vlanInfo.Mode -eq 'Access') {
                    $adapterProperties['VLAN'] = $vlanInfo.AccessVlanId
                } elseif ($vlanInfo.Mode -eq 'Trunk') {
                    $adapterProperties['VLAN'] = ($vlanInfo.TrunkVlanIdList -join ',')
                } else {
                    $adapterProperties['VLAN'] = ''
                }
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

        $disks = Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            $diskElement = $xmlDocument.CreateElement('Disk')
            $disksElement.AppendChild($diskElement) | Out-Null

            # Store controller number and location inside ControllerLocation element as Number:Location
            $controllerLocationValue = "{0}:{1}" -f $disk.ControllerNumber, $disk.ControllerLocation

            $diskProperties = @{
                'ControllerType' = $disk.ControllerType
                'ControllerLocation' = $controllerLocationValue
                'Path' = $disk.Path
            }

            foreach ($diskProperty in $diskProperties.GetEnumerator()) {
                $diskChild = $xmlDocument.CreateElement($diskProperty.Key)
                $diskChild.InnerText = [string]$diskProperty.Value
                $diskElement.AppendChild($diskChild) | Out-Null
            }
        }

        $xmlDocument.Save($outputPath)
    }

    # Retention: delete files older than 30 days
    $cutoff = (Get-Date).AddDays(-30)
    Get-ChildItem -Path $backupFolder -Filter '*.xml' -File | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
        Write-Host "Removing expired backup '$($_.Name)'" -ForegroundColor Yellow
        Remove-Item -Path $_.FullName -Force
    }

    Write-Host 'Hyper-V VM configuration export completed successfully.' -ForegroundColor Green
} catch {
    Write-Host "An error occurred: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
