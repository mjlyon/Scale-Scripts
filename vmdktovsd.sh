#!/bin/bash


# Retrieve the VMDK
# Replace username:password with credentials for ESX
# Replace filename.vmdk with the disk name from the datastore 
# Replace esxi-host-ip/folder/etc... with the path to the datastore 
# Replace datacenter-name and datastore-name with relevant values

curl -u "username:password" -o "filename.vmdk" \
"https://esxi-host-ip/folder/vmfolder/vmname.vmdk?dcPath=datacenter-name&dsName=datastore-name" \
| curl -u admin:admin -H "Content-Type: application/octet-stream" -H "Content-Length: $(curl -sI "https://esxi-host-ip/folder/vmfolder/vmname.vmdk?dcPath=datacenter-name&dsName=datastore-name" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')" -T - -k "https://10.8.12.60/rest/v1/VirtualDisk/upload?filename=vmname.vmdk&filesize=$(curl -sI "https://esxi-host-ip/folder/vmfolder/vmname.vmdk?dcPath=datacenter-name&dsName=datastore-name" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')" -vvv
