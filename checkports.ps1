# List of IPs and ports to check
$portsToCheck = @(
    @{IP = '35.241.30.219'; Port = 443},       # Fleet Manager
    @{IP = '206.246.135.231'; Port = 443},     # Update Server
    @{IP = '206.246.135.234'; Port = 22},      # Remote Support
    @{IP = '35.232.148.94'; Port = 443}        # Broker
)

# Check Port Availability 
function Test-PortOpen {
    param(
        [string]$ip,
        [int]$port
    )

    try {
        $tcpConnection = Test-NetConnection -ComputerName $ip -Port $port
        if ($tcpConnection.TcpTestSucceeded) {
            return "Port $port on $ip is OPEN."
        } else {
            return "Port $port on $ip is CLOSED."
        }
    } catch {
        return "Error checking port $port on $ip."
    }
}

# Check DHCP provider availability
#function Check-DHCP {
#    try {
#        $dhcpStatus = Get-WmiObject -Class Win32_NetworkAdapterConfiguration | Where-Object { $_.DHCPEnabled -eq $true }
#        if ($dhcpStatus) {
#            return "DHCP is available."
#        } else {
##            return "DHCP is NOT available."
 #       }
 #   } catch {
 #       return "Error checking DHCP provider."
 #   }
#}

# Start checking ports
$results = @()
foreach ($entry in $portsToCheck) {
    $result = Test-PortOpen -ip $entry.IP -port $entry.Port
    $results += $result
}


# Combine results
$finalResults = $results + $dhcpResult

# Display results in a pop-up window
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[System.Windows.Forms.MessageBox]::Show($finalResults -join "`n", "Network Check Results")

