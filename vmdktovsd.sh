#!/bin/bash

# Replace username:password with credentials for ESX
# Replace filename.vmdk with the disk name from the datastore 
# Replace esxi-host-ip/folder/etc... with the path to the datastore 
# Replace datacenter-name and datastore-name with relevant values

curl -u "username:password" -o "filename.vmdk" \
"https://esxi-host-ip/folder/vmfolder/vmname.vmdk?dcPath=datacenter-name&dsName=datastore-name"
