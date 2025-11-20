# Hyper-V Cluster VM Backup and NetApp FlexClone Restore

## Overview
This repository contains two production-ready PowerShell runbooks for Hyper-V Failover Clusters that centralize VM configuration backups on a NetApp SMB share and perform cluster-safe restores from ONTAP FlexClone volumes. The design targets Windows Server 2019/2022/2025 clusters and ONTAP 9.17.1+ REST APIs while preventing downtime or modification of existing VMs.

## System Architecture
- **Control Plane:** PowerShell executed on any cluster node.
- **Cluster State:** Core cluster group ownership determines execution for backups.
- **Storage:** NetApp ONTAP volumes exposed via SMB3; FlexClone volumes provide crash-consistent restores.
- **Backup Target:** Central share `\\by-hyper-v.bylab.local\vm_config_bk` for XML metadata.
- **Network:** Management access to ONTAP cluster LIF over HTTPS with basic authentication and certificate validation bypass (operator-confirmed).

### ASCII Architecture Diagram
```
+-------------------+        HTTPS (REST)        +---------------------------+
| Hyper-V Cluster   | -------------------------> | NetApp ONTAP Cluster      |
| (any node)        | <------------------------- | (Mgmt LIF)                |
|                   |       SMB3 (data)         |                           |
|  Export script -> | -> \\by-hyper-v... backup |                           |
|  Restore script <-| <- FlexClone SMB shares   | FlexClone + SMB share      |
+-------------------+                           +---------------------------+
```

## Components
### Export-HyperVVMConfig.ps1
- Runs only on the **core cluster group owner node** to avoid duplicate metadata.
- Enumerates every clustered VM, captures CPU, memory, network, and disk topology, and writes timestamped XML under the central share.
- Enforces per-VM retention of 30 days with automatic pruning.

### Restore-VMFromFlexClone.ps1
- Guides operators through selecting a VM XML, source volume, and snapshot.
- Creates an ONTAP FlexClone and SMB3 share, validates VM files, and builds a **new** Hyper-V VM with original settings.
- Offers optional cleanup to remove the FlexClone and share.

## Cluster-Aware Design
- Backup execution is gated by the owner of the **"Cluster Group"** resource, which is required for Windows Server 2025 where `Get-Cluster | Select OwnerNode` is unreliable.
- Restore runs safely on any node and never touches existing VMs, ensuring cluster stability.

## NetApp ONTAP REST API Integration
- Uses HTTPS with basic authentication and certificate validation override for lab or self-signed deployments.
- Wrapper function encapsulates `Invoke-RestMethod` with consistent error handling and status output.

## Snapshot Filtering Rules
- Excludes ONTAP snapshots whose names start with `vserver` or `snapmirror` to prevent selection of system or replication snapshots.

## FlexClone Creation Process
1. Lookup source volume UUID via `/api/storage/volumes?name=<volume>`.
2. List and filter snapshots under `/api/storage/volumes/<uuid>/snapshots`.
3. Create FlexClone with body:
   ```json
   {
     "name": "<clone_name>",
     "clone": {
       "parent_volume": { "name": "<source_volume>" },
       "parent_snapshot": { "name": "<snapshot>" }
     },
     "nas": { "path": "/<clone_name>" }
   }
   ```
4. Provision SMB3 share named `clone_<clone_name>` via `/api/protocols/smb/shares` with the NAS path.

## SMB3 Share Provisioning
- Each FlexClone receives a dedicated SMB share (`clone_<clone_name>`), enabling Hyper-V to attach VHDX files directly over UNC without mapping drives.

## Backup Design
- Metadata-only backups stored as XML, one folder per VM, named `<VMName>_<yyyyMMdd_HHmmss>.xml`.
- Gathers owner node, CSV volume, generation, CPU count, memory settings, NIC definitions (MAC, switch, VLAN), and disk layout (controller type, location, path).
- Retains 30 days of history per VM and removes older XML files automatically.

## Restore Design
- Loads operator-selected XML from the central share.
- Queries ONTAP for eligible snapshots, creates a FlexClone, and exposes it via SMB.
- Validates VM folder and VHDX presence within the clone.
- Recreates a **new** Hyper-V VM (never overwriting) with processor, memory, network, and disk settings applied.
- Optional cleanup removes the SMB share and deletes the FlexClone.

## Execution Flowcharts
### Export-HyperVVMConfig.ps1
```
Start
  |
  |-- Determine core cluster owner (Cluster Group)
  |   |-- Not owner -> Exit
  |
  |-- Ensure backup path exists
  |-- Enumerate clustered VMs
  |   |-- For each VM: gather CPU/memory/NIC/disk -> write XML -> prune >30d
  |
  |-- Complete
```

### Restore-VMFromFlexClone.ps1
```
Start
  |
  |-- Prompt credentials + cluster Mgmt + allow SSL bypass
  |-- Load XML list from backup share; operator selects VM + timestamp
  |-- Ask for source volume -> list snapshots (filter system/mirror)
  |-- Create FlexClone + SMB share
  |-- Locate VM folder + VHDX inside clone
  |-- Create NEW VM -> apply CPU/memory -> NICs (MAC/VLAN) -> attach disks
  |-- Success message
  |-- Optional: delete SMB share and FlexClone
```

## Permissions Required
- Hyper-V administrative rights on the cluster node running the scripts.
- Failover Clustering module access.
- SMB permissions to read/write `\\by-hyper-v.bylab.local\vm_config_bk`.
- ONTAP credentials with rights to query volumes/snapshots, create/delete volumes, and manage SMB shares.

## Troubleshooting
- **Backup skipped:** Ensure the node owns the "Cluster Group" resource (Windows Server 2025 behavior).
- **Access denied to SMB:** Verify network connectivity and permissions to the backup share or FlexClone share.
- **REST failures:** Confirm ONTAP management LIF is reachable over HTTPS and credentials are correct; check if certificate validation bypass is permitted in your environment.
- **Missing VHDX:** Validate the VM folder exists inside the FlexClone share and that the snapshot contains the VM files.

## Security Considerations
- Credentials are collected interactively and converted only for HTTP Basic headers; avoid storing plain-text credentials.
- SSL validation is bypassed intentionally per requirement; in production, use trusted certificates when possible.
- Scripts avoid modifying existing VMs and perform destructive FlexClone cleanup only after operator confirmation.

## Limitations
- Metadata-only backups do not capture VHDX contents.
- VLAN trunk recreation assumes comma-separated VLAN IDs for trunk lists.
- Requires SMB access from cluster nodes to ONTAP-hosted shares.

## Future Enhancements
- Integrate role-based access control for REST calls using ONTAP application accounts.
- Add logging to centralized Windows Event Logs or Syslog targets.
- Provide optional secure secret storage (e.g., Windows Credential Manager) for ONTAP credentials.

## Appendices
### Sample XML Structure
```xml
<VM>
    <Name>ExampleVM</Name>
    <OwnerNode>HVNODE01</OwnerNode>
    <CSVVolume>CSV01</CSVVolume>
    <Generation>2</Generation>
    <CPU>4</CPU>
    <MemoryStartupBytes>8589934592</MemoryStartupBytes>
    <DynamicMemoryEnabled>True</DynamicMemoryEnabled>
    <DynamicMemoryMinBytes>4294967296</DynamicMemoryMinBytes>
    <DynamicMemoryMaxBytes>17179869184</DynamicMemoryMaxBytes>
    <NetworkAdapters>
        <Adapter>
            <Name>ProductionNIC</Name>
            <MacAddress>00155D123456</MacAddress>
            <SwitchName>ProdSwitch</SwitchName>
            <VLAN>120</VLAN>
        </Adapter>
    </NetworkAdapters>
    <Disks>
        <Disk>
            <ControllerType>SCSI</ControllerType>
            <ControllerLocation>0</ControllerLocation>
            <Path>\\\\ClusterStorage\\\\CSV01\\\\VMs\\\\ExampleVM\\\\Virtual Hard Disks\\\\ExampleVM.vhdx</Path>
        </Disk>
    </Disks>
</VM>
```

### Sample API Payload
FlexClone creation payload used by the restore script:
```json
{
  "name": "vol1_clone_123",
  "clone": {
    "parent_volume": { "name": "vol1" },
    "parent_snapshot": { "name": "snap_daily" }
  },
  "nas": { "path": "/vol1_clone_123" }
}
```

### Example Script Output
```
Starting Hyper-V VM configuration backup...
Processing VM 'SQL01' currently owned by 'HVNODE02'
Saved configuration for 'SQL01' to \\by-hyper-v.bylab.local\vm_config_bk\SQL01\SQL01_20240101_010101.xml
VM configuration backup completed.
```
