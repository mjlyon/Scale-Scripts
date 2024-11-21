#!/bin/bash

# Written by Ian Smith of Scale Computing, converted to bash
# Provided without warranty or support

# Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -Server)
            Server="$2"
            shift 2
            ;;
        -Credential)
            Credential="$2"
            shift 2
            ;;
        -SkipCertificateCheck)
            SkipCertificateCheck="true"
            shift
            ;;
        -OVA)
            OVA="$2"
            shift 2
            ;;
        -PerformanceDrivers)
            PerformanceDrivers="$2"
            shift 2
            ;;
        -GuestTools)
            GuestTools="$2"
            shift 2
            ;;
        -DoNotCleanup)
            DoNotCleanup="true"
            shift
            ;;
        -Verbose)
            Verbose="true"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Set default values if not set
if [ -z "$Server" ]; then
    echo "Server parameter is required."
    exit 1
fi

if [ -z "$OVA" ]; then
    read -p "Enter full path to OVA file: " OVA
fi

if [ -z "$PerformanceDrivers" ]; then
    read -p "Performance Drivers? (y/n): " PerformanceDrivers
fi

if [ -z "$GuestTools" ]; then
    read -p "Insert Guest Tools ISO for Windows? (y/n): " GuestTools
fi

# Check if the OVA exists
if [ ! -f "$OVA" ]; then
    echo "OVA file does not exist at $OVA"
    exit 1
fi

# Create tmp directory and extract OVA contents
tmpDir=$(mktemp -d)
ovaFileName=$(basename "$OVA")
tar -C "$tmpDir" -xvf "$OVA" || { echo "Failed to extract OVA"; exit 1; }

# Find the .vmdk file and .ovf file
vmdkList=$(find "$tmpDir" -name "*.vmdk")
ovfFile=$(find "$tmpDir" -name "*.ovf")

# Parse the OVF XML using `xmllint`
vmName=$(xmllint --xpath "string(//VirtualSystem/VirtualSystemIdentifier)" "$ovfFile")
if [ -z "$vmName" ]; then
    vmName="$ovaFileName"
fi

# Set performance drivers based on user input
usePerformanceDrivers=false
if [[ "$PerformanceDrivers" == "Y" || "$PerformanceDrivers" == "y" ]]; then
    usePerformanceDrivers=true
fi

# Set Guest Tools insertion based on user input
attachGuestTools=false
if [[ "$GuestTools" == "Y" || "$GuestTools" == "y" ]]; then
    echo "Will insert the SC//Guest Tools ISO for Windows!"
    attachGuestTools=true
fi

# Set up for REST API
url="https://$Server/rest/v1"
authHeader="Authorization: Basic $(echo -n "$Credential" | base64)"

# Create the VM on the HyperCore system
echo "Creating VM $vmName on HyperCore..."
json="{\"dom\": {\"name\": \"$vmName\", \"desc\": \"$vmName\", \"mem\": 0, \"numVCPU\": 0}}"
vmUUID=$(curl -X POST "$url/VirDomain/" -H "$authHeader" -H "Content-Type: application/json" -d "$json" | jq -r .createdUUID)

# Upload VMDK disks
for vmdk in $vmdkList; do
    vmdkFileName=$(basename "$vmdk")
    vmdkSize=$(stat --format=%s "$vmdk")
    echo "Uploading $vmdkFileName..."
    uploadResponse=$(curl -X PUT "$url/VirtualDisk/upload?filename=$vmdkFileName&filesize=$vmdkSize" -H "$authHeader" --data-binary @"$vmdk")
    uploadedUUID=$(echo "$uploadResponse" | jq -r .createdUUID)
    echo "Finished uploading $vmdkFileName (uuid: $uploadedUUID)"
    
    # Attach the disk to the VM
    echo "Attaching $vmdkFileName to VM..."
    json="{\"template\": {\"virDomainUUID\": \"$vmUUID\", \"type\": \"$(if [ "$usePerformanceDrivers" == true ]; then echo "VIRTIO_DISK"; else echo "IDE_DISK"; fi)\", \"capacity\": $vmdkSize}}"
    curl -X POST "$url/VirtualDisk/$uploadedUUID/attach" -H "$authHeader" -H "Content-Type: application/json" -d "$json"
done

# Finalize VM settings
echo "Finalizing VM Settings for $vmName"
json="{\"name\": \"$vmName\", \"description\": \"Imported from $ovaFileName\", \"mem\": 0, \"numVCPU\": 0}"
curl -X PATCH "$url/VirDomain/$vmUUID" -H "$authHeader" -H "Content-Type: application/json" -d "$json"

# Clean up temporary files
if [ "$DoNotCleanup" != "true" ]; then
    echo "Cleaning up temporary files..."
    rm -rf "$tmpDir"
else
    echo "Skipping cleanup..."
fi

echo "OVA import complete!"
