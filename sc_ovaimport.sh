#!/bin/bash

# Written by Ian Smith of Scale Computing, converted to bash
# Provided without warranty or support

function print_help() {
    cat << EOF
Usage: $0 [options]

Options:
  -server <Server>              Specify the server address (required).
  -credential <Credential>      Provide the credential in base64 format.
  -skipcertificatecheck         Skip certificate validation (optional).
  -ova <Path>                   Full path to the OVA file (required).
  -performancedrivers <y/n>     Use performance drivers (optional, y/n).
  -guesttools <y/n>             Insert Guest Tools ISO for Windows (optional, y/n).
  -donotcleanup                 Skip cleaning up temporary files (optional).
  -verbose                      Enable verbose output (optional).
  --help                        Show this help message.
EOF
}

# Convert all arguments to lowercase for matching
ARGS=("$@")
for ((i = 0; i < $#; i++)); do
    ARGS[$i]="${ARGS[$i],,}"
done

# Arguments
while [[ $# -gt 0 ]]; do
    case "${ARGS[0]}" in
        -server)
            Server="$2"
            shift 2
            ;;
        -credential)
            Credential="$2"
            shift 2
            ;;
        -skipcertificatecheck)
            SkipCertificateCheck="true"
            shift
            ;;
        -ova)
            OVA="$2"
            shift 2
            ;;
        -performancedrivers)
            PerformanceDrivers="$2"
            shift 2
            ;;
        -guesttools)
            GuestTools="$2"
            shift 2
            ;;
        -donotcleanup)
            DoNotCleanup="true"
            shift
            ;;
        -verbose)
            Verbose="true"
            shift
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: ${ARGS[0]}"
            print_help
            exit 1
            ;;
    esac
    shift
done

# Validate required arguments
if [ -z "$Server" ]; then
    echo "Error: -server parameter is required."
    print_help
    exit 1
fi

if [ -z "$OVA" ]; then
    echo "Error: -ova parameter is required."
    print_help
    exit 1
fi

# Check if the OVA file exists
if [ ! -f "$OVA" ]; then
    echo "Error: OVA file does not exist at path '$OVA'."
    exit 1
fi

# Additional logic remains unchanged
# ...
# The rest of the script continues from here...

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
