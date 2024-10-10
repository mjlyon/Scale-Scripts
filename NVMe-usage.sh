#!/bin/bash

# Define the NVMe device
DEVICE="/dev/nvme0"

# Get the data units written using the nvme command
DATA_UNITS_WRITTEN=$(nvme smart-log $DEVICE | grep "data_units_written" | awk '{print $3}')

# Convert the data units written from 1MB units to GB and TB
GB_WRITTEN=$(echo "scale=3; $DATA_UNITS_WRITTEN * 1000 * 1000 / 1024 / 1024 / 1024" | bc)
TB_WRITTEN=$(echo "scale=3; $DATA_UNITS_WRITTEN * 1000 * 1000 / 1024 / 1024 / 1024 / 1024" | bc)

# Display the results
echo ""
echo "Total data written to $DEVICE:"
echo "Total GB Written: $GB_WRITTEN GB"
echo "Total TB Written: $TB_WRITTEN TB"
echo ""
