import subprocess

# Define the NVMe device
device = "/dev/nvme0"

# Get the data units written using the nvme command
try:
    result = subprocess.run(["nvme", "smart-log", device], capture_output=True, text=True, check=True)
    # Extract data_units_written from the output
    for line in result.stdout.splitlines():
        if "data_units_written" in line:
            data_units_written = int(line.split()[2])
            break
    else:
        raise ValueError("data_units_written not found in the output")

    # Convert the data units written from 1MB units to GB and TB
    gb_written = data_units_written * 1000 * 1000 / (1024**3)  # GB
    tb_written = data_units_written * 1000 * 1000 / (1024**4)  # TB

    # Display the results
    print(f"\nTotal data written to {device}:")
    print(f"Total GB Written: {gb_written:.3f} GB")
    print(f"Total TB Written: {tb_written:.3f} TB\n")

except subprocess.CalledProcessError as e:
    print(f"Error executing nvme command: {e}")
except ValueError as e:
    print(f"Error: {e}")
