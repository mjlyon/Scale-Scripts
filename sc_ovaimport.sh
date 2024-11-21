#!/bin/bash

# Written by Ian Smith of Scale Computing, converted to bash
# Provided without warranty or support

function show_menu() {
    echo "=========================================="
    echo "          OVA Import Script"
    echo "=========================================="
    echo "Please provide the following parameters:"
}

function validate_file() {
    if [ ! -f "$1" ]; then
        echo "Error: File does not exist at path '$1'."
        return 1
    fi
    return 0
}

show_menu

# Collect inputs
read -p "Enter Server address: " Server
while [ -z "$Server" ]; do
    echo "Server address is required."
    read -p "Enter Server address: " Server
done

read -p "Enter Username: " Username
while [ -z "$Username" ]; do
    echo "Username is required."
    read -p "Enter Username: " Username
done

read -sp "Enter Password: " Password
echo
while [ -z "$Password" ]; do
    echo "Password is required."
    read -sp "Enter Password: " Password
    echo
done

read -p "Enter full path to the OVA file: " OVA
while ! validate_file "$OVA"; do
    read -p "Enter full path to the OVA file: " OVA
done

read -p "Use performance drivers? (y/n): " PerformanceDrivers
while [[ ! "$PerformanceDrivers" =~ ^[YyNn]$ ]]; do
    echo "Please enter 'y' or 'n'."
    read -p "Use performance drivers? (y/n): " PerformanceDrivers
done

read -p "Insert Guest Tools ISO for Windows? (y/n): " GuestTools
while [[ ! "$GuestTools" =~ ^[YyNn]$ ]]; do
    echo "Please enter 'y' or 'n'."
    read -p "Insert Guest Tools ISO for Windows? (y/n): " GuestTools
done

read -p "Do not clean up temporary files? (y/n): " DoNotCleanup
while [[ ! "$DoNotCleanup" =~ ^[YyNn]$ ]]; do
    echo "Please enter 'y' or 'n'."
    read -p "Do not clean up temporary files? (y/n): " DoNotCleanup
done

read -p "Enable verbose output? (y/n): " Verbose
while [[ ! "$Verbose" =~ ^[YyNn]$ ]]; do
    echo "Please enter 'y' or 'n'."
    read -p "Enable verbose output? (y/n): " Verbose
done

# Process inputs
PerformanceDrivers=$( [[ "$PerformanceDrivers" =~ ^[Yy]$ ]] && echo true || echo false )
GuestTools=$( [[ "$GuestTools" =~ ^[Yy]$ ]] && echo true || echo false )
DoNotCleanup=$( [[ "$DoNotCleanup" =~ ^[Yy]$ ]] && echo true || echo false )
Verbose=$( [[ "$Verbose" =~ ^[Yy]$ ]] && echo true || echo false )
AuthHeader="Authorization: Basic $(echo -n "${Username}:${Password}" | base64)"

# Skip certificate check in curl (-k)
url="https://$Server/rest/v1"

# Extract the OVA
tmpDir=$(mktemp -d)
ovaFileName=$(basename "$OVA")
tar -C "$tmpDir" -xvf "$OVA" || { echo "Failed to extract OVA"; exit 1; }

# Find the .vmdk and .ovf files
vmdkList=$(find "$tmpDir" -name "*.vmdk")
ovfFile=$(find "$tmpDir" -name "*.ovf")

# Parse the OVF for the VM name
vmName=$(xmllint --xpath "string(//VirtualSystem/VirtualSystemIdentifier)" "$ovfFile")
if [ -z "$vmName" ]; then
    vmName="$ovaFileName"
fi

# Create VM
echo "Creating VM $vmName on HyperCore..."
vmJson="{\"dom\": {\"name\": \"$vmName\", \"desc\": \"$vmName\", \"mem\": 0, \"numVCPU\": 0}}"
vmUUID=$(curl -k -X POST "$url/VirDomain/" -H "$AuthHeader" -H "Content-Type: application/json" -d "$vmJson" | jq -r .createdUUID)
if [ -z "$vmUUID" ]; then
    echo "Error: Failed to create VM."
    exit 1
fi

# Upload VMDK files
for vmdk in $vmdkList; do
    vmdkFileName=$(basename "$vmdk")
    vmdkSize=$(stat --format=%s "$vmdk")
    echo "Uploading $vmdkFileName..."
    uploadResponse=$(curl -k -X PUT "$url/VirtualDisk/upload?filename=$vmdkFileName&filesize=$vmdkSize" -H "$AuthHeader" --data-binary @"$vmdk")
    uploadedUUID=$(echo "$uploadResponse" | jq -r .createdUUID)

    if [ -z "$uploadedUUID" ]; then
        echo "Error: Failed to upload $vmdkFileName."
        exit 1
    fi

    # Attach the disk
    diskType=$( [[ "$PerformanceDrivers" == true ]] && echo "VIRTIO_DISK" || echo "IDE_DISK" )
    echo "Attaching $vmdkFileName to VM..."
    attachJson="{\"template\": {\"virDomainUUID\": \"$vmUUID\", \"type\": \"$diskType\", \"capacity\": $vmdkSize}}"
    curl -k -X POST "$url/VirtualDisk/$uploadedUUID/attach" -H "$AuthHeader" -H "Content-Type: application/json" -d "$attachJson"
done

# Finalize VM Settings
echo "Finalizing VM settings for $vmName..."
finalizeJson="{\"name\": \"$vmName\", \"description\": \"Imported from $ovaFileName\", \"mem\": 4096, \"numVCPU\": 2}"
curl -k -X PATCH "$url/VirDomain/$vmUUID" -H "$AuthHeader" -H "Content-Type: application/json" -d "$finalizeJson"

# Clean up temporary files
if [ "$DoNotCleanup" != true ]; then
    echo "Cleaning up temporary files..."
    rm -rf "$tmpDir"
else
    echo "Skipping cleanup as requested."
fi

echo "OVA import process complete!"
