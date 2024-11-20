#!/usr/bin/env pwsh

<#
.SYNOPSIS
Given an OVA file, extract the contents and import as a new VM using the Scale Computing REST API.

.PARAMETER Server
The hostname or LAN IP address to a Scale Computing Cluster to import the OVA to.

.PARAMETER Credential
User credentials used to authenticate with the server

.PARAMETER SkipCertificateCheck
Ignore Invalid/self-signed certificate errors

.PARAMETER OVA
Full path to the OVA archive

.PARAMETER PerformanceDrivers
Whether to use performance (VIRTIO) or compatible (IDE/E1000) device types. Generally, only use compatible for OS types (windows) that do not have drivers already installed/plan to be installed.

.PARAMETER GuestTools
Whether to automatically insert the guest tools iso containing performance drivers, windows guest agent, etc.

.PARAMETER DoNotCleanUp
Whether this script should cleanup the local unpacked ova contents and the uploaded vmdk disks on the HyperCore system when finished.

.PARAMETER Verbose
Increase console output verbosity (helpful when troubleshooting).

.EXAMPLE
./sc-ova-import.ps1 -Server ip-or-hostname -Credential (Get-Credential) -PerformanceDrivers y -GuestTools n -OVA /path/to/file.ova 
#>

[CmdletBinding()]

Param(
    [Parameter(Mandatory = $true,Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Server,
    [PSCredential] $Credential = (Get-Credential -Message "Enter SC//HyperCore Credentials"),
    [switch] $SkipCertificateCheck,
    [string] $OVA = (Read-Host -Prompt "Enter full path to OVA file: "),
    [string] $PerformanceDrivers = (Read-Host -Prompt "Performance Drivers? (y/n): "),
    [string] $GuestTools = (Read-Host -Prompt "Insert Guest Tools ISO for Windows? (y/n): "),
    [switch] $DoNotCleanup
)

$ErrorActionPreference = 'Stop';

# Create tmp directory and extract ova there
$tmp = [System.IO.Path]::GetTempPath()
$ovaFileName = Split-Path -Path $OVA -Leaf
$tmpDir = Join-Path $tmp $ovaFileName
if (Test-Path $tmpDir) {
    Write-Verbose "Removing $tmpDir..."
    Remove-Item -Path $tmpDir -Recurse
}
New-Item -Path "$tmpDir" -ItemType Directory
tar -C "$tmpDir" -xvf $OVA
$vmdkList = Get-ChildItem $tmpDir/*.vmdk
[xml]$ovf = Get-Content (Get-ChildItem "$tmpDir/*.ovf")


# Set up for rest API
$url = "https://$Server/rest/v1"
$restOpts = @{
    Credential = $Credential
    ContentType = 'application/json'
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    $restOpts.SkipCertificateCheck = $SkipCertificateCheck
}
elseif ($SkipCertificateCheck) {
    try
    {
        add-type -ErrorAction stop @"
            using System.Net;
            using System.Security.Cryptography.X509Certificates;
            public class TrustAllCertsPolicy : ICertificatePolicy {
                public bool CheckValidationResult(
                    ServicePoint srvPoint, X509Certificate certificate,
                    WebRequest request, int certificateProblem) {
                    return true;
                }
            }
"@
    } catch { write-error "Failed to create TrustAllCertsPolicy: $_" }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}
$restUploadOpts = @{
    Credential = $Credential
    ContentType = "application/octet-stream"
    SkipCertificateCheck = $restOpts.SkipCertificateCheck
}


[bool]$usePerformanceDrivers = $false
if ($PerformanceDrivers -eq "Y" -or $PerformanceDrivers -eq "y") {
    $usePerformanceDrivers = $true
}

# TODO actually insert the iso or remove
[bool]$attachGuestTools = $false
if ($GuestTools -eq "Y" -or $GuestTools -eq "y") {
    Write-Host "Will insert the SC//Guest Tools ISO for Windows!"
    $attachGuestTools = $true
}


# copy/pasta: Ensure tasks are complete before taking the next step
function Wait-ScaleTask {
    Param(
        [Parameter(Mandatory = $true,Position  = 1, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $TaskTag
    )

    $retryDelay = [TimeSpan]::FromSeconds(1)
    $timeout = [TimeSpan]::FromSeconds(300)

    $timer = [Diagnostics.Stopwatch]::new()
    $timer.Start()

    Write-Verbose "Waiting $timeout seconds for Task '$TaskTag' to complete.."

    while ($timer.Elapsed -lt $timeout)
    {
        Start-Sleep -Seconds $retryDelay.TotalSeconds
        $taskStatus = Invoke-RestMethod @restOpts "$url/TaskTag/$TaskTag" -Method GET

        if ($taskStatus.state -eq 'ERROR') {
            throw "Task '$TaskTag' failed!"
        }
        elseif ($taskStatus.state -eq 'COMPLETE') {
            Write-Verbose "Task '$TaskTag' completed!"
            return
        }
    }
    throw [TimeoutException] "Task '$TaskTag' failed to complete in $($timeout.Seconds) seconds"
}

# TODO error out if import was previously attempted and left around cruft


$initialDesc = "Importing-$ovaFileName"
Write-Host "Creating VM $initialDesc on HyperCore..."
# TODO - does this only work on virtualbox exports?
$vmMachineType = if ($ovf.Envelope.VirtualSystem.Machine.Hardware.Firmware.type -eq 'EFI') { "uefi" } else { "bios" }
$json = @{
    dom = @{
        name = $initialDesc
        desc = $initialDesc
        mem = 0
        numVCPU = 0
    }
    options = @{
         machineTypeKeyword = $vmMachineType
    }
} | ConvertTo-Json -Depth 100
$result = Invoke-RestMethod @restOpts "$url/VirDomain/"  -Method POST -Body $json
$vmUUID = $($result.createdUUID)
Wait-ScaleTask -TaskTag $($result.taskTag)
Write-Host "HyperCore VM $vmUUID created for OVA import!"


foreach ($vmdk in $vmdkList) {
    $vmdkFileName = Split-Path -Path $vmdk -Leaf
    $vmdkSize = (Get-Item $vmdk).Length
    $vmdkPayload = [System.IO.File]::ReadAllBytes($vmdk)
    Write-Host "Beginning upload of $vmdkFileName..."
    $result = Invoke-RestMethod @restUploadOpts "$url/VirtualDisk/upload?filename=$vmdkFileName&filesize=$vmdkSize" -Method PUT -Body $vmdkPayload
    $uploadedUUID = $($result.createdUUID)
    Write-Host "Wait 90 seconds for disk to be converted"
    Start-Sleep -Seconds 90
    Write-Host "Finished uploading $vmdkFileName (uuid: $uploadedUUID)! Attaching as new block device to VM..."
    $json = @{
        template = @{
            virDomainUUID = $vmUUID
            type = if ($usePerformanceDrivers) { "VIRTIO_DISK" } else { "IDE_DISK" }
            capacity = $vmdkSize
        }
        options = @{
            regenerateDiskID = $false
        }
    } | ConvertTo-Json -Depth 100
    $result = Invoke-RestMethod @restOpts "$url/VirtualDisk/$uploadedUUID/attach" -Method POST -Body $json
    Wait-ScaleTask -TaskTag $($result.taskTag)
    $attachedBlockDevUUID = $($result.createdUUID)
    Write-Host "Attached uploaded $vmdk as new blockdevice $attachedBlockDevUUID to VM!"
    if ($DoNotCleanup -eq $false) {
        Write-Host "Cleaning up $uploadedUUID..."
        $result = Invoke-RestMethod @restOpts "$url/VirtualDisk/$uploadedUUID" -Method DELETE
    }
}
Write-Host "VMDK Upload(s) Complete!"


Write-Host "Pulling VM attributes from OVF file..."
[string]$vmName = $ovf.Envelope.VirtualSystem.VirtualHardwareSection.System.VirtualSystemIdentifier
if ([string]::IsNullOrEmpty($vmName)) {
    $vmName = "$ovaFileName"
}
Write-Verbose "vmName is $vmName"

# Convert-Size adapted from https://techibee.com/powershell/convert-from-any-to-any-bytes-kb-mb-gb-tb-using-powershell/2376
# Source: https://www.opennodecloud.com/howto/2013/12/25/howto-ON-ovf-reference.html
#   AllocationUnits: Default is “bytes”. Other options are:
#   “KB”, “KILOBYTE” or “byte * 2^10”
#   “MB”, “MEGABYTE” or “byte * 2^20”
#   “GB”, “GIGABYTE” or “byte * 2^30”
#   “TB”, “TERABYTE” or “byte * 2^40”
# Source: https://www.dmtf.org/sites/default/files/standards/documents/DSP0004_3.0.1.pdf
#   Appendix D indicates numberous possibilities (for AllocationUnits).
#   This aims to capture the most common cases.
function Convert-Size {
    [cmdletbinding()]
    param(
        # [validateset("Bytes","KB", "KiloBytes", "MB", "MegaBytes", "GB", "GigaBytes", "TB", "TeraBytes")]
        [string]$From,
        # [validateset("Bytes","KB", "KiloBytes", "MB", "MegaBytes", "GB", "GigaBytes", "TB", "TeraBytes")]
        [string]$To,
        [Parameter(Mandatory=$true)]
        [double]$Value,
        [int]$Precision = 4
    )
    switch -wildcard ($From.ToLower()) {
        "bytes" {$value = $Value }
        "byte * 2^10" {$value = $Value * 1024 }
        "kb" {$value = $Value * 1024 }
        "kilobyte*" {$value = $Value * 1024 }
        "byte * 2^20" {$value = $Value * 1024 * 1024}
        "mb" {$value = $Value * 1024 * 1024}
        "megabyte*" {$value = $Value * 1024 * 1024}
        "byte * 2^30" {$value = $Value * 1024 * 1024 * 1024}
        "gb" {$value = $Value * 1024 * 1024 * 1024}
        "gigabyte*" {$value = $Value * 1024 * 1024 * 1024}
        "byte * 2^40" {$value = $Value * 1024 * 1024 * 1024 * 1024}
        "tb" {$value = $Value * 1024 * 1024 * 1024 * 1024}
        "terabyte*" {$value = $Value * 1024 * 1024 * 1024 * 1024}
        Default {$value = $Value } # bytes
    }
    switch -wildcard  ($To.ToLower()) {
        "bytes" {return $value}
        "byte * 2^10" {$Value = $Value/1KB}
        "kb" {$Value = $Value/1KB}
        "kilobyte*" {$Value = $Value/1KB}
        "byte * 2^20" {$Value = $Value/1MB}
        "mb" {$Value = $Value/1MB}
        "megabyte*" {$Value = $Value/1MB}
        "byte * 2^30" {$Value = $Value/1GB}
        "gb" {$Value = $Value/1GB}
        "gigabyte*" {$Value = $Value/1GB}
        "byte * 2^40" {$Value = $Value/1TB}
        "tb" {$Value = $Value/1TB}
        "terabyte*" {$Value = $Value/1TB}
        Default {return $value} # bytes
    }
    return [Math]::Round($value,$Precision,[MidPointRounding]::AwayFromZero)
}


#######################
# Resource Accounting #
#######################
# Source: https://www.opennodecloud.com/howto/2013/12/25/howto-ON-ovf-reference.html
# CIM ResourceType ValueMap
# ID  Value   ID  Value   ID  Value
# 1   Other   2   Computer System     3   Processor
# 4   Memory  5   IDE Controller  6   Parallel SCSI HBA
# 7   FC HBA  8   iSCSI HBA   9   IB HCA
# 10  Ethernet Adapter    11  Other Network Adapter   12  I/O Slot
# 13  I/O Device  14  Floppy Drive    15  CD Drive
# 16  DVD drive   17  Disk Drive  18  Tape Drive
# 19  Storage Extent  20  Other storage device    21  Serial port
# 22  Parallel port   23  USB Controller  24  Graphics controller
# 25  IEEE 1394 Controller    26  Partitionable Unit  27  Base Partitionable Unit
# 28  Power   29  Cooling Capacity    30  Ethernet Switch Port
# 31  Logical Disk    32  Storage Volume  33  Ethernet Connection
# ..  DMTF reserved   0x8000..0xFFFF  Vendor Reserved
[bool]$foundCDROM = $false
[int]$numEthernetAdapter = 0
[int]$numIDEController = 0
[int]$numOtherController = 0
[int]$numSCSIController = 0
[int]$numIDEDisk = 0
[int]$numOtherDisk = 0
[int]$numSCSIDisk = 0
[int]$vmVCPU = 0
[double] $vmMemory = 0
[int]$numItems = $ovf.CreateNavigator().Evaluate("count(//*[local-name()='Item'])")
for ([int]$i=0; $i -lt $numItems; $i++) {
    $item = $ovf.Envelope.VirtualSystem.VirtualHardwareSection.Item[$i]
    Write-Verbose "Found reference to item $($item.InstanceID) resourcetype $($item.ResourceType)"
    switch ($item.ResourceType) {
        3 { $vmVCPU = $item.VirtualQuantity } # Processor
        4 {
            $memAllocUnits = $item.AllocationUnits
            Write-Verbose "memAllocUnits is $memAllocUnits"
            $vmMemory = Convert-Size -From $memAllocUnits -To Bytes $item.VirtualQuantity
            Write-Verbose "vmMemory is $vmMemory"
        } # Memory
        5 { $numIDEController += 1 } # IDE Controller
        6 { $numSCSIController += 1 } # Parallel SCSI HBA
        10 { $numEthernetAdapter += 1 } # Ethernet Adapter
        15 { $foundCDROM = $true } # CD Drive
        16 { $foundCDROM = $true } # DVD Drive
        17 {
            switch ($item.Parent) {
                # Disk reference to the storage controller
                5 { $numIDEDisk += 1 }
                6 { $numSCSIDisk += 1 }
                20 { $numOtherDisk += 1 }
            }
        } # Disk Drive
        20 { $numOtherController += 1 } # Other storage device (SATA)
        Default {
            # TODO: Handle all types and error out in default case or is that overkill?
            Write-Verbose "Item $($item.InstanceID) has unhandled resource type: $($item.ResourceType)"
        }
    }
}
# Virtualbox (and maybe other) exports put these types of devices here
[int]$numEthernetPortItems = $ovf.CreateNavigator().Evaluate("count(//*[local-name()='EthernetPortItem'])")
[int]$numStorageItems = $ovf.CreateNavigator().Evaluate("count(//*[local-name()='StorageItem'])")
for ([int]$i=0; $i -lt $numEthernetPortItems; $i++) {
    if ($numEthernetPortItems -eq 1) {
        $item = $ovf.Envelope.VirtualSystem.VirtualHardwareSection.EthernetPortItem
    }
    else {
        $item = $ovf.Envelope.VirtualSystem.VirtualHardwareSection.EthernetPortItem[$i]
    }
    Write-Verbose "Found reference to EthernetPortItem $($item.InstanceID)"
    if ($item.ResourceType -eq 10) {
        $numEthernetAdapter += 1
    }
    else {
        Write-Error "EthernetPortItem $($item.InstanceID) has an unhandled resource type: $($item.ResourceType)"
    }
}
for ([int]$i=0; $i -lt $numStorageItems; $i++) {
    if ($numStorageItems -eq 1) {
        $item = $ovf.Envelope.VirtualSystem.VirtualHardwareSection.StorageItem
    }
    else {
        $item = $ovf.Envelope.VirtualSystem.VirtualHardwareSection.StorageItem[$i]
    }
    Write-Verbose "Found reference to StorageItem $($item.InstanceID) type $($item.ResourceType)"
    switch ($item.ResourceType) {
        5 { $numIDEController += 1 } # IDE Controller
        6 { $numSCSIController += 1 } # Parallel SCSI HBA
        10 { $numEthernetAdapter += 1 } # Ethernet Adapter
        15 { $foundCDROM = $true } # CD Drive
        16 { $foundCDROM = $true } # DVD Drive
        17 {
            switch ($item.Parent) {
                5 { $numIDEDisk += 1 }
                6 { $numSCSIDisk += 1 }
                20 { $numOtherDisk += 1 }
            }
        } # Disk Drive
        20 { $numOtherController += 1 } # Other storage device (SATA)
        Default { Write-Error "StorageItem $($item.InstanceID) has an unhandled resource type: $($item.ResourceType)" }
    }
}

if (
    $foundCDROM -eq $false -and
    (
        ($numIDEController -gt $numIDEDisk) -or
        ($numSCSIController -gt $numSCSIDisk) -or
        ($numOtherController -gt $numOtherDisk)
    )
) {
    # TODO: Don't be hacky?
    # There was an extra controller with no associated disk
    $foundCDROM = $true
}
# TODO: Implement maxDevice limits?
# The VM is limited to max 4 IDE, this could be exceeded when using compatible driver types
if ($foundCDROM -eq $true) {
    Write-Host "Adding a cdrom device to VM..."
    $json = @{
        virDomainUUID = $vmUUID
        type = "IDE_CDROM"
        cacheMode = "WRITETHROUGH"
        path = "" # TODO $attachGuestTools
        capacity = 0
    } | ConvertTo-Json -Depth 100
    $result = Invoke-RestMethod @restOpts "$url/VirDomainBlockDevice/" -Method POST -Body $json
    Wait-ScaleTask -TaskTag $($result.taskTag)
    $cdromBlockDevUUID = $($result.createdUUID)
    Write-Host "Cdrom device $cdromBlockDevUUID added!"
}


for ([int]$i=0; $i -lt $numEthernetAdapter; $i++) {
    Write-Host "Adding a network device to VM..."
    # TODO: Are there additional parameters we need to obtain? (VLAN, connected, MAC addr)
    $json = @{
        virDomainUUID = $vmUUID
        type = if ($usePerformanceDrivers) { "VIRTIO" } else { "INTEL_E1000" }
    } | ConvertTo-Json -Depth 100
    $result = Invoke-RestMethod @restOpts "$url/VirDomainNetDevice/" -Method POST -Body $json
    Wait-ScaleTask -TaskTag $($result.taskTag)
    $netDevUUID = $($result.createdUUID)
    Write-Host "Network device $netDevUUID added!"
}

# TODO Boot devices/order? Does that only show up in vmware exports?
# TODO Windows 11/VTPM?

Write-Host "Finalizing VM Settings for $vmName"
$json = @{
    name = $vmName
    description = "Imported from $ovaFileName"
    mem = $vmMemory
    numVCPU = $vmVCPU
} | ConvertTo-Json -Depth 100
$result = Invoke-RestMethod @restOpts "$url/VirDomain/$vmUUID"  -Method PATCH -Body $json
Wait-ScaleTask -TaskTag $($result.taskTag)

if ($DoNotCleanup -eq $true) {
    Write-Verbose "Skipping cleanup..."
}
else {
    Write-Verbose "Cleaning up $tmpDir..."
    Remove-Item -Path $tmpDir -Recurse
    Write-Verbose "$tmpDir removed!"
}
Write-Host "Import OVA Complete!"
Write-Host "Please check all of the VM/disk/network settings (resources, boot types/order) and make any necessary changes before powering on!"
