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

$date = get-date -f yyyy-MM-dd-hh-mm-ss
$hostname = $env:COMPUTERNAME
Get-WmiObject Win32_PnPSignedDriver| select devicename, driverversion | where {$_.devicename -like '*virtio*'} | Out-File c:\temp\drivers.$hostname.$date.txt
Get-Content "c:\temp\drivers.$hostname.$date.txt" | foreach {Write-Output $_}
$hostEnv = Get-ChildItem -Path ENV:*

Get-CimInstance Win32_OperatingSystem | Select-Object  Caption, InstallDate, ServicePackMajorVersion, OSArchitecture, BootDevice,  BuildNumber, CSName | FL


# region Create PS objects using Scale REST API  - currently creates objects not yet used for interactive use
# Try to match API object names where possible

$VM = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/VirDomain -Headers $Headers
$VirDomain = $VM
$VirDomainStats = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/VirDomainStats -Headers $Headers
$Cluster = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/Cluster -Headers $Headers
$Node = Invoke-RestMethod -Method Get -Uri https://$clusterip/rest/v1/Node -Headers $Headers


Write-Host Querying driver verisions


#Loop
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
       Write-Host "          Usage:         $vmDiskUsage GB" `n
    }


}
