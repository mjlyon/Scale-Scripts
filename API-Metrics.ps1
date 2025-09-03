# REST API Metrics Collection Script
# This script retrieves VM and Node metrics from a REST API using basic authentication

# Configuration
$HostIP = "10.8.12.17"                     # Update with your host IP address
$Username = "mikey"                        # Update with your username
$Password = "Scale2019"                    # Update with your password

# API Endpoints
$VMStatsUri = "https://$HostIP/rest/v1/VirDomainStats"
$NodeStatsUri = "https://$HostIP/rest/v1/Node"

# Create credential object for basic authentication
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)

# Function to make REST API calls with error handling
function Invoke-ApiRequest {
    param(
        [string]$Uri,
        [System.Management.Automation.PSCredential]$Credential
    )
    
    try {
        # Ignore SSL certificate errors for self-signed certificates
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        
        $Response = Invoke-RestMethod -Uri $Uri -Method Get -SkipCertificateCheck -Credential $Credential -ContentType "application/json"
        return $Response
    }
    catch {
        Write-Error "Failed to retrieve data from $Uri : $_"
        return $null
    }
}

# Function to format VM metrics
function Format-VMMetrics {
    param($VMData)
    
    $FormattedVMs = @()
    
    foreach ($VM in $VMData) {
        # Process VSD stats for each VM
        foreach ($VsdStat in $VM.vsdStats) {
            foreach ($Rate in $VsdStat.rates) {
                $FormattedVM = [PSCustomObject]@{
                    'VM UUID' = $VM.uuid.Substring(0,8) + "..."
                    'VSD UUID' = $VsdStat.uuid.Substring(0,8) + "..."
                    'CPU Usage %' = [math]::Round($VM.cpuUsage, 2)
                    'RX Bit Rate' = Format-DataSize $VM.rxBitRate
                    'TX Bit Rate' = Format-DataSize $VM.txBitRate
                    'Read IOPS' = [math]::Round($Rate.millireadsPerSecond / 1000, 2)
                    'Write IOPS' = [math]::Round($Rate.milliwritesPerSecond / 1000, 2)
                    'Read KB/s' = $Rate.readKibibytesPerSecond
                    'Write KB/s' = $Rate.writeKibibytesPerSecond
                    'Read Latency (μs)' = $Rate.meanReadLatencyMicroseconds
                    'Write Latency (μs)' = $Rate.meanWriteLatencyMicroseconds
                }
                $FormattedVMs += $FormattedVM
            }
        }
        
        # If no VSD stats, still show basic VM info
        if ($VM.vsdStats.Count -eq 0) {
            $FormattedVM = [PSCustomObject]@{
                'VM UUID' = $VM.uuid.Substring(0,8) + "..."
                'VSD UUID' = "N/A"
                'CPU Usage %' = [math]::Round($VM.cpuUsage, 2)
                'RX Bit Rate' = Format-DataSize $VM.rxBitRate
                'TX Bit Rate' = Format-DataSize $VM.txBitRate
                'Read IOPS' = 0
                'Write IOPS' = 0
                'Read KB/s' = 0
                'Write KB/s' = 0
                'Read Latency (μs)' = 0
                'Write Latency (μs)' = 0
            }
            $FormattedVMs += $FormattedVM
        }
    }
    
    return $FormattedVMs
}

# Function to format Node metrics
function Format-NodeMetrics {
    param($NodeData)
    
    $FormattedNodes = @()
    
    foreach ($Node in $NodeData) {
        $NodeInfo = [PSCustomObject]@{
            'Node UUID' = $Node.uuid.Substring(0,8) + "..."
            'LAN IP' = $Node.lanIP
            'Backplane IP' = $Node.backplaneIP
            'CPU Usage %' = [math]::Round($Node.cpuUsage, 2)
            'Memory Usage %' = [math]::Round($Node.memUsagePercentage, 2)
            'Total Capacity' = Format-DataSize $Node.capacity
            'Network Status' = $Node.networkStatus
            'Peer ID' = $Node.peerID
            'CPU Cores' = $Node.numCores
            'CPU Threads' = $Node.numThreads
            'Drive Count' = $Node.drives.Count
        }
        $FormattedNodes += $NodeInfo
        
        # Add drive details for each node
        foreach ($Drive in $Node.drives) {
            $DriveInfo = [PSCustomObject]@{
                'Node UUID' = "  Drive"
                'LAN IP' = $Drive.serialNumber
                'Backplane IP' = "Slot $($Drive.slot)"
                'CPU Usage %' = ""
                'Memory Usage %' = ""
                'Total Capacity' = Format-DataSize $Drive.capacityBytes
                'Network Status' = Format-DataSize $Drive.usedBytes
                'Peer ID' = "$([math]::Round(($Drive.usedBytes / $Drive.capacityBytes) * 100, 1))%"
                'CPU Cores' = "$($Drive.temperature)°C"
                'CPU Threads' = if ($Drive.isHealthy) { "Healthy" } else { "Unhealthy" }
                'Drive Count' = $Drive.type
            }
            $FormattedNodes += $DriveInfo
        }
    }
    
    return $FormattedNodes
}

# Function to format data sizes
function Format-DataSize {
    param([long]$Size)
    
    if ($Size -eq 0) { return "0 B" }
    
    $Units = @("B", "KB", "MB", "GB", "TB", "PB")
    $Index = 0
    $FormattedSize = $Size
    
    while ($FormattedSize -ge 1024 -and $Index -lt $Units.Length - 1) {
        $FormattedSize = $FormattedSize / 1024
        $Index++
    }
    
    return "{0:N2} {1}" -f $FormattedSize, $Units[$Index]
}

# Function to display summary statistics
function Show-Summary {
    param($VMData, $NodeData)
    
    Write-Host "`n" -BackgroundColor Blue -ForegroundColor White "=== CLUSTER SUMMARY ==="
    
    $TotalVMs = $VMData.Count
    $ActiveVMs = ($VMData | Where-Object { $_.cpuUsage -gt 0 }).Count
    $TotalNodes = $NodeData.Count
    $OnlineNodes = ($NodeData | Where-Object { $_.networkStatus -eq "ONLINE" }).Count
    $TotalCapacity = ($NodeData | Measure-Object -Property capacity -Sum).Sum
    $AvgCPUUsage = ($NodeData | Measure-Object -Property cpuUsage -Average).Average
    
    Write-Host "Total VMs: $TotalVMs (Active: $ActiveVMs)" -ForegroundColor Green
    Write-Host "Total Nodes: $TotalNodes (Online: $OnlineNodes)" -ForegroundColor Green
    Write-Host "Total Cluster Capacity: $(Format-DataSize $TotalCapacity)" -ForegroundColor Green
    Write-Host "Average Node CPU Usage: $([math]::Round($AvgCPUUsage, 2))%" -ForegroundColor Green
    Write-Host ""
}

# Main execution
Write-Host "Retrieving metrics from REST API..." -ForegroundColor Yellow

# Retrieve VM metrics
Write-Host "Fetching VM data from virDomainStats endpoint..." -ForegroundColor Cyan
$VMData = Invoke-ApiRequest -Uri $VMStatsUri -Credential $Credential

# Retrieve Node metrics  
Write-Host "Fetching Node data from node endpoint..." -ForegroundColor Cyan
$NodeData = Invoke-ApiRequest -Uri $NodeStatsUri -Credential $Credential

if ($VMData -and $NodeData) {
    # Display summary
    Show-Summary -VMData $VMData -NodeData $NodeData
    
    # Format and display VM metrics
    Write-Host "=== VM METRICS ===" -BackgroundColor Green -ForegroundColor Black
    $FormattedVMs = Format-VMMetrics -VMData $VMData
    $FormattedVMs | Format-Table -AutoSize
    
    # Format and display Node metrics
    Write-Host "`n=== NODE METRICS ===" -BackgroundColor Blue -ForegroundColor White
    $FormattedNodes = Format-NodeMetrics -NodeData $NodeData
    $FormattedNodes | Format-Table -AutoSize
    
    # Export to CSV if needed
    $ExportChoice = Read-Host "`nWould you like to export the data to CSV files? (y/n)"
    if ($ExportChoice -eq 'y' -or $ExportChoice -eq 'Y') {
        $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $FormattedVMs | Export-Csv -Path "VM_Metrics_$Timestamp.csv" -NoTypeInformation
        $FormattedNodes | Export-Csv -Path "Node_Metrics_$Timestamp.csv" -NoTypeInformation
        Write-Host "Data exported to VM_Metrics_$Timestamp.csv and Node_Metrics_$Timestamp.csv" -ForegroundColor Green
    }
}
else {
    Write-Host "Failed to retrieve data from API. Please check your credentials and API endpoints." -ForegroundColor Red
}

# Pause to view results
Write-Host "`nPress any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
