<#
.SYNOPSIS
    Refreshes RTSP tokens for existing Blue Iris cameras from UniFi Protect.

.DESCRIPTION
    Reads NVR configuration, generates fresh tokens for all cameras,
    and updates the Blue Iris registry. Designed to run as a scheduled task.

.PARAMETER ConfigPath
    Path to JSON config file with NVR details.

.PARAMETER Quality
    Stream quality to generate. Default: "low".

.EXAMPLE
    .\Refresh-Tokens.ps1 -ConfigPath "C:\BlueIris\token_config.json"

.NOTES
    Schedule as a Windows Task to run weekly or after NVR reboots.
    Config file format:
    {
      "nvrs": [
        {"ip": "192.168.1.100", "apiKey": "YOUR_API_KEY"}
      ]
    }
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [ValidateSet("high", "low")]
    [string]$Quality = "low"
)

$logFile = ".\token_refresh_$(Get-Date -Format 'yyyyMMdd_HHmm').log"

function Log($msg, $color = "White") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $msg"
    Write-Host $line -ForegroundColor $color
    $line | Out-File -Append $logFile
}

# Load config
if (!(Test-Path $ConfigPath)) {
    Log "ERROR: Config file not found: $ConfigPath" "Red"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
Log "=== Token Refresh Started ===" "Cyan"
Log "Config: $ConfigPath"
Log "NVRs: $($config.nvrs.Count)"
Log "Quality: $Quality"

# Handle self-signed certs
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$allTokens = @{}

foreach ($nvr in $config.nvrs) {
    Log "Processing NVR: $($nvr.ip)" "Cyan"

    $headers = @{ "X-API-Key" = $nvr.apiKey }
    $splat = @{ Headers = $headers }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $splat["SkipCertificateCheck"] = $true }

    try {
        $cameras = Invoke-RestMethod `
            -Uri "https://$($nvr.ip)/proxy/protect/integration/v1/cameras" @splat
    }
    catch {
        Log "  ERROR: Cannot reach NVR - $($_.Exception.Message)" "Red"
        continue
    }

    Log "  Found $($cameras.Count) cameras" "Green"

    foreach ($cam in $cameras | Where-Object { $_.state -eq "CONNECTED" }) {
        try {
            $resp = Invoke-RestMethod `
                -Uri "https://$($nvr.ip)/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
                -Method POST @splat `
                -Body "{`"qualities`":[`"$Quality`"]}" `
                -ContentType "application/json"

            if ($resp.$Quality -match "/([^/?]+)") {
                $allTokens[$cam.name] = @{
                    Token = $Matches[1]
                    NvrIP = $nvr.ip
                }
                Log "  OK: $($cam.name)" "Green"
            }
        }
        catch {
            Log "  FAIL: $($cam.name) - $($_.Exception.Message)" "Red"
        }
    }
}

if ($allTokens.Count -eq 0) {
    Log "No tokens generated. Aborting." "Red"
    exit 1
}

# Stop Blue Iris
Log "Stopping Blue Iris service..." "Yellow"
Stop-Service -Name "BlueIris" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# Backup registry
$backupPath = ".\bi6_pre_refresh_$(Get-Date -Format 'yyyyMMdd_HHmm').reg"
reg export "HKLM\SOFTWARE\Perspective Software\Blue Iris" $backupPath /y 2>$null
Log "Registry backed up to: $backupPath"

# Update registry
$regBase = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras"
$updated = 0
$notFound = 0

foreach ($entry in $allTokens.GetEnumerator()) {
    $camName = $entry.Key
    $token = $entry.Value.Token
    $nvrIP = $entry.Value.NvrIP
    $regPath = "$regBase\$camName"

    if (Test-Path $regPath) {
        Set-ItemProperty $regPath -Name "ip_path" -Value "/$token"
        Set-ItemProperty $regPath -Name "ip_subpath" -Value "/$token"
        Set-ItemProperty $regPath -Name "ip_path2" -Value "/$token"
        Set-ItemProperty $regPath -Name "dsname" -Value "admin@${nvrIP}:80/${token}/:7447:1[/${token}]"
        $updated++
    }
    else {
        Log "  NOT IN BI6: $camName (no registry entry)" "Yellow"
        $notFound++
    }
}

Log "Updated: $updated | Not in BI6: $notFound" "Cyan"

# Start Blue Iris
Log "Starting Blue Iris service..." "Yellow"
Start-Service -Name "BlueIris"

$waitTime = [math]::Max(120, $updated * 3)
Log "Waiting $waitTime seconds for cameras..." "Cyan"
Start-Sleep -Seconds $waitTime

Log "=== Token Refresh Complete ===" "Green"
Log "Log saved to: $logFile"
