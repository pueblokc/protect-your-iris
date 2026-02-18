<#
.SYNOPSIS
    Generates RTSP stream tokens for all cameras on a UniFi Protect NVR.

.DESCRIPTION
    Connects to the UniFi Protect Integration API, discovers all cameras,
    generates RTSP tokens, and exports results to CSV.

.PARAMETER NvrIP
    IP address of the UniFi Protect NVR.

.PARAMETER ApiKey
    Integration API key from the UniFi Protect settings.

.PARAMETER Qualities
    Array of stream qualities to request. Default: "high", "low".
    Valid values: "high", "medium", "low"
    WARNING: "medium" is unreliable on many camera models. Stick to "high" and "low".

.EXAMPLE
    .\Generate-Tokens.ps1 -NvrIP "192.168.1.100" -ApiKey "YourApiKeyHere"

.EXAMPLE
    .\Generate-Tokens.ps1 -NvrIP "192.168.1.100" -ApiKey "YourApiKeyHere" -Qualities @("low")

.NOTES
    Part of the "Protect Your Iris" guide.
    https://github.com/kc0eks/protect-your-iris
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "IP address of the UniFi Protect NVR")]
    [string]$NvrIP,

    [Parameter(Mandatory = $true, HelpMessage = "Integration API key")]
    [string]$ApiKey,

    [ValidateSet("high", "medium", "low")]
    [string[]]$Qualities = @("high", "low")
)

# Handle certificate validation for self-signed NVR certs
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                WebRequest req, int problem) { return true; }
        }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$headers = @{ "X-API-Key" = $ApiKey }
$splatParams = @{ Headers = $headers }
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $splatParams["SkipCertificateCheck"] = $true
}

# Step 1: Discover cameras
Write-Host "`n=== UniFi Protect Token Generator ===" -ForegroundColor Cyan
Write-Host "NVR: $NvrIP" -ForegroundColor White
Write-Host "Qualities: $($Qualities -join ', ')" -ForegroundColor White
Write-Host ""

try {
    $cameras = Invoke-RestMethod `
        -Uri "https://${NvrIP}/proxy/protect/integration/v1/cameras" @splatParams
}
catch {
    Write-Host "ERROR: Failed to connect to NVR at $NvrIP" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Is the NVR IP correct and reachable?"
    Write-Host "  2. Is the Integration API enabled in Protect settings?"
    Write-Host "  3. Is the API key correct?"
    exit 1
}

$total = $cameras.Count
$connected = ($cameras | Where-Object { $_.state -eq "CONNECTED" }).Count
$disconnected = $total - $connected

Write-Host "Found $total cameras ($connected connected, $disconnected disconnected)" -ForegroundColor Green
Write-Host ""

# Step 2: Generate tokens
$results = @()
$processed = 0

foreach ($cam in $cameras) {
    $processed++
    $pct = [math]::Round(($processed / $total) * 100)

    if ($cam.state -ne "CONNECTED") {
        Write-Host "  [$pct%] SKIP: $($cam.name) (state: $($cam.state))" -ForegroundColor Yellow
        continue
    }

    $qualityJson = ($Qualities | ForEach-Object { "`"$_`"" }) -join ","
    $body = "{`"qualities`":[$qualityJson]}"

    try {
        $resp = Invoke-RestMethod `
            -Uri "https://${NvrIP}/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
            -Method POST @splatParams `
            -Body $body `
            -ContentType "application/json"

        $result = [PSCustomObject]@{
            Name       = $cam.name
            CameraID   = $cam.id
            Model      = $cam.type
            State      = $cam.state
            NvrIP      = $NvrIP
            RTSPPort   = 7447
        }

        foreach ($q in $Qualities) {
            $url = $resp.$q
            if ($url -match "rtsps?://[^:]+:\d+/(.+?)(\?|$)") {
                $token = $Matches[1]
                $result | Add-Member -NotePropertyName "${q}Token" -NotePropertyValue $token
                $result | Add-Member -NotePropertyName "${q}RTSP" -NotePropertyValue "rtsp://${NvrIP}:7447/${token}"
            }
            else {
                $result | Add-Member -NotePropertyName "${q}Token" -NotePropertyValue "FAILED"
                $result | Add-Member -NotePropertyName "${q}RTSP" -NotePropertyValue "FAILED"
            }
        }

        $results += $result
        Write-Host "  [$pct%] OK: $($cam.name)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [$pct%] FAIL: $($cam.name) - $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Step 3: Export results
$csvPath = ".\camera_tokens_$(Get-Date -Format 'yyyy-MM-dd_HHmm').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Exported $($results.Count) cameras to: $csvPath" -ForegroundColor Green

# Display summary table
Write-Host ""
$results | Format-Table Name, State, @{
    L = "Main Token"
    E = { if ($_.highToken) { $_.highToken.Substring(0, [Math]::Min(8, $_.highToken.Length)) + "..." } else { $_.lowToken.Substring(0, [Math]::Min(8, $_.lowToken.Length)) + "..." } }
}, @{
    L = "Sub Token"
    E = { if ($_.lowToken) { $_.lowToken.Substring(0, [Math]::Min(8, $_.lowToken.Length)) + "..." } else { "N/A" } }
} -AutoSize

Write-Host "`nDone! Use these tokens to configure Blue Iris cameras." -ForegroundColor Cyan
Write-Host "See README.md for the full setup guide." -ForegroundColor White
