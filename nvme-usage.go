package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"strconv"
)

func main() {
	// Define the NVMe device
	device := "/dev/nvme0"

	// Run the nvme smart-log command to get the data units written
	cmd := exec.Command("nvme", "smart-log", device)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		fmt.Println("Error executing nvme command:", err)
		return
	}

	// Find the data_units_written line in the output
	var dataUnitsWritten int
	for _, line := range strings.Split(out.String(), "\n") {
		if strings.Contains(line, "data_units_written") {
			// Split the line and get the value for data_units_written
			fields := strings.Fields(line)
			if len(fields) >= 3 {
				dataUnitsWritten, err = strconv.Atoi(fields[2])
				if err != nil {
					fmt.Println("Error converting data_units_written to integer:", err)
					return
				}
				break
			}
		}
	}

	// If the data_units_written was not found, print an error
	if dataUnitsWritten == 0 {
		fmt.Println("data_units_written not found in the output")
		return
	}

	// Convert the data units written from 1MB units to GB and TB
	gbWritten := float64(dataUnitsWritten) * 1000 * 1000 / (1024 * 1024 * 1024) // GB
	tbWritten := float64(dataUnitsWritten) * 1000 * 1000 / (1024 * 1024 * 1024 * 1024) // TB

	// Display the results
	fmt.Printf("\nTotal data written to %s:\n", device)
	fmt.Printf("Total GB Written: %.3f GB\n", gbWritten)
	fmt.Printf("Total TB Written: %.3f TB\n", tbWritten)
}
