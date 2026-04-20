<#
.SYNOPSIS
    Refreshes RTSP tokens for existing Blue Iris cameras from UniFi Protect.

.DESCRIPTION
    Reads NVR configuration, fetches (and optionally regenerates) RTSP tokens
    for all cameras, and updates the Blue Iris registry. Designed to run as
    a scheduled task OR on-demand after a Protect firmware update.

    [!] THIS SCRIPT UPDATES RESOLUTION FIELDS IN ADDITION TO PATH FIELDS.
    Without that, switching a camera's stream quality (LOW <-> HIGH) via
    registry injection leaves BI's decoder misconfigured - BI then hits a
    silent retry loop (Socket error / Socket closed) even though the RTSP
    stream is perfectly fine. See the main README for the full explanation:
    https://github.com/pueblokc/protect-your-iris#-critical-resolution-field-mismatch-the-silent-killer

.PARAMETER ConfigPath
    Path to JSON config file with NVR details.

.PARAMETER Quality
    Stream quality to pull from Protect and point BI at. Default: "low".
    If you change this between runs you MUST make sure the Xres/Yres values
    below reflect the new quality's pixel dimensions.

.PARAMETER GetOnly
    If set, this script will ONLY do GET /rtsps-stream (no POST attempt).
    As of Protect firmware circa 2026-04, POST returns HTTP 400 with empty
    body regardless of key/body - regeneration must be done in the Protect
    web UI (camera -> Advanced -> toggle RTSP off then on). GET still works
    and returns current tokens, which is what we need. See README:
    https://github.com/pueblokc/protect-your-iris#-token-regeneration-workaround-post-rtsps-stream-returns-400

.PARAMETER MainXres
.PARAMETER MainYres
    Pixel dimensions of the stream you're pointing BI at. Default is
    640x360 (LOW quality). If -Quality high, pass -MainXres / -MainYres
    matching the camera's native resolution (e.g. 2688x1512 for a G4 Bullet).

.PARAMETER NativeXres
.PARAMETER NativeYres
    Camera's native resolution (what Protect shows in the camera's Advanced
    settings). Used for mainxres/mainyres/fullxres/fullyres (snapshot size).
    Default 2688x1512 which is G4 Bullet native. Set this per your cameras.

.EXAMPLE
    # Legacy POST-based refresh (only works on older Protect firmware)
    .\Refresh-Tokens.ps1 -ConfigPath "C:\BlueIris\token_config.json"

.EXAMPLE
    # GET-only refresh (works on current Protect firmware - requires user
    # to have toggled RTSP in the Protect UI first for cams being rotated)
    .\Refresh-Tokens.ps1 -ConfigPath "C:\BlueIris\token_config.json" -GetOnly

.EXAMPLE
    # HIGH quality push for 2K cameras
    .\Refresh-Tokens.ps1 -ConfigPath "C:\BlueIris\token_config.json" `
        -Quality high -MainXres 2688 -MainYres 1512 -GetOnly

.NOTES
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

    [ValidateSet("high", "low", "medium")]
    [string]$Quality = "low",

    [switch]$GetOnly,

    [int]$MainXres = 640,
    [int]$MainYres = 360,
    [int]$NativeXres = 2688,
    [int]$NativeYres = 1512
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
Log "GetOnly mode: $($GetOnly.IsPresent)"
Log "Main stream dims (xres/yres): ${MainXres} x ${MainYres}"
Log "Camera native (mainxres/mainyres): ${NativeXres} x ${NativeYres}"

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

function Parse-Token($uri) {
    if ($uri -and $uri -match 'rtsps?://[^/]+/([^?]+)') { return $Matches[1] }
    return $null
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
        $token = $null

        if ($GetOnly) {
            # GET current tokens - works on current firmware but does NOT regenerate.
            # If you want fresh tokens, toggle RTSP in Protect UI first.
            try {
                $resp = Invoke-RestMethod `
                    -Uri "https://$($nvr.ip)/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
                    -Method GET @splat
                $token = Parse-Token $resp.$Quality
            }
            catch {
                Log "  FAIL (GET): $($cam.name) - $($_.Exception.Message)" "Red"
                continue
            }
        }
        else {
            # Legacy path: POST to regenerate. Fails with HTTP 400 on Protect
            # firmware from circa 2026-04 onward - use -GetOnly in that case.
            try {
                $resp = Invoke-RestMethod `
                    -Uri "https://$($nvr.ip)/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
                    -Method POST @splat `
                    -Body "{`"qualities`":[`"$Quality`"]}" `
                    -ContentType "application/json"
                $token = Parse-Token $resp.$Quality
            }
            catch {
                $msg = $_.Exception.Message
                Log "  FAIL (POST): $($cam.name) - $msg" "Red"
                if ($msg -match "400") {
                    Log "    HINT: POST rejected by Protect. Try -GetOnly and toggle RTSP in Protect UI." "Yellow"
                }
                continue
            }
        }

        if ($token) {
            $allTokens[$cam.name] = @{
                Token = $token
                NvrIP = $nvr.ip
            }
            Log "  OK: $($cam.name) -> /$token" "Green"
        }
        else {
            Log "  FAIL: $($cam.name) - no $Quality token in response" "Red"
        }
    }
}

if ($allTokens.Count -eq 0) {
    Log "No tokens resolved. Aborting." "Red"
    exit 1
}

# Stop Blue Iris
Log "Stopping Blue Iris service..." "Yellow"
Stop-Service -Name "BlueIris" -Force -ErrorAction SilentlyContinue
$svc = Get-Service -Name "BlueIris" -ErrorAction SilentlyContinue
if ($svc) { try { $svc.WaitForStatus('Stopped', '00:01:30') } catch {} }
Get-Process -Name "BlueIris" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# Backup registry
$backupPath = ".\bi6_pre_refresh_$(Get-Date -Format 'yyyyMMdd_HHmm').reg"
reg export "HKLM\SOFTWARE\Perspective Software\Blue Iris" $backupPath /y 2>$null
Log "Registry backed up to: $backupPath"

# Update registry - path fields AND resolution fields
$regBase = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras"
$updated = 0
$notFound = 0
$unchanged = 0

foreach ($entry in $allTokens.GetEnumerator()) {
    $camName = $entry.Key
    $token = $entry.Value.Token
    $nvrIP = $entry.Value.NvrIP
    $regPath = "$regBase\$camName"

    # Try exact match, then fuzzy (strip spaces/underscores) if BI regkey differs from Protect name
    if (!(Test-Path $regPath)) {
        $normalized = ($camName.ToLower() -replace '[\s_\.\-]', '')
        $match = Get-ChildItem $regBase -ErrorAction SilentlyContinue | Where-Object {
            ($_.PSChildName.ToLower() -replace '[\s_\.\-]', '') -eq $normalized
        } | Select-Object -First 1
        if ($match) { $regPath = $match.PSPath }
    }

    if (!(Test-Path $regPath)) {
        Log "  NOT IN BI6: $camName (no registry entry)" "Yellow"
        $notFound++
        continue
    }

    $existing = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
    $newPath = "/$token"
    if ($existing.ip_path -eq $newPath -and $existing.xres -eq $MainXres -and $existing.yres -eq $MainYres) {
        $unchanged++
        continue
    }

    # ---- Path fields ----
    Set-ItemProperty $regPath -Name "ip_path"    -Value $newPath -Force
    Set-ItemProperty $regPath -Name "ip_subpath" -Value $newPath -Force
    Set-ItemProperty $regPath -Name "ip_path2"   -Value $newPath -Force
    Set-ItemProperty $regPath -Name "dsname" -Value "admin@${nvrIP}:80${newPath}/:7447:1[${newPath}]" -Force

    # ---- Resolution fields (MUST match the stream quality) ----
    # Without these, BI will silently retry-loop with Socket errors. See README.
    Set-ItemProperty $regPath -Name "xres"         -Value $MainXres   -Type DWord -Force
    Set-ItemProperty $regPath -Name "yres"         -Value $MainYres   -Type DWord -Force
    Set-ItemProperty $regPath -Name "mainxres"     -Value $NativeXres -Type DWord -Force
    Set-ItemProperty $regPath -Name "mainyres"     -Value $NativeYres -Type DWord -Force
    Set-ItemProperty $regPath -Name "fullxres"     -Value $NativeXres -Type DWord -Force
    Set-ItemProperty $regPath -Name "fullyres"     -Value $NativeYres -Type DWord -Force
    Set-ItemProperty $regPath -Name "zrect_left"   -Value 0           -Type DWord -Force
    Set-ItemProperty $regPath -Name "zrect_top"    -Value 0           -Type DWord -Force
    Set-ItemProperty $regPath -Name "zrect_right"  -Value $MainXres   -Type DWord -Force
    Set-ItemProperty $regPath -Name "zrect_bottom" -Value $MainYres   -Type DWord -Force
    Set-ItemProperty $regPath -Name "ip_aformat"   -Value 7           -Type DWord -Force

    $updated++
}

Log "Updated: $updated | Unchanged: $unchanged | Not in BI6: $notFound" "Cyan"

# Start Blue Iris
Log "Starting Blue Iris service..." "Yellow"
Start-Service -Name "BlueIris"

$waitTime = [math]::Max(90, $updated * 2)
Log "Waiting $waitTime seconds for cameras to reconnect..." "Cyan"
Start-Sleep -Seconds $waitTime

Log "=== Token Refresh Complete ===" "Green"
Log "Log saved to: $logFile"
Log ""
Log "Verification: check the BI UI, or run (via local BI JSON API):" "White"
Log "  POST http://127.0.0.1:81/json {cmd:camlist} -- look for isOnline=false entries." "White"
