import os
import tarfile
import requests
import json
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from requests.auth import HTTPBasicAuth


def extract_ova(ova_path, tmp_dir):
    # Extract OVA file into a temporary directory
    if os.path.exists(tmp_dir):
        print(f"Removing existing directory {tmp_dir}...")
        os.rmdir(tmp_dir)  # Remove existing tmp dir
    os.makedirs(tmp_dir)  # Create a new temp directory
    with tarfile.open(ova_path, "r:gz") as tar:
        tar.extractall(path=tmp_dir)
    return tmp_dir


def wait_scale_task(server_url, task_tag, auth, timeout=300, retry_delay=1):
    print(f"Waiting for Task '{task_tag}' to complete...")
    start_time = time.time()

    while time.time() - start_time < timeout:
        response = requests.get(f"{server_url}/TaskTag/{task_tag}", auth=auth, verify=False)
        task_status = response.json()

        if task_status['state'] == 'ERROR':
            raise Exception(f"Task '{task_tag}' failed!")
        elif task_status['state'] == 'COMPLETE':
            print(f"Task '{task_tag}' completed!")
            return
        time.sleep(retry_delay)

    raise TimeoutError(f"Task '{task_tag}' failed to complete in {timeout} seconds")


def create_vm(server_url, ova_filename, auth):
    initial_desc = f"Importing-{ova_filename}"
    print(f"Creating VM {initial_desc} on HyperCore...")

    # Placeholder for reading OVF file and machine type (this should be extracted from the OVF XML)
    ovf_file_path = os.path.join(tmp_dir, [f for f in os.listdir(tmp_dir) if f.endswith('.ovf')][0])
    tree = ET.parse(ovf_file_path)
    root = tree.getroot()
    machine_type = "uefi" if root.find(".//Firmware").text == 'EFI' else "bios"

    vm_data = {
        "dom": {
            "name": initial_desc,
            "desc": initial_desc,
            "mem": 0,  # Will set actual memory later
            "numVCPU": 0  # Will set actual vCPU later
        },
        "options": {
            "machineTypeKeyword": machine_type
        }
    }

    response = requests.post(f"{server_url}/VirDomain/", json=vm_data, auth=auth, verify=False)
    result = response.json()
    vm_uuid = result['createdUUID']
    wait_scale_task(server_url, result['taskTag'], auth)
    print(f"HyperCore VM {vm_uuid} created for OVA import!")
    return vm_uuid


def upload_vmdk_files(server_url, vmdk_list, auth, vm_uuid, use_performance_drivers=False):
    for vmdk in vmdk_list:
        vmdk_filename = os.path.basename(vmdk)
        vmdk_size = os.path.getsize(vmdk)
        print(f"Beginning upload of {vmdk_filename}...")
        with open(vmdk, "rb") as f:
            vmdk_payload = f.read()
            response = requests.put(f"{server_url}/VirtualDisk/upload?filename={vmdk_filename}&filesize={vmdk_size}",
                                    data=vmdk_payload, auth=auth, verify=False)
            result = response.json()
            uploaded_uuid = result['createdUUID']
            print(f"Wait 90 seconds for disk to be converted")
            time.sleep(90)
            print(f"Finished uploading {vmdk_filename} (uuid: {uploaded_uuid})! Attaching as new block device to VM...")
            
            # Attaching disk to VM
            json_data = {
                "template": {
                    "virDomainUUID": vm_uuid,
                    "type": "VIRTIO_DISK" if use_performance_drivers else "IDE_DISK",
                    "capacity": vmdk_size
                },
                "options": {
                    "regenerateDiskID": False
                }
            }

            response = requests.post(f"{server_url}/VirtualDisk/{uploaded_uuid}/attach", json=json_data, auth=auth,
                                     verify=False)
            result = response.json()
            wait_scale_task(server_url, result['taskTag'], auth)
            attached_block_dev_uuid = result['createdUUID']
            print(f"Attached uploaded {vmdk_filename} as new block device {attached_block_dev_uuid} to VM!")


def main():
    # Server and authentication details
    server = input("Enter Scale Computing server IP/hostname: ")
    username = input("Enter username: ")
    password = input("Enter password: ")
    auth = HTTPBasicAuth(username, password)
    
    # OVA path and details
    ova_path = input("Enter full path to OVA file: ")
    tmp_dir = os.path.join("/tmp", Path(ova_path).stem)  # Temporary directory for OVA contents
    
    # Extract OVA and get VMDK list
    tmp_dir = extract_ova(ova_path, tmp_dir)
    vmdk_list = [os.path.join(tmp_dir, f) for f in os.listdir(tmp_dir) if f.endswith('.vmdk')]
    
    # Create VM
    vm_uuid = create_vm(f"https://{server}/rest/v1", Path(ova_path).name, auth)

    # Upload and attach VMDK files
    use_performance_drivers = input("Use performance drivers? (y/n): ").strip().lower() == "y"
    upload_vmdk_files(f"https://{server}/rest/v1", vmdk_list, auth, vm_uuid, use_performance_drivers)

    print("OVA Import Completed!")


if __name__ == "__main__":
    main()
