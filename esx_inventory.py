import ssl
import atexit
from pyVim import connect
from pyVmomi import vim
from pyVmomi import vmodl

# Function to get VM details (vCPU, memory, storage)
def get_vm_details(vm):
    summary = vm.summary
    config = summary.config
    storage = summary.storage

    print(f"VM Name: {config.name}")
    print(f"vCPUs: {config.numCpu}")
    print(f"Memory: {config.memorySizeMB} MB")
    print(f"Storage Used: {storage.committed / (1024 ** 3):.2f} GB")
    print("-" * 40)

# Recursive function to process folders and list VMs
def list_vms_in_folder(folder):
    for entity in folder.childEntity:
        if isinstance(entity, vim.VirtualMachine):
            get_vm_details(entity)
        elif isinstance(entity, vim.Folder):
            list_vms_in_folder(entity)

# Main function to connect and retrieve VM inventory
def main():
    # Replace these values with your actual ESXi/vCenter details
    host = "your-esx-host-ip-or-name"
    user = "your-username"
    password = "your-password"
    port = 443

    # Bypass SSL verification for self-signed certificates
    context = ssl.SSLContext(ssl.PROTOCOL_SSLv23)
    context.verify_mode = ssl.CERT_NONE

    try:
        # Connect to the host
        service_instance = connect.SmartConnect(host=host,
                                                user=user,
                                                pwd=password,
                                                port=port,
                                                sslContext=context)

        atexit.register(connect.Disconnect, service_instance)

        # Get the content of the service instance
        content = service_instance.RetrieveContent()

        # Get the root folder
        root_folder = content.rootFolder

        # List all VMs recursively starting from the root folder
        list_vms_in_folder(root_folder)

    except vmodl.MethodFault as error:
        print(f"Caught vmodl fault: {error.msg}")
    except Exception as e:
        print(f"Caught exception: {str(e)}")

if __name__ == "__main__":
    main()
