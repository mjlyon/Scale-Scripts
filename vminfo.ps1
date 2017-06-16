#ok basically working ...
# Dave's connection stanza
param(
   #[string]$clusterip = "10.205.15.70",
     [string] $clusterip = "10.100.15.11",
     [string] $user = "admin",
     [string] $pass = "scale",

   # [string] $detail="N",
   [int] $loops=50
   # [int] $sleep=0


)

#initialize variables
$driverVersion = @()
$VM = @()
$Cluster = @()
$winmac = @()

#this is newer certificate block that seems to work in more places
Add-Type @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            ServicePointManager.ServerCertificateValidationCallback +=
                delegate
                (
                    Object obj,
                    X509Certificate certificate,
                    X509Chain chain,
                    SslPolicyErrors errors
                )
                {
                    return true;
                };
        }
    }
"@

[ServerCertificateValidationCallback]::Ignore();

# region This section formats credentials to base64

$pair = "$($user):$($pass)"
$encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
$basicAuthValue = "Basic $encodedCreds"
$Headers = @{
    Authorization = $basicAuthValue
}

# Create object lists from REST API calls
$VM = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/VirDomain -Headers $Headers
$VirDomain = $VM
$VirDomainStats = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/VirDomainStats -Headers $Headers
$Cluster = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/Cluster -Headers $Headers
$Node = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/Node -Headers $Headers

# Other Local Variables
$date = get-date -f yyyy-MM-dd-hh-mm-ss
$hostname = $env:COMPUTERNAME
$hostEnv = Get-ChildItem -Path ENV:*

# Create hidden scaletemp directory to store logs
$path = "c:\scaletemp"
If((Test-Path $path) -eq $False)
  {
	 New-Item "C:\scaletemp" -ItemType Directory |%{$_.Attributes = "hidden"}
  }
	Else
  {
	}

Get-WmiObject Win32_PnPSignedDriver| select devicename, driverversion | where {$_.devicename -like '*virtio*'} | Out-File c:\temp\drivers.$hostname.$date.txt
Get-Content "c:\temp\drivers.$hostname.$date.txt" | foreach {Write-Output $_}
Get-CimInstance Win32_OperatingSystem | Select-Object  Caption, InstallDate, ServicePackMajorVersion, OSArchitecture, BootDevice,  BuildNumber, CSName | FL




Write-Host "Cluster Name: " $Cluster.clusterName
Write-Host "Version:  " $Cluster.icosVersion `n

# Determine local subnet and find reachable hosts
$subnet = $clusterip

# Loop through each VM and extract information
ForEach ($x in $VM)
{

  $vmMem = [math]::round($x.mem/1GB, 2)
  Write-Host "VM Name:" $x.name", " $x.description
  #Write-Host "VM GUID:" $x.guid
  Write-Host "CPUs:"  $x.numVCPU
  Write-Host "Memory:"  $vmMem "GB"
  Write-Host "Running on node: " $x.console.ip `n
    foreach ($vmDiskBytes in $x.blockDevs | Where-Object type -ne 3)
    {
       $vmDiskCapacityGB = [math]::Round($vmDiskBytes.capacity/1GB, 2)
       $vmDiskUsage = [math]::Round($vmDiskBytes.allocation/1GB, 2)
       $vmdiskuuid = $vmDiskBytes.guid
       Write-Host "     Disk: $vmdiskuuid" `n
       Write-Host "          Capacity:      $vmDiskCapacityGB GB"
       Write-Host "          Usage:         $vmDiskUsage GB"
       Write-Host "          SSD Priority:" $vmDiskBytes.tieringPriorityFactor `n
    }
    foreach ($vmNetDevices in $x.netDevs | Where-Object connected -eq "true")
    {
      Write-Host $vmNetDevices.macAddress
      Write-Host $vmNetDevices.vlan
    }

}
