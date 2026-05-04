<p align="center">
  <img src="assets/header-banner.svg" alt="Protect Your Iris" width="800"/>
</p>

<h1 align="center">🔵 Protect Your Iris</h1>

<h3 align="center">The Definitive Guide to Blue Iris 6 + UniFi Protect Integration</h3>

<p align="center">
  <em>Because your cameras deserve better than a blinking red "NO SIGNAL" icon.</em>
</p>

<p align="center">
  <a href="#-who-is-this-for">Who Is This For?</a> •
  <a href="#-the-big-picture">Big Picture</a> •
  <a href="#-prerequisites">Prerequisites</a> •
  <a href="#-part-1-understanding-the-ecosystem">Part 1: The Ecosystem</a> •
  <a href="#-part-2-setting-up-blue-iris-6">Part 2: BI6 Setup</a> •
  <a href="#-part-3-connecting-unifi-protect">Part 3: Integration</a> •
  <a href="#-part-4-optimization">Part 4: Optimization</a> •
  <a href="#-part-5-advanced">Part 5: Advanced</a> •
  <a href="#-troubleshooting">Troubleshooting</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Blue_Iris-6.x-blue?style=for-the-badge" alt="Blue Iris 6"/>
  <img src="https://img.shields.io/badge/UniFi_Protect-Latest-00A3E0?style=for-the-badge" alt="UniFi Protect"/>
  <img src="https://img.shields.io/badge/Cameras-1_to_128-green?style=for-the-badge" alt="Camera Count"/>
  <img src="https://img.shields.io/badge/Battle_Tested-62_Cameras-orange?style=for-the-badge" alt="Battle Tested"/>
</p>

---

> # 🚨🚨🚨 CRITICAL BUG — READ THIS BEFORE YOU REFRESH TOKENS 🚨🚨🚨
>
> **If you update `ip_path` / `ip_subpath` / `dsname` in the BI registry to point at a different stream quality (LOW vs HIGH vs MEDIUM), you MUST ALSO update `xres`, `yres`, `mainxres`, `mainyres`, `zrect_*`, and `ip_aformat` to match the new quality's pixel dimensions.**
>
> If you don't, BI will:
> - Successfully complete the TCP connection to the NVR ✅
> - Successfully do RTSP DESCRIBE and parse the SDP ✅
> - **Silently fail at SETUP/PLAY** with a never-ending `Signal: Socket error / Socket closed / network retry` loop ❌
>
> **The camera will show "NO SIGNAL" forever** even though the stream is perfectly fine at the protocol level. We burned 3 hours on this in April 2026 before figuring it out.
>
> **The earlier versions of `Refresh-Tokens.ps1` in this repo had this bug** — they updated the path fields but never touched resolution fields. If the new token's quality differs from what the camera was originally set up at, the camera will go dead.
>
> Details, detection, and fix: jump to **[Critical: Resolution Field Mismatch](#-critical-resolution-field-mismatch-the-silent-killer)** before doing anything else with tokens.
>
> Also note (as of Protect firmware circa 2026-04): `POST /proxy/protect/integration/v1/cameras/{id}/rtsps-stream` now returns **HTTP 400 with empty body** regardless of API key. GET still works and returns current tokens, but you can no longer regenerate tokens programmatically — you must toggle RTSP in the Protect web UI per camera, then GET the fresh URLs. See **[Token regeneration workaround](#-token-regeneration-workaround-post-rtsps-stream-returns-400)**.

---

## ⚠️ Disclaimer

This guide is written by someone who spent an unreasonable number of hours staring at registry keys, RTSP tokens, and CPU graphs at 3 AM. It's based on real-world experience migrating a 62-camera UniFi Protect system to Blue Iris 6.

**This is not official documentation** from either Ubiquiti or Perspective Software. It's a field guide — written in the trenches, for the trenches.

Everything here has been tested on real hardware with real cameras. Your mileage may vary, but at least you'll know where the landmines are.

---

## 🚨 Critical: Resolution Field Mismatch (the silent killer)

> Add date discovered: 2026-04-20 · Cost to discover: ~3 hours of production downtime at 2 AM · Environment: 62-camera PAC deployment.

### The bug in one paragraph

Blue Iris 6 stores two things per camera that MUST stay in sync:
1. **The stream path** (`ip_path` + `ip_subpath` + `ip_path2` + `dsname`) — points at one UniFi Protect RTSP token, which corresponds to ONE specific stream quality (HIGH / MEDIUM / LOW).
2. **The expected frame dimensions** (`xres`, `yres`, `mainxres`, `mainyres`, `zrect_left/top/right/bottom`) — tell BI's H.264/H.265 decoder "the frames I'm about to receive are this big."

If you refresh tokens or switch quality and only touch the path fields (which is what most refresh scripts do — including the ones in earlier versions of this repo), the resolution fields become a lie. BI then tries to fit 640×360 encoded frames into a decoder buffer sized for 2688×1512 (or vice-versa). The decoder throws, BI closes the socket, waits ~20 seconds, retries, same failure. Forever.

### What it looks like

```
1   02:59:28.058   court4    Signal: Socket error
0   02:59:41.972   court4    Signal: main stream loss
1   02:59:41.972   court4    Signal: network retry
1   02:59:53.270   court4    Signal: Socket closed
0   03:00:11.900   court4    Signal: main stream loss
1   03:00:11.900   court4    Signal: network retry
1   03:00:49.730   court4    Signal: Socket error
...
```

Rinse, repeat, every 20 seconds. The BI UI shows "NO SIGNAL" with a red dot.

### The reason this is a silent killer

All of these are **green** when this bug hits:
- ✅ `Test-NetConnection -ComputerName NVR_IP -Port 7447` passes
- ✅ `curl -k https://NVR_IP/proxy/protect/integration/v1/cameras/{id}/rtsps-stream -H "X-API-Key:..."` returns valid tokens
- ✅ Raw RTSP `DESCRIBE` from BI to the NVR returns `200 OK` + valid SDP describing the stream
- ✅ `netstat` on the BI box shows `ESTABLISHED` TCP sessions to port 7447 on the NVR
- ✅ Other cameras on the same NVR using the same port and auth work fine

So every network diagnostic says "the stream is good and BI is talking to the NVR." And yet the camera is dead. The only clue is the Socket error/closed/retry loop in `C:\BlueIris\log\YYYYMM.txt`.

### How to diagnose

1. Pick one stuck camera's current registry values:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras\<CameraName>" |
     Select-Object ip, ip_port2, ip_path, xres, yres, mainxres, mainyres, zrect_right, zrect_bottom
   ```
2. Ask Protect what dimensions that token actually carries. For LOW, it's usually 640×360. For HIGH, usually the camera's native (e.g. 2688×1512 for a G4 Bullet).
3. If `xres`/`yres` doesn't match the stream quality that `ip_path` points to, **that's the bug**.

### The fix (per camera, when pushing a new LOW-quality token)

```powershell
$regPath = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras\$cameraName"

# --- Path fields ---
Set-ItemProperty $regPath -Name 'ip_path'    -Value $lowToken -Force
Set-ItemProperty $regPath -Name 'ip_subpath' -Value $lowToken -Force   # for Protect-fed cams, all three the same works
Set-ItemProperty $regPath -Name 'ip_path2'   -Value $lowToken -Force
Set-ItemProperty $regPath -Name 'dsname' -Value "admin@${nvrIP}:80${lowToken}/:7447:1[${lowToken}]" -Force

# --- Resolution fields: MUST MATCH THE STREAM QUALITY ---
# LOW quality (640x360 is typical for UniFi Protect LOW)
Set-ItemProperty $regPath -Name 'xres'         -Value 640  -Type DWord -Force
Set-ItemProperty $regPath -Name 'yres'         -Value 360  -Type DWord -Force
Set-ItemProperty $regPath -Name 'mainxres'     -Value 2688 -Type DWord -Force   # camera's native resolution (for snapshots)
Set-ItemProperty $regPath -Name 'mainyres'     -Value 1512 -Type DWord -Force
Set-ItemProperty $regPath -Name 'fullxres'     -Value 2688 -Type DWord -Force
Set-ItemProperty $regPath -Name 'fullyres'     -Value 1512 -Type DWord -Force
Set-ItemProperty $regPath -Name 'zrect_left'   -Value 0    -Type DWord -Force
Set-ItemProperty $regPath -Name 'zrect_top'    -Value 0    -Type DWord -Force
Set-ItemProperty $regPath -Name 'zrect_right'  -Value 640  -Type DWord -Force
Set-ItemProperty $regPath -Name 'zrect_bottom' -Value 360  -Type DWord -Force

# --- Audio format (working reference cams all have this set to 7) ---
Set-ItemProperty $regPath -Name 'ip_aformat'   -Value 7    -Type DWord -Force
```

For HIGH quality tokens, set `xres`/`yres`/`zrect_right`/`zrect_bottom` to the camera's native resolution (whatever you see in the UniFi Protect UI for that camera — e.g. 2688×1512, 3840×2160, 2560×1440).

### Reference patterns (from a healthy 62-cam deployment)

| Setup mode | `ip_path` points to | `xres × yres` | `mainxres × mainyres` |
|---|---|---|---|
| LOW quality main stream (low CPU) | LOW token | 640 × 360 | 2688 × 1512 |
| HIGH quality main stream (higher quality recording) | HIGH token | 2688 × 1512 | 2688 × 1512 |

### Why this doesn't bite you during initial setup

When you **add a camera through the Blue Iris UI**, BI probes the stream once at setup time, reads the SDP, and writes all the fields atomically — path AND resolution. It all lines up by construction.

When you **edit the registry directly** (via scripts, bulk imports, or `.reg` files), you only change what you explicitly touch. Everything you didn't touch keeps its old value, which may be stale. That's the whole trap.

### `Refresh-Tokens.ps1` in this repo

The v1 `scripts/Refresh-Tokens.ps1` in this repo (pre-2026-04-20) had this bug — it updated path fields and left resolution fields alone. If your cameras were set up at HIGH and you refreshed to LOW (or vice-versa), they'd go dead silently.

**The v2 script now updates resolution fields too**, reading the actual stream's dimensions from Protect's API before writing. You still need to tell it what resolution to expect per quality — see the updated script header.

---

## 🚨 Token regeneration workaround (POST /rtsps-stream returns 400)

As of Protect firmware versions circa 2026-04 and later, `POST /proxy/protect/integration/v1/cameras/{id}/rtsps-stream` returns:

```
HTTP/1.1 400 Bad Request
Content-Length: 0
```

…with an empty body, regardless of the API key's permissions, the JSON body shape, or whether you try `PATCH` / `PUT` / `DELETE` instead. Multiple body variants tested (`{"qualities":["low"]}`, `{"qualities":["high","medium","low"]}`, `{}`, etc.) all fail identically. `GET` still works fine. This wasn't the case in earlier Protect firmware — it used to work exactly as documented.

**What still works:**
- `GET /proxy/protect/integration/v1/cameras` — list cameras with state ✅
- `GET /proxy/protect/integration/v1/cameras/{id}` — single camera detail ✅
- `GET /proxy/protect/integration/v1/cameras/{id}/rtsps-stream` — current tokens for all qualities ✅

**What doesn't work:**
- `POST`/`PATCH`/`PUT`/`DELETE` anything ❌

### The workaround

To rotate a camera's RTSP tokens (to fix a misbehaving stream, invalidate an old token, etc.):

1. Open Protect web UI → **Devices** → click the camera
2. **Settings** → **Advanced** → scroll to the **RTSP** section
3. **Uncheck** every quality checkbox → **Save**
4. Wait ~3 seconds
5. **Re-check** the quality checkbox(es) you need (usually LOW, optionally HIGH) → **Save**
6. On your management host, run `GET /proxy/protect/integration/v1/cameras/{id}/rtsps-stream` to pull the fresh token(s)
7. Push the fresh tokens to BI (using the fix pattern above, including resolution fields)
8. Restart the Blue Iris service so it picks up the new registry values

The `scripts/Refresh-Tokens.ps1` in this repo has a GET-only mode that works on current firmware — use `-GetOnly` to skip the POST. You'll need to do the UI toggle manually for any camera whose tokens you actually want to rotate.

### Why the POST broke

Unclear. The validator IS running (POST with empty body returns a proper schema error: `"must have required property 'qualities'"`), but any validly-shaped body returns `400` with an empty response. Not a permission issue (the API key has full Admin). Ubiquiti support hasn't acknowledged this publicly as of this writing.

If/when a firmware release fixes this, the old POST-based refresh flow will work again. This warning will stay in the README until then.

---

## 🚨 Critical: Storage Rotation Silent-Failure Modes

> [!danger] Storage rotation can break in three different ways. Each looks the same from outside (drives 100% full, "Disk full" log spam) but the fix is different. Diagnose before patching.

### Failure Mode 1 — Broken Cascade Dead-End

**Symptom:** Drives full. BI logs `Move: over quota X/Y GB` every few minutes but never actually moves files. The "current" GB number keeps creeping up past quota indefinitely.

**Cause:** A storage folder has `moveto` pointing to a NEXT folder whose `path` field is empty (an unconfigured Aux folder). When the source folder fills, BI tries to move clips to the dead-end target, can't, and silently halts instead of falling back to recycle-in-place.

**Real example (62-camera deployment, May 2026):**

| # | Name | Path | moveto | What's wrong |
|---|------|------|--------|--------------|
| 0 | New | `E:\BlueIris\New` | 1 → Stored | OK |
| 1 | Stored | `D:\BlueIris\Stored` | **3 → Aux 1** | ❌ Aux 1 has empty path |
| 2 | Alerts | `C:\BlueIris\Alerts` | 1 → Stored | OK |
| 3 | Aux 1 | `(empty)` | — | dead-end |

**How to detect:**

```powershell
# Audit every storage folder slot
foreach ($i in 0..15) {
    $p = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\clips\folders\$i"
    if (Test-Path $p) {
        $f = Get-ItemProperty $p
        "[$i] $($f.name) path='$($f.path)' moveto=$($f.moveto) action=$($f.action)"
    }
}
```

If any folder you cascade INTO has an empty `path`, you have the bug.

**Fix:** For the **last** folder in the cascade, set `moveto = 0` and `action = 2`. That tells BI: "stop trying to move further — just delete oldest when over quota."

```powershell
# After stopping the BlueIris service:
Set-ItemProperty 'HKLM:\SOFTWARE\Perspective Software\Blue Iris\clips\folders\1' `
    -Name moveto -Value 0 -Type DWord
```

### Failure Mode 2 — `archmb` is the Real Quota, Not `limit`

> [!warning] In BI 6 the `limit` registry field is cosmetic. Quota is enforced by `archmb` (size in MEGABYTES, 1024-based).

**Symptom:** You "lower the quota" by setting `limit` and BI ignores you. The "Move: over quota X/Y GB" log line shows `Y` as a number you never set.

**Why:** Do the math on what BI logs as the quota. If it says `over quota 3168/3166GB`, that 3,166 GB number is `archmb / 1024`. For us: `archmb = 3,241,984 MB → 3,241,984 / 1024 = 3,166 GiB`. Exact match. Meanwhile `limit = 2,900,000,000,000 bytes` (2.9 TB / 2,701 GiB) was never referenced.

| Field | Type | Units | What it actually does |
|-------|------|-------|-----------------------|
| `limit` | QWord | bytes | **Cosmetic / legacy. Not enforced.** |
| `archmb` | DWord | megabytes (1024-based) | **Actual quota trigger.** |
| `limitsize` | DWord | bool | Master switch — set to 1 to enable size-based quota |
| `limitage` | DWord | bool | Master switch — set to 1 to enable age-based purge (paired with `archdays`) |
| `archdays` | DWord | days | Min age before clip is eligible to move/recycle |

**To actually lower a quota:**

```powershell
# Lower New folder quota to ~2.7 TiB (2,800,000 MB)
Set-ItemProperty 'HKLM:\SOFTWARE\Perspective Software\Blue Iris\clips\folders\0' `
    -Name archmb -Value 2800000 -Type DWord
```

Always change `archmb`. Never trust `limit`.

### Failure Mode 3 — Clip Database Desync

**Symptom:** BI logs `DB clips (X TB) > Disk usage (Y TB), run a repair`. Drives fill while BI claims to be rotating. `MoveFile 2` and `MoveFile 3` warnings flood the log.

**Cause:** BI's clip-tracking DB has phantom entries — references to clips that no longer exist on disk. Crashes, manual cleanups, `robocopy /MIR` empty-source tricks, all create this state. When BI's purge loop tries to "delete oldest" it iterates DB entries, finds the file already missing, "succeeds" with 0 bytes freed, and never touches the real clips on disk that aren't in the DB.

**MoveFile error codes** (Win32):

| Code | Meaning | Implies |
|------|---------|---------|
| `MoveFile 2` | `ERROR_FILE_NOT_FOUND` | Source file already deleted (phantom DB entry) |
| `MoveFile 3` | `ERROR_PATH_NOT_FOUND` | Source path missing |
| `MoveFile 31` | Generic device error / destination full | Cascade dead-end or destination drive issue |

**Fix:**

1. Manually free disk space (delete oldest `.bvr` files outside BI)
2. Restart `BlueIris` service — startup log will emit `DB clips (X) > Disk usage (Y), run a repair`
3. Trigger DB repair in the BI UI: **Settings → Cameras → Database tab → Repair / Regenerate**
4. Daily auto-compact runs at 02:00 (`DBCompact: started → DBCompact: OK`) — also clears phantom entries automatically
5. After repair, BI's DB matches disk and rotation resumes

### Confirming Steady State After A Fix

Watch the `Move: over quota` log line for 1+ hours. In a healthy system:

```
0  Move: over quota 3168/3166GB, 537.5 GB free
0  Move: over quota 3166/3166GB, 539.0 GB free
0  Move: over quota 3168/3166GB, 537.0 GB free
```

The "current" number hovers within 2-3 GB of the "quota" number, free space stable to within ±5 GB. That's BI keeping up — moves out match recordings in. If the current keeps creeping up indefinitely, rotation is still broken.

### Service Name Gotcha

The Windows service is named **`BlueIris`** (no space). Its DisplayName is "Blue Iris Service". PowerShell calls using `Get-Service -Name 'Blue Iris'` (with space) return null and silently no-op stop/start logic. **Always use `BlueIris` for `-Name`** (or `'Blue Iris*'` with `-DisplayName`).

```powershell
# CORRECT
Stop-Service  -Name 'BlueIris' -Force
Start-Service -Name 'BlueIris'

# Silently fails — no service with that exact -Name
Stop-Service  -Name 'Blue Iris' -Force
```

---

## 📋 Who Is This For?

| You Are... | This Guide Will... |
|---|---|
| **Complete beginner** to Blue Iris | Walk you through everything from scratch |
| **Existing BI5 user** upgrading to BI6 | Show you the migration path and gotchas |
| **UniFi Protect user** wanting more control | Teach you how to pull RTSP feeds into BI6 |
| **IT admin** managing 20+ cameras | Give you automation scripts and optimization tricks |
| **Someone who Googled "Blue Iris UniFi Protect"** at 2 AM | Save you the 40+ hours we spent figuring this out |

> **Already know your way around?** Skip to [Part 5: Advanced](#-part-5-advanced-topics) for the registry hacks, automation scripts, and performance tuning that took us days to discover.

---

## 🗺️ The Big Picture

Here's what we're building:

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR NETWORK                              │
│                                                                  │
│  ┌──────────┐    ┌──────────┐         ┌──────────────────────┐  │
│  │ Camera 1 │───▶│          │  RTSP   │                      │  │
│  ├──────────┤    │  UniFi   │────────▶│    Blue Iris 6       │  │
│  │ Camera 2 │───▶│ Protect  │         │                      │  │
│  ├──────────┤    │  NVR     │  API    │  • Records to disk   │  │
│  │ Camera 3 │───▶│          │◀───────▶│  • Motion detection  │  │
│  ├──────────┤    │          │         │  • AI analytics      │  │
│  │   ...    │───▶│          │         │  • Mobile app        │  │
│  ├──────────┤    │          │         │  • Web interface     │  │
│  │Camera 62 │───▶│          │         │  • Alerts & triggers │  │
│  └──────────┘    └──────────┘         └──────────────────────┘  │
│                                                                  │
│  Cameras talk to Protect.    BI6 pulls RTSP streams from NVR.   │
│  Protect manages cameras.    BI6 records and analyzes video.     │
└─────────────────────────────────────────────────────────────────┘
```

**Why would you want this?**

UniFi Protect is great at managing cameras — firmware updates, adoption, live view. But Blue Iris 6 is a **recording and analytics powerhouse**:

- **More recording flexibility** — continuous, motion-triggered, scheduled, or mixed
- **Better motion detection** — zone masks, object detection, AI filtering
- **Advanced alerting** — email, push, Telegram, webhooks, MQTT
- **Multi-NVR support** — pull from multiple Protect NVRs into one view
- **Local AI** — built-in person/vehicle/animal detection without cloud
- **Remote access** — web UI, mobile apps, RTSP re-streaming
- **Deeper storage control** — tiered storage, clip management, archival policies

**The trade-off?** You're adding another system to manage. But if you've got more than a handful of cameras and want serious recording/alerting capabilities, it's absolutely worth it.

---

## 🔧 Prerequisites

### Hardware Requirements

Blue Iris 6 runs on Windows and its hardware needs scale with camera count:

| Camera Count | CPU | RAM | GPU | Notes |
|---|---|---|---|---|
| 1–8 cameras | Intel i5 (6th gen+) | 8 GB | Not required | Entry level |
| 8–16 cameras | Intel i7 (8th gen+) | 16 GB | Recommended | Mid-range |
| 16–32 cameras | Intel i7/i9 (10th gen+) | 16–32 GB | Recommended | Prosumer |
| 32–64 cameras | Intel i7/i9 (12th gen+) | 32 GB | Required | Enterprise |
| 64–128 cameras | Intel i9/Xeon | 32–64 GB | Required | Maximum |

> **Our test system:** Intel i7-12700 (12 cores/20 threads), RTX 3060 12GB, Intel UHD 770, 32GB RAM — running 62 cameras comfortably at ~9% BI6 CPU usage after optimization.

**GPU Notes:**
- NVIDIA GPUs with NVENC provide the best hardware decode support
- Intel Quick Sync (built into most Intel CPUs) works well as a secondary decoder
- AMD GPUs are **NOT supported** for hardware acceleration in Blue Iris as of 2026
- For 30+ cameras, having BOTH an NVIDIA GPU and Intel Quick Sync gives you two decode engines

### Storage Requirements

| Use Case | Recommended | Formula |
|---|---|---|
| Database + temp | SSD, 100+ GB | Fast I/O for BI6 database |
| Active recordings | SSD or HDD, 1+ TB | `cameras × avg_bitrate × hours_retained ÷ 8` |
| Archive | HDD, 2+ TB | Long-term storage, lower I/O requirements |
| Alert images | SSD, 50+ GB | Snapshots from motion events |

**Storage calculation example:**
- 30 cameras at 4 Mbps average bitrate, 7-day retention
- `30 × 4 Mbps × 86400 sec × 7 days ÷ 8 = ~9 TB`
- With motion-only recording, expect 30–50% of that

### Software Requirements

- **Windows 10/11 Pro** (64-bit) — Pro recommended for Remote Desktop
- **Blue Iris 6** — [blueirissoftware.com](https://blueirissoftware.com) ($75 new license; **free** for BI4/BI5 users with active maintenance)
- **UniFi Protect** — Running on a UniFi NVR (UNVR, UNVR Pro, UDM Pro, Cloud Key Gen2+)
- **UniFi Protect firmware** — 5.3 or later (Integration API support)
- **Microsoft Visual C++ Redistributable v145** — required by BI6 (installer usually handles this)
- **.NET Framework 4.8+** — Usually pre-installed on Windows 10/11

### Network Requirements

- Blue Iris PC and UniFi NVR must be on the **same network** (or routable VLANs)
- Sufficient bandwidth: `cameras × stream_bitrate`
  - LOW quality: ~1 Mbps per camera
  - HIGH quality: ~4–8 Mbps per camera
  - 62 cameras at LOW = ~62 Mbps (easily handled by gigabit)
- Recommended: Dedicated VLAN for camera traffic

---

## 📖 Part 1: Understanding the Ecosystem

### What is Blue Iris?

Blue Iris (BI) is a Windows-based video management system (VMS) that's been around since 2007. It started as a hobbyist project and grew into one of the most popular NVR software packages for prosumers and small businesses.

**Blue Iris 6** (released 2024) brought significant improvements:
- Modernized UI with dark mode support
- Native HTTPS for the web interface
- Built-in AI object detection (person, vehicle, animal)
- Increased camera limit to 128 (up from 64)
- Improved database format for faster searches
- Better multi-GPU decode support
- Enhanced Direct-to-Disc recording

**Key concept:** Blue Iris doesn't talk to cameras natively through UniFi Protect's protocol. Instead, it pulls **RTSP video streams** — a standard protocol that almost every IP camera and NVR supports.

### What is UniFi Protect?

UniFi Protect is Ubiquiti's video surveillance platform. It runs on UniFi hardware (UNVR, UDM Pro, etc.) and manages UniFi cameras.

**Key features:**
- Zero-config camera adoption
- Automatic firmware updates
- Smart detection (person, vehicle, animal, package)
- Cloud and local access
- Recording and playback
- Integration API for third-party access

**The Integration API** is what makes this whole guide possible. It lets third-party software (like Blue Iris) request RTSP stream URLs for any camera on the NVR.

### How They Work Together

```
                                 Integration API
                                 (HTTPS + API Key)
                                        │
    ┌─────────────┐            ┌────────▼────────┐           ┌─────────────┐
    │   Cameras    │───ONVIF──▶│  UniFi Protect   │◀──RTSP──▶│  Blue Iris 6 │
    │              │           │     NVR          │           │             │
    │ • Managed by │           │ • Camera mgmt   │           │ • Recording │
    │   Protect    │           │ • RTSP server    │           │ • Motion    │
    │ • Firmware   │           │ • Smart detect   │           │ • AI        │
    │   updates    │           │ • Token auth     │           │ • Alerts    │
    └─────────────┘           └──────────────────┘           └─────────────┘
```

1. **Cameras** connect to the **UniFi Protect NVR** (they're "adopted" in Protect)
2. **You** request RTSP stream tokens from the **Integration API**
3. **Blue Iris** connects to the NVR using those RTSP tokens
4. **Both systems run simultaneously** — Protect still manages the cameras, BI6 records the streams

> **Important:** You're not replacing Protect. You're supplementing it. Protect still handles camera management, firmware, and its own recording. Blue Iris adds a second recording layer with more flexibility.

### RTSP: The Glue That Holds It All Together

**RTSP** (Real-Time Streaming Protocol) is how cameras stream video over a network. Think of it like a URL for a video feed:

```
rtsp://192.168.1.100:7447/abc123TokenHere
       ─────┬──────  ──┬─ ────────┬───────
           NVR IP    Port   Stream Token
```

UniFi Protect NVRs serve RTSP streams on two ports:
- **Port 7447** — RTSP (unencrypted, faster)
- **Port 7441** — RTSPS (TLS encrypted, more secure)

Blue Iris works with both, but **port 7447 (RTSP) is recommended** for lower CPU overhead.

### Stream Quality Levels

Each camera on UniFi Protect can provide up to three stream quality levels:

| Quality | Typical Resolution | Bitrate | Use Case |
|---|---|---|---|
| **HIGH** | Native (2K/4K) | 4–8 Mbps | Full-quality recording |
| **MEDIUM** | Varies | 2–4 Mbps | ⚠️ **UNRELIABLE — avoid** |
| **LOW** | 640×360 | 0.5–1 Mbps | Grid view, motion detection |

> **⚠️ Critical Warning:** In our testing across 62 cameras, **MEDIUM quality tokens failed for ~40% of cameras**. HIGH and LOW worked for 100%. **Always use HIGH or LOW — never MEDIUM.**

---

## 🛠️ Part 2: Setting Up Blue Iris 6

### Fresh Install vs. Upgrade from BI5

| Approach | Pros | Cons |
|---|---|---|
| **Fresh install** | Clean config, no legacy issues, optimal database | Must reconfigure cameras |
| **In-place upgrade** | Keeps existing cameras, settings, schedules | May inherit BI5 bugs, database migration issues |

**Our recommendation: Fresh install.** If you're integrating with UniFi Protect anyway, you'll be setting up new RTSP connections regardless. A clean install gives you the best foundation.

If you must upgrade in-place, BI6 will automatically convert your BI5 database and pick up existing cameras. But back up EVERYTHING first.

### Installation Steps

#### Step 1: Download and Install

1. Purchase Blue Iris 6 from [blueirissoftware.com](https://blueirissoftware.com) ($70 USD, one-time)
2. Download the installer
3. Run the installer as Administrator
4. Choose default installation path (`C:\Program Files\Blue Iris\`)
5. When prompted, enter your license key
6. The installer will set up a Windows service called "Blue Iris"

#### Step 2: Initial Configuration

After installation, Blue Iris will launch and walk you through initial setup:

1. **Admin password** — Set a strong password for the admin account
2. **Web server** — Enable and set a port (default: 80, we recommend 81 or 8080)
3. **Storage paths** — Configure where recordings go (see storage recommendations above)

#### Step 3: Storage Configuration (Important!)

Set up tiered storage for optimal performance:

```
┌─────────────────────────────────────────────┐
│  Drive C: (SSD)                             │
│  └── C:\BlueIris\db       → Database/temp   │
│                                              │
│  Drive D: (SSD or fast HDD)                 │
│  └── D:\BlueIris\clips    → Active clips    │
│  └── D:\BlueIris\alerts   → Alert images    │
│                                              │
│  Drive E: (Large HDD)                       │
│  └── E:\BlueIris\archive  → Long-term       │
└─────────────────────────────────────────────┘
```

In Blue Iris settings:
- **Settings → Clips and Archiving → Folders**
- Set "New" folder to your SSD path
- Set "Stored" folder to your HDD path
- Set limits based on drive capacity
- Enable "Direct-to-disc" for better I/O performance (writes camera's native stream to disk without re-encoding — **massive CPU savings**)
- **Pro tip:** Format video storage drives with **1 MB cluster size** (not the default 4 KB) to reduce fragmentation for large sequential video writes

#### Step 4: Create a Template Camera

Before bulk-adding cameras, create ONE camera manually to use as a template:

1. Click the **"+"** button to add a camera
2. Enter a name (e.g., "Template Camera")
3. For the connection type, select **RTSP/RTMP/HTTP**
4. Enter your NVR's IP address and port 7447
5. For the path, enter any valid RTSP token (we'll get these next)
6. Test the connection
7. Configure your preferred settings (recording mode, motion sensitivity, etc.)
8. This camera's settings will serve as your baseline for all others

---

## 🔌 Part 3: Connecting UniFi Protect to Blue Iris 6

This is where the magic happens. We'll use UniFi Protect's Integration API to get RTSP stream tokens, then configure Blue Iris to pull those streams.

### Step 1: Enable the Integration API

The Integration API must be enabled on your UniFi Protect NVR:

1. Open the **UniFi Protect** web interface (not the mobile app — web UI only)
2. Go to **Settings** (gear icon)
3. Navigate to **Control Plane** → **Integrations** → **Your API Keys**
4. Enter a descriptive name (e.g., "BlueIris-Integration")
5. Click **"Create API Key"**
6. **Copy the key IMMEDIATELY** — it's shown only once and cannot be retrieved later

> **Hardware note:** Some older hardware (UCK G2 Plus) may not have the Integrations menu. Ensure your UniFi OS and Protect firmware are fully updated to 5.3+.

> **Note:** You need a separate API key for each NVR. If you have multiple NVRs, repeat this process for each one.

```
Your API key will look something like this:
AbCdEfGh1234567890XyZqWeRtYuIoPaS

Keep it secret. Keep it safe. Anyone with this key can access your camera streams.
```

### Step 2: Discover Your Cameras

Now let's find out what cameras are on your NVR. Open PowerShell (or any tool that can make HTTPS requests):

```powershell
# Set your NVR details
$nvrIP = "192.168.1.100"      # ← Your NVR's IP address
$apiKey = "YOUR_API_KEY_HERE"  # ← Your Integration API key

# Skip certificate validation (NVR uses self-signed certs)
# PowerShell 7+:
$headers = @{ "X-API-Key" = $apiKey }

# Get all cameras
$cameras = Invoke-RestMethod `
    -Uri "https://${nvrIP}/proxy/protect/integration/v1/cameras" `
    -Headers $headers `
    -SkipCertificateCheck

# Display camera names and IDs
$cameras | ForEach-Object {
    Write-Output "$($_.name) | ID: $($_.id) | State: $($_.state)"
}
```

**Using curl instead:**
```bash
curl -k -X GET \
  "https://192.168.1.100/proxy/protect/integration/v1/cameras" \
  -H "X-API-Key: YOUR_API_KEY_HERE" | python -m json.tool
```

You'll get back a JSON array of all cameras with their details: name, ID, model, state, firmware version, and more.

### Step 3: Generate RTSP Stream Tokens

For each camera, you need to request RTSP stream tokens. These tokens are what Blue Iris uses to connect:

```powershell
# Generate tokens for a specific camera
$cameraId = "camera-uuid-from-step-2"

$body = '{"qualities":["high","low"]}'

$response = Invoke-RestMethod `
    -Uri "https://${nvrIP}/proxy/protect/integration/v1/cameras/${cameraId}/rtsps-stream" `
    -Method POST `
    -Headers $headers `
    -Body $body `
    -ContentType "application/json" `
    -SkipCertificateCheck

# Response contains:
# {
#   "high": "rtsps://192.168.1.100:7441/aBcDeFgH12345678",
#   "low":  "rtsps://192.168.1.100:7441/xYzQwErT87654321"
# }

Write-Output "HIGH: $($response.high)"
Write-Output "LOW:  $($response.low)"
```

**Important conversion:** The API returns `rtsps://` URLs on port `7441`. For Blue Iris, convert to `rtsp://` on port `7447`:

```
API returns:  rtsps://192.168.1.100:7441/aBcDeFgH12345678
BI6 uses:     rtsp://192.168.1.100:7447/aBcDeFgH12345678
                                   ────
                                   The token works on both ports!
```

### Step 4: Bulk Token Generation Script

Don't generate tokens one by one for 30+ cameras. Use this script:

```powershell
#############################################
# UniFi Protect → Blue Iris Token Generator
# Generates RTSP tokens for ALL cameras
#############################################

param(
    [Parameter(Mandatory=$true)]
    [string]$NvrIP,

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,

    [string[]]$Qualities = @("high", "low")
)

# Skip cert validation
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
$splat = @{ Headers = $headers }
if ($PSVersionTable.PSVersion.Major -ge 7) { $splat["SkipCertificateCheck"] = $true }

# Get all cameras
Write-Host "Fetching cameras from NVR at $NvrIP..." -ForegroundColor Cyan
$cameras = Invoke-RestMethod -Uri "https://${NvrIP}/proxy/protect/integration/v1/cameras" @splat

Write-Host "Found $($cameras.Count) cameras." -ForegroundColor Green

$results = @()

foreach ($cam in $cameras) {
    if ($cam.state -ne "CONNECTED") {
        Write-Host "  SKIP: $($cam.name) (state: $($cam.state))" -ForegroundColor Yellow
        continue
    }

    $qualityJson = ($Qualities | ForEach-Object { "`"$_`"" }) -join ","
    $body = "{`"qualities`":[$qualityJson]}"

    try {
        $resp = Invoke-RestMethod `
            -Uri "https://${NvrIP}/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
            -Method POST @splat `
            -Body $body `
            -ContentType "application/json"

        $result = [PSCustomObject]@{
            Name    = $cam.name
            ID      = $cam.id
            Model   = $cam.type
            State   = $cam.state
        }

        # Extract tokens from URLs
        foreach ($q in $Qualities) {
            $url = $resp.$q
            if ($url -match "rtsps?://[^:]+:\d+/(.+?)(\?|$)") {
                $token = $Matches[1]
                $result | Add-Member -NotePropertyName "${q}Token" -NotePropertyValue $token
                $result | Add-Member -NotePropertyName "${q}RTSP" -NotePropertyValue "rtsp://${NvrIP}:7447/${token}"
            }
        }

        $results += $result
        Write-Host "  OK: $($cam.name)" -ForegroundColor Green
    }
    catch {
        Write-Host "  FAIL: $($cam.name) — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Export to CSV
$csvPath = ".\camera_tokens_$(Get-Date -Format 'yyyy-MM-dd_HHmm').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "`nExported $($results.Count) cameras to $csvPath" -ForegroundColor Cyan

# Display summary
$results | Format-Table Name, State, highToken, lowToken -AutoSize
```

**Usage:**
```powershell
.\Generate-Tokens.ps1 -NvrIP "192.168.1.100" -ApiKey "YOUR_API_KEY"
```

### Step 5: Add Cameras to Blue Iris

You have three options for adding cameras:

#### Option A: Manual (GUI) — Best for 1–10 cameras

1. In Blue Iris, click **"+"** to add a camera
2. Name: Enter the camera name
3. Connection type: **IP camera / RTSP**
4. IP/Host: Your NVR's IP (e.g., `192.168.1.100`)
5. Port: `7447`
6. Path: `/{token}` (the token from Step 3, with leading slash)
7. Protocol: **RTSP over TCP**
8. Username: `admin` (or leave blank)
9. **CRITICAL:** Check **"Skip MAC, HTTP, DNS Reachability tests"** — all UniFi cameras share the NVR's MAC address, so BI gets confused without this when adding multiple cameras
10. Click **"Test"** — you should see the video feed
11. Configure recording, motion, and other settings
12. Repeat for each camera

#### Option B: Registry Injection — Best for 10+ cameras (Recommended)

This is the power-user approach. Blue Iris stores all camera configs in the Windows registry. You can create cameras by writing directly to the registry.

> **⚠️ CRITICAL: Always stop the Blue Iris service before editing the registry.** Blue Iris periodically writes its in-memory state back to the registry, overwriting your changes within seconds.

```powershell
#########################################
# Stop Blue Iris FIRST!
#########################################
Stop-Service -Name "BlueIris" -Force
Start-Sleep -Seconds 5

#########################################
# Create a camera in the registry
#########################################
$cameraName = "Front Door"
$nvrIP = "192.168.1.100"
$mainToken = "aBcDeFgH12345678"  # HIGH or LOW token
$subToken = "xYzQwErT87654321"   # LOW token for sub stream

$regPath = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras\$cameraName"

# Create the key if it doesn't exist
if (!(Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

# Native resolution of the camera (look it up in Protect UI -> camera -> settings)
# Common values: G4 Bullet = 2688x1512, G4 Pro = 3840x2160, G3 Flex = 1920x1080
$nativeXres = 2688
$nativeYres = 1512

# Main stream quality determines xres/yres — MUST match the token you pointed ip_path at
# If $mainToken is a LOW token, use 640x360. If HIGH, use the camera's native resolution.
$mainXres = 640   # LOW quality stream dimensions
$mainYres = 360

# Required properties
$props = @{
    # Connection
    "type"           = 4          # 4 = IP camera
    "ip"             = $nvrIP
    "ip_port"        = 80         # Base port (NOT 7447!)
    "ip_port2"       = 7447       # RTSP port
    "ip_path"        = "/$mainToken"
    "ip_subpath"     = "/$subToken"    # THE REAL sub stream field!
    "ip_path2"       = "/$subToken"    # Set same for compatibility

    # DSName (Blue Iris reconstructs this on startup)
    "dsname"         = "admin@${nvrIP}:80/${mainToken}/:7447:1[/${subToken}]"

    # Authentication
    "ipid"           = "admin"
    "ippw"           = "YWRtaW4="      # base64("admin")
    "ippwencode"     = 1

    # Enable
    "enable"         = 1
    "enabled"        = 1
    "active"         = 254

    # Performance
    "smartdecode"    = 1          # HUGE CPU saver
    "bvr"            = 1          # Direct-to-disc
    "hwaccel"        = 1          # Hardware acceleration
    "gpu"            = "any"      # Use any available GPU
    "ip_fps"         = 10         # Buffer hint (not a throttle!)

    # Camera settings
    "ip_device"      = 135
    "ip_camno"       = 1
    "ip_keepalives"  = 1
    "ip_rtsptime"    = 1
    "screencap"      = 1
    "hidden"         = 0
    "format"         = 0
    "pixfmt"         = 12
    "rtp"            = 0
    "https"          = 0

    # ⚠️ RESOLUTION FIELDS — MUST match the quality that ip_path points at
    # See "Critical: Resolution Field Mismatch" section above — get this wrong and the
    # camera will silently fail to stream with a Socket error retry loop.
    "xres"           = $mainXres      # main stream pixel width (matches ip_path quality)
    "yres"           = $mainYres      # main stream pixel height
    "mainxres"       = $nativeXres    # camera's native resolution (for snapshots)
    "mainyres"       = $nativeYres
    "fullxres"       = $nativeXres
    "fullyres"       = $nativeYres
    "zrect_left"     = 0              # motion detection rectangle — match main stream size
    "zrect_top"      = 0
    "zrect_right"    = $mainXres
    "zrect_bottom"   = $mainYres
    "ip_aformat"     = 7              # audio format (empirical: 7 works for UniFi Protect RTSP)
}

foreach ($key in $props.Keys) {
    $value = $props[$key]
    $type = if ($value -is [int]) { "DWord" } else { "String" }
    Set-ItemProperty -Path $regPath -Name $key -Value $value -Type $type
}

Write-Host "Created camera: $cameraName" -ForegroundColor Green

#########################################
# Start Blue Iris and wait for cameras
#########################################
Start-Service -Name "BlueIris"
Write-Host "Starting Blue Iris... waiting 2 minutes for cameras to connect."
Start-Sleep -Seconds 120
```

#### Option C: Bulk Registry Script — The Full Automation

Combine token generation (Step 4) with registry injection for fully automated setup:

```powershell
#########################################
# Full Automation: Protect → BI6
# Discovers cameras, generates tokens,
# creates all cameras in Blue Iris registry
#########################################

param(
    [Parameter(Mandatory=$true)] [string]$NvrIP,
    [Parameter(Mandatory=$true)] [string]$ApiKey,
    [string]$Quality = "low"   # "high" or "low"
)

# 1. Stop Blue Iris
Write-Host "Stopping Blue Iris..." -ForegroundColor Yellow
Stop-Service -Name "BlueIris" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# 2. Get cameras from Protect
$headers = @{ "X-API-Key" = $ApiKey }
$cameras = Invoke-RestMethod `
    -Uri "https://${NvrIP}/proxy/protect/integration/v1/cameras" `
    -Headers $headers -SkipCertificateCheck

Write-Host "Found $($cameras.Count) cameras on NVR" -ForegroundColor Cyan

$created = 0
foreach ($cam in $cameras) {
    if ($cam.state -ne "CONNECTED") { continue }

    # Generate token
    $body = "{`"qualities`":[`"$Quality`"]}"
    $resp = Invoke-RestMethod `
        -Uri "https://${NvrIP}/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
        -Method POST -Headers $headers -Body $body `
        -ContentType "application/json" -SkipCertificateCheck

    if ($resp.$Quality -match "/([^/?]+)") {
        $token = $Matches[1]
    } else { continue }

    # Create registry entry
    $regPath = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras\$($cam.name)"
    if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

    # Set all required properties (abbreviated — see full list in Option B)
    @{
        type=4; ip=$NvrIP; ip_port=80; ip_port2=7447
        ip_path="/$token"; ip_subpath="/$token"; ip_path2="/$token"
        dsname="admin@${NvrIP}:80/${token}/:7447:1[/${token}]"
        enable=1; enabled=1; active=254
        smartdecode=1; bvr=1; hwaccel=1; gpu="any"; ip_fps=10
        ipid="admin"; ippw="YWRtaW4="; ippwencode=1
        ip_device=135; ip_camno=1; screencap=1; hidden=0
        format=0; pixfmt=12; rtp=0; https=0
    }.GetEnumerator() | ForEach-Object {
        $type = if ($_.Value -is [int]) { "DWord" } else { "String" }
        Set-ItemProperty -Path $regPath -Name $_.Key -Value $_.Value -Type $type
    }

    Write-Host "  Created: $($cam.name)" -ForegroundColor Green
    $created++
}

# 3. Start Blue Iris
Write-Host "`nStarting Blue Iris with $created cameras..." -ForegroundColor Yellow
Start-Service -Name "BlueIris"
Write-Host "Waiting 2.5 minutes for cameras to connect..." -ForegroundColor Cyan
Start-Sleep -Seconds 150

Write-Host "`nDone! Check Blue Iris for camera status." -ForegroundColor Green
```

### Step 6: Verify Everything Works

After Blue Iris starts, verify your cameras:

**Via the Blue Iris UI:**
- Open Blue Iris on the desktop
- You should see camera tiles appearing in the grid
- Each camera should show video (may take 1–2 minutes)
- Look for any "NO SIGNAL" cameras

**Via the Blue Iris API:**
```powershell
# Quick status check via BI6 JSON API
$biPort = 81  # Your BI6 web server port
$biUser = "admin"
$biPass = "your_bi_password"

# Step 1: Login
$login = Invoke-RestMethod -Uri "http://127.0.0.1:${biPort}/json" `
    -Method POST -Body '{"cmd":"login"}' -ContentType "application/json"
$session = $login.session

# Step 2: Authenticate
$md5Input = "${biUser}:${session}:${biPass}"
$md5 = [System.Security.Cryptography.MD5]::Create()
$bytes = [System.Text.Encoding]::ASCII.GetBytes($md5Input)
$hash = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""

$auth = Invoke-RestMethod -Uri "http://127.0.0.1:${biPort}/json" `
    -Method POST -ContentType "application/json" `
    -Body "{`"cmd`":`"login`",`"session`":`"$session`",`"response`":`"$hash`"}"

# Step 3: Get camera list
$camlist = Invoke-RestMethod -Uri "http://127.0.0.1:${biPort}/json" `
    -Method POST -ContentType "application/json" `
    -Body "{`"cmd`":`"camlist`",`"session`":`"$session`"}"

# Display results
$camlist.data | Where-Object { $_.isOnline -ne $null } |
    Format-Table @{L="Name";E={$_.optionDisplay}},
                 @{L="Online";E={if($_.isOnline){"✅"}else{"❌"}}},
                 @{L="FPS";E={[math]::Round($_.FPS,1)}},
                 @{L="Resolution";E={"$($_.width)x$($_.height)"}} -AutoSize
```

---

## ⚡ Part 4: Optimization (The Fun Part)

This is where we turn a working system into a **performant** system. These optimizations were discovered through real-world testing on a 62-camera deployment.

### The Big Three CPU Savers

These three settings had the biggest impact on CPU usage. Combined, they dropped CPU from **100% to 9%** on our test system:

#### 1. Smart Decode (`smartdecode=1`) — The Biggest Win

**What it does:** Only decodes video keyframes (I-frames) for cameras that aren't actively being viewed. Full decoding only happens when you click on a camera, it triggers an alert, or it's being streamed remotely.

**Impact:** Dropped BI6 CPU from **100% to 12%** by itself.

```
Without smartdecode:  BI6 decodes ALL frames from ALL cameras ALL the time
With smartdecode:     BI6 only decodes keyframes unless you're watching

┌──────────────────────────────────────────────────────────┐
│ 62 cameras × 30fps = 1,860 frames/second to decode      │
│                          vs.                              │
│ 62 cameras × ~2 keyframes/sec = 124 frames/second       │
│                                                           │
│ That's a 15x reduction in decode work.                    │
└──────────────────────────────────────────────────────────┘
```

**How to enable:**
- Per camera in BI6 UI: Camera settings → Video → "Limit decoding unless required"
- Registry: `smartdecode = 1` (DWORD) per camera

> **⚠️ Gotcha:** When someone connects remotely or opens an "all cameras" view, BI temporarily disables smartdecode for those cameras and decodes at full rate. This can cause a sudden CPU spike. Size your hardware to handle this occasional burst.

#### 2. Limit Live Preview (`limit_live=1`) — Grid View Saver

**What it does:** Throttles the rendering frame rate for the camera grid view. Instead of rendering every frame at full rate for all visible cameras, it shows lower-rate thumbnail updates.

**Impact:** Reduces CPU load from rendering, especially when the BI6 window is visible.

**How to enable:**
- BI6 UI: Settings → Other → "Limit live preview"
- Registry: `limit_live = 1` (DWORD) global setting

#### 3. Stream Quality Selection — Memory Miracle

Using **LOW quality** streams (640×360) instead of HIGH (2K/4K) dramatically reduces resource usage:

| Metric | HIGH Quality | LOW Quality | Improvement |
|---|---|---|---|
| Memory | ~10 GB | ~137 MB | **73× less** |
| CPU per frame | High (large frames) | Minimal | ~10× less |
| Bandwidth | ~250 Mbps | ~62 Mbps | 4× less |
| Storage | ~9 TB/week | ~2 TB/week | 4× less |

**The trade-off:** LOW quality records at 640×360. That's fine for motion detection and general surveillance, but not great if you need to zoom in and identify faces or license plates.

**Best strategy:** Use LOW for the majority of cameras, HIGH for entrances, cash registers, and other critical views where identification matters.

### Dual Streaming: Best of Both Worlds

Blue Iris 6 supports dual streaming — a main stream for recording and a sub stream for the live grid view:

```
┌────────────────────────────────────┐
│  Camera: "Front Door"              │
│                                     │
│  Main Stream (ip_path):            │
│  → HIGH quality token               │
│  → Used for recording               │
│  → Full resolution (2K/4K)          │
│                                     │
│  Sub Stream (ip_subpath):           │
│  → LOW quality token                │
│  → Used for grid view               │
│  → 640×360 (saves CPU)              │
└────────────────────────────────────┘
```

> **⚠️ CRITICAL DISCOVERY: `ip_subpath` is the real sub stream field in Blue Iris 6, NOT `ip_path2`!**
>
> This took us HOURS to figure out. The Blue Iris documentation and many forum posts reference `ip_path2` as the sub stream field. **It's not.** In BI6, the sub stream is controlled by `ip_subpath`. Setting `ip_path2` does nothing for the sub stream.
>
> **How we confirmed it:** The BI6 `dsname` field shows the sub stream token in square brackets. With `ip_path2` set, the brackets were empty: `[]`. After setting `ip_subpath`, the brackets populated: `[/token]`.

### Registry Settings Reference

#### Per-Camera Settings
```
HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras\{CameraName}
```

| Key | Type | Value | Description |
|---|---|---|---|
| `ip_path` | String | `/{token}` | Main stream RTSP path |
| `ip_subpath` | String | `/{token}` | **Sub stream path (THE REAL ONE)** |
| `ip_path2` | String | `/{token}` | Legacy field — set same as ip_subpath |
| `smartdecode` | DWORD | `1` | Limit decoding unless camera is viewed |
| `bvr` | DWORD | `1` | Direct-to-disc recording |
| `hwaccel` | DWORD | `1` | Hardware acceleration |
| `gpu` | String | `any` | GPU selection (`any`, `nvidia`, `intel`) |
| `ip_fps` | DWORD | `10` | Buffer sizing hint (NOT a framerate throttle!) |
| `ip` | String | `{NVR_IP}` | NVR IP address |
| `ip_port` | DWORD | `80` | Base connection port |
| `ip_port2` | DWORD | `7447` | RTSP stream port |
| `type` | DWORD | `4` | Camera type (4 = IP camera) |

#### Global Settings
```
HKLM:\SOFTWARE\Perspective Software\Blue Iris
```

| Key | Type | Value | Description |
|---|---|---|---|
| `limit_live` | DWORD | `1` | Limit live preview rendering |
| `limit_decode` | DWORD | `1` | Global decode limiting |
| `limit_streaming` | DWORD | `1` | Limit streaming decode |
| `direct_to_disc` | DWORD | `1` | Enable D2D globally |
| `gpudecode` | DWORD | `1` | Enable GPU decode |
| `hwaccel` | DWORD | `1` | Global hardware acceleration |

### The DSName Format Explained

The `dsname` field is how Blue Iris internally represents a camera's full connection string:

```
admin@192.168.1.100:80/MainToken/:7447:1[/SubToken]
  │        │        │     │        │   │    │
  │        │        │     │        │   │    └── Sub stream token (from ip_subpath)
  │        │        │     │        │   └── Connection type (1 = RTSP)
  │        │        │     │        └── RTSP port (from ip_port2)
  │        │        │     └── Main stream token (from ip_path)
  │        │        └── Base port (from ip_port)
  │        └── NVR IP address (from ip field)
  └── Username (from ipid field)
```

Blue Iris reconstructs `dsname` from its component fields on startup. You can set `dsname` directly, but BI6 may overwrite it. **Always set the component fields too.**

### Additional Optimizations

#### Windows-Level Tweaks

| Optimization | Impact | How |
|---|---|---|
| **Windows Defender exclusions** | 5–10% CPU saved | Exclude BI6 folders from real-time scanning |
| **Kill remote access tools** | 5–10% CPU saved | ScreenConnect, TeamViewer use CPU for screen capture |
| **Minimize BI6 window** | Reduces dwm.exe CPU | Desktop Window Manager renders video tiles via RDP |
| **Run as headless service** | Eliminates UI overhead | Best for dedicated servers with no monitor |
| **Disable BI6 timestamp overlay** | Minor CPU save | Cameras already have their own timestamps |

**Windows Defender exclusion commands:**
```powershell
# Run as Administrator
Add-MpPreference -ExclusionPath "C:\BlueIris"
Add-MpPreference -ExclusionPath "D:\BlueIris"
Add-MpPreference -ExclusionPath "E:\BlueIris"
Add-MpPreference -ExclusionProcess "BlueIris.exe"
```

#### FPS Control (It's Not Where You Think)

> **`ip_fps` does NOT control the framerate coming from the NVR.** It's a buffer sizing hint that tells Blue Iris how large to make its internal frame buffer. The actual FPS is determined by the stream profile on the UniFi Protect NVR.

**To actually reduce FPS:**
1. Log into **UniFi Protect** web UI
2. Go to each camera's settings → **Recording Profile**
3. Find the **LOW quality** profile
4. Change the target FPS (e.g., from 30 to 10 or 15)
5. This change affects ALL consumers of the LOW stream

**Why reduce FPS?**
- 62 cameras at 30fps = 1,860 frames/second to process
- 62 cameras at 10fps = 620 frames/second
- That's a **67% reduction** in total frames BI6 needs to handle

### Performance Benchmarks

Real-world results from a 62-camera system (i7-12700, RTX 3060, 32GB RAM):

| Configuration | System CPU | BI6 CPU | Memory | Cameras |
|---|---|---|---|---|
| HIGH quality, no optimization | 100% | 100% | ~10 GB | 62/62 |
| HIGH + smartdecode + limit_live | ~65% | ~15% | ~8 GB | 62/62 |
| LOW main + LOW sub | ~70% | ~20% | ~137 MB | 62/62 |
| **LOW + smartdecode + limit_live** | **~62%** | **~9%** | **~137 MB** | **62/62** |
| LOW + smartdecode + Defender excluded | ~50% | ~9% | ~137 MB | 62/62 (est.) |

The remaining system CPU is consumed by:
- `dwm.exe` — Desktop Window Manager (rendering via RDP)
- `MsMpEng.exe` — Windows Defender (scanning video files)
- `SRService.exe` — ScreenConnect (remote access tool)
- Background Windows services

---

## 🧪 Part 5: Advanced Topics

> This section is for experienced users who want to automate, script, and push the system to its limits.

### Token Lifecycle and Refresh

RTSP tokens generated by UniFi Protect:
- Are **permanent** — they do not expire on their own
- Remain valid as long as RTSP is enabled for that stream quality on the camera
- Multiple active tokens can coexist for the same camera
- Only invalidated by: disabling RTSP on the camera, factory resetting the camera, or revoking the API key
- If cameras go NO_SIGNAL with a previously working token, the issue is usually network/NVR, not token expiry

> **Note:** Don't confuse RTSP stream tokens with camera *adoption* tokens (those expire in 60 minutes). Stream tokens are permanent identifiers.

**Automated token refresh script:**

```powershell
##############################################
# Scheduled Token Refresh for Blue Iris + Protect
# Run as a Windows Scheduled Task (weekly)
##############################################

param(
    [string]$ConfigPath = "C:\BlueIris\token_config.json"
)

# Load config (NVR IPs, API keys)
$config = Get-Content $ConfigPath | ConvertFrom-Json

foreach ($nvr in $config.nvrs) {
    $headers = @{ "X-API-Key" = $nvr.apiKey }

    # Get cameras
    $cameras = Invoke-RestMethod `
        -Uri "https://$($nvr.ip)/proxy/protect/integration/v1/cameras" `
        -Headers $headers -SkipCertificateCheck

    # Generate fresh tokens
    $tokenMap = @{}
    foreach ($cam in $cameras | Where-Object { $_.state -eq "CONNECTED" }) {
        $resp = Invoke-RestMethod `
            -Uri "https://$($nvr.ip)/proxy/protect/integration/v1/cameras/$($cam.id)/rtsps-stream" `
            -Method POST -Headers $headers `
            -Body '{"qualities":["low"]}' `
            -ContentType "application/json" -SkipCertificateCheck

        if ($resp.low -match "/([^/?]+)") {
            $tokenMap[$cam.name] = $Matches[1]
        }
    }

    # Stop BI6
    Stop-Service -Name "BlueIris" -Force
    Start-Sleep -Seconds 5

    # Update registry
    $regBase = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras"
    foreach ($entry in $tokenMap.GetEnumerator()) {
        $camName = $entry.Key
        $token = $entry.Value
        $regPath = "$regBase\$camName"

        if (Test-Path $regPath) {
            Set-ItemProperty $regPath -Name "ip_path" -Value "/$token"
            Set-ItemProperty $regPath -Name "ip_subpath" -Value "/$token"
            Set-ItemProperty $regPath -Name "ip_path2" -Value "/$token"

            $ip = (Get-ItemProperty $regPath).ip
            Set-ItemProperty $regPath -Name "dsname" `
                -Value "admin@${ip}:80/${token}/:7447:1[/${token}]"
        }
    }

    # Start BI6
    Start-Service -Name "BlueIris"
}

Start-Sleep -Seconds 150
Write-Host "Token refresh complete." -ForegroundColor Green
```

**Config file format** (`token_config.json`):
```json
{
  "nvrs": [
    {
      "ip": "192.168.1.100",
      "apiKey": "YOUR_NVR1_API_KEY"
    },
    {
      "ip": "192.168.1.101",
      "apiKey": "YOUR_NVR2_API_KEY"
    }
  ]
}
```

### Multi-NVR Setups

When pulling cameras from multiple NVRs into one Blue Iris instance:

```
┌──────────┐         ┌──────────────────────────┐
│  NVR 1   │──RTSP──▶│                          │
│ 30 cams  │         │      Blue Iris 6          │
└──────────┘         │                          │
                      │   62 cameras total       │
┌──────────┐         │   Unified grid view       │
│  NVR 2   │──RTSP──▶│   Single recording DB     │
│ 32 cams  │         │   Combined alerting       │
└──────────┘         └──────────────────────────┘
```

**Key considerations:**
- Each NVR needs its own API key and token generation
- The `ip` field in the registry must point to the **correct NVR** for each camera
- Camera names must be unique across NVRs (Blue Iris uses name as the registry key)
- Total bandwidth = sum of all streams from all NVRs

**Common pitfall:** Wrong NVR IP + valid token = NO_SIGNAL. If a camera was moved between NVRs, make sure the `ip` field matches the NVR that actually hosts the camera.

### Blue Iris 6 JSON API Reference

BI6 exposes a JSON API for status monitoring and control:

```
Endpoint: http://127.0.0.1:{port}/json
Auth: MD5 hash of "username:{session}:password"
```

| Command | Description | Response |
|---|---|---|
| `{"cmd":"login"}` | Start session | Session token |
| `{"cmd":"login","session":"TOKEN","response":"MD5"}` | Authenticate | Login result |
| `{"cmd":"status","session":"TOKEN"}` | System status | CPU, memory, uptime |
| `{"cmd":"camlist","session":"TOKEN"}` | All cameras | Name, status, FPS, resolution |
| `{"cmd":"logout","session":"TOKEN"}` | End session | Logout confirmation |

### Registry Editing Rules

> **CRITICAL: Blue Iris 6 overwrites the registry while running.**

If BI6 is running, it periodically dumps its in-memory state back to the registry. Your changes will be overwritten within seconds.

**The correct procedure:**
```powershell
# 1. ALWAYS stop the service first
Stop-Service -Name "BlueIris" -Force
Start-Sleep -Seconds 5  # Let it fully stop

# 2. Make your registry changes
# ... (all the Set-ItemProperty calls)

# 3. Start the service back up
Start-Service -Name "BlueIris"
Start-Sleep -Seconds 150  # Wait for ALL cameras to connect
# Large camera counts need more time — ~2.5 sec per camera
```

**Backup before bulk changes:**
```powershell
# Export the entire BI6 registry tree
reg export "HKLM\SOFTWARE\Perspective Software\Blue Iris" "C:\BlueIris\backup_$(Get-Date -Format 'yyyyMMdd_HHmm').reg"
```

**Restore from backup:**
```powershell
Stop-Service -Name "BlueIris" -Force
reg import "C:\BlueIris\backup_20260216_1030.reg"
Start-Service -Name "BlueIris"
```

### Camera Name Mapping Challenges

If you're migrating from BI5 or had cameras set up previously, camera names in Blue Iris often don't match the names in UniFi Protect:

| Blue Iris Name | Protect Name | Why? |
|---|---|---|
| `frontdoor` | `Front Door` | BI uses shortnames, Protect uses display names |
| `court3.g5` | `Court 3` | Legacy naming from older camera model |
| `Indoor Pool Stairs v2` | `Indoor Pool Stairs` | Camera was replaced, BI kept old name |
| `Outdoor BBall West` | `Outdoor Snack Entry` | Camera was physically moved |

**Best practice:** Before any bulk operation, build a **complete name mapping table**:
1. Get all camera names from Protect API
2. Get all camera registry key names from BI6
3. Match by existing RTSP token when possible
4. Manually map the rest by context

### Monitoring Blue Iris Health

Set up external monitoring to catch issues before users notice:

**Option 1: HTTP health check** (works with Uptime Kuma, Nagios, etc.)
```
http://your-bi-server:81/json → {"cmd":"status"} → check "signal" count
```

**Option 2: PowerShell monitoring script**
```powershell
# Check camera health via BI6 API
# Returns count of online/offline cameras

$port = 81
$user = "admin"
$pass = "your_password"

$login = Invoke-RestMethod "http://127.0.0.1:${port}/json" `
    -Method POST -Body '{"cmd":"login"}' -ContentType "application/json"

$session = $login.session
$md5 = # ... (same MD5 auth as shown earlier)

$auth = Invoke-RestMethod "http://127.0.0.1:${port}/json" `
    -Method POST -Body "{`"cmd`":`"login`",`"session`":`"$session`",`"response`":`"$md5`"}" `
    -ContentType "application/json"

$camlist = Invoke-RestMethod "http://127.0.0.1:${port}/json" `
    -Method POST -Body "{`"cmd`":`"camlist`",`"session`":`"$session`"}" `
    -ContentType "application/json"

$online = ($camlist.data | Where-Object { $_.isOnline -eq $true }).Count
$offline = ($camlist.data | Where-Object { $_.isOnline -eq $false }).Count

Write-Host "Online: $online | Offline: $offline"

if ($offline -gt 0) {
    # Send alert via your preferred method
    # Telegram, email, webhook, etc.
}
```

---

## 🔥 Troubleshooting

### 🚨 Tight "Socket error / Socket closed / network retry" loop after refreshing tokens

**Symptom:** BI log shows a ~20-second cycle per affected camera:

```
1   HH:MM:SS.xxx   cam_name   Signal: network retry
1   HH:MM:SS.xxx   cam_name   Signal: Socket error
1   HH:MM:SS.xxx   cam_name   Signal: Socket closed
```

Camera was working fine before the token refresh / registry edit, now shows NO SIGNAL.

**What's happening:** Resolution field mismatch — the path fields point at one quality (e.g. LOW = 640×360) but `xres`/`yres` still reflect a different quality (e.g. HIGH = 2688×1512). BI's decoder can't fit the wrong-sized frames into its buffer. See the full explanation at **[Critical: Resolution Field Mismatch](#-critical-resolution-field-mismatch-the-silent-killer)**.

**Quick fix:** stop BI, update `xres`, `yres`, `mainxres`, `mainyres`, `fullxres`, `fullyres`, `zrect_right`, `zrect_bottom`, and `ip_aformat` to match the stream you pointed at, start BI. Camera will reconnect within ~30 seconds.

**Confirmation test:** if raw RTSP `DESCRIBE` (e.g. from a PowerShell TcpClient or VLC) against the same URL returns `200 OK` with valid SDP, then the problem is definitely on the BI-decoder side, not the NVR side.

### Camera Shows "NO SIGNAL"

This is the most common issue. Work through this checklist:

```
NO SIGNAL Troubleshooting Flowchart:

1. Is the NVR IP correct?
   └─ Check the `ip` field matches the NVR hosting this camera
   └─ Wrong IP + valid token = NO SIGNAL

2. Is the token still valid?
   └─ Generate a fresh token via the Integration API
   └─ Update ip_path, ip_subpath, ip_path2, and dsname

3. Are the ports correct?
   └─ ip_port MUST be 80 (not 7447!)
   └─ ip_port2 MUST be 7447
   └─ Common mistake: setting ip_port to 7447

4. Did you stop BI6 before editing the registry?
   └─ If not, BI6 probably overwrote your changes
   └─ Stop service → edit → start service

5. Is the camera connected in Protect?
   └─ Check Protect UI — camera must show "Connected"
   └─ Disconnected camera = no RTSP stream available

6. Can you reach the NVR from the BI6 machine?
   └─ Test: curl rtsp://NVR_IP:7447/token (or use VLC)
   └─ Firewall, VLAN, or routing issue?

7. Wait longer
   └─ Large camera counts take 2+ minutes to fully connect
   └─ ~2.5 seconds per camera on startup
```

### CPU at 100%

```
CPU Troubleshooting Priority:

1. Enable smartdecode=1 on ALL cameras     (biggest win)
2. Enable limit_live=1 globally            (grid view optimization)
3. Switch to LOW quality streams           (if not already)
4. Add Windows Defender exclusions         (stop scanning video files)
5. Kill unnecessary services               (ScreenConnect, TeamViewer)
6. Minimize BI6 window                     (reduces dwm.exe load)
7. Reduce FPS in Protect NVR profiles      (fewer frames to process)
```

### MEDIUM Quality Tokens Don't Work

**Don't use MEDIUM quality.** In our testing, ~40% of cameras fail with MEDIUM quality tokens from the Integration API. This appears to be a bug or limitation in certain camera models.

**Solution:** Always request `"qualities": ["high", "low"]` and use one or both. Never rely on MEDIUM.

### BI6 Crashes on Startup

Common causes:
- **Running in Session 0** (no desktop) — BI6 needs an interactive desktop session
- **Corrupted database** — delete the .db files and let BI6 recreate
- **Registry corruption** — restore from your backup .reg file
- **License issue** — verify your license key is entered correctly

### Cameras Show 0 FPS but "Online"

This usually means the RTSP connection is established but no video data is flowing:
- Token may be stale — regenerate
- Camera may be in a transitional state — wait 60 seconds
- NVR may be overloaded — check Protect dashboard for NVR CPU/disk

### Drives 100% Full, "Clip: Disk full" Spamming Every Camera

**Symptom:** Every camera in the log throws `Clip: Disk full` every few seconds. Drives are at 0 bytes free. BI service is running.

**Diagnose first** — three different bugs look identical from outside. See the full breakdown at **[Storage Rotation Silent-Failure Modes](#-critical-storage-rotation-silent-failure-modes)**.

Quick triage:

```powershell
# 1. Check storage cascade for dead-ends
foreach ($i in 0..15) {
    $p = "HKLM:\SOFTWARE\Perspective Software\Blue Iris\clips\folders\$i"
    if (Test-Path $p) {
        $f = Get-ItemProperty $p
        "[$i] $($f.name) path='$($f.path)' moveto=$($f.moveto)"
    }
}
# Any folder being cascaded into with empty path = Failure Mode 1.

# 2. Compare BI's logged quota to what you set
# In the log, look for: "Move: over quota X/Y GB"
# Compare Y to (your archmb / 1024) — if they don't match,
# you set the wrong field. archmb is real, limit is cosmetic.

# 3. Look for the smoking-gun DB warning
Select-String -Path 'C:\BlueIris\log\*.txt' -Pattern 'DB clips.*run a repair' -SimpleMatch | Select-Object -Last 5
# If present = Failure Mode 3. Run UI repair + wait for 02:00 auto-compact.
```

**Recovery sequence** (works for all three modes — each step is harmless if not needed):

```powershell
# 1. Stop BI cleanly
Stop-Service -Name 'BlueIris' -Force

# 2. Free 30%+ of each rotation drive — delete oldest .bvr files
#    (outside BI; we'll repair the DB after)
$target = 'D:\BlueIris\Stored'  # or wherever
$needFreeGB = 600
Get-ChildItem $target -Filter '*.bvr' -File | Sort-Object LastWriteTime |
    ForEach-Object {
        $drive = Get-PSDrive -Name $_.PSDrive
        if ($drive.Free / 1GB -lt $needFreeGB) { Remove-Item $_.FullName -Force }
    }

# 3. Fix the cascade dead-end if you have one
Set-ItemProperty 'HKLM:\SOFTWARE\Perspective Software\Blue Iris\clips\folders\1' `
    -Name moveto -Value 0 -Type DWord

# 4. Optionally lower archmb on each folder so quota leaves 15%+ headroom
# (Only do this if your existing archmb is too tight)
# Set-ItemProperty ... -Name archmb -Value <NEW_MB> -Type DWord

# 5. Start BI
Start-Service -Name 'BlueIris'

# 6. In BI UI: Settings → Cameras → Database tab → Repair / Regenerate
#    (or wait until 02:00 for the auto-compact)
```

---

## 📚 Reference Cards

### Quick Reference: Integration API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/proxy/protect/integration/v1/cameras` | GET | List all cameras |
| `/proxy/protect/integration/v1/cameras/{id}/rtsps-stream` | POST | Generate RTSP tokens |

**Headers required:** `X-API-Key: {your_api_key}`

**Token request body:** `{"qualities": ["high", "low"]}`

### Quick Reference: Key Registry Paths

```
Global:     HKLM:\SOFTWARE\Perspective Software\Blue Iris
Per-camera: HKLM:\SOFTWARE\Perspective Software\Blue Iris\Cameras\{CameraName}
```

### Quick Reference: Stream Quality Decision Tree

```
                    ┌─────────────────────┐
                    │  What do you need?   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                 ▼
        ┌──────────┐   ┌──────────────┐   ┌──────────┐
        │ Identify  │   │ Just detect  │   │ Both?    │
        │ faces/    │   │ motion and   │   │          │
        │ plates    │   │ presence     │   │          │
        └─────┬────┘   └──────┬───────┘   └────┬─────┘
              │                │                 │
              ▼                ▼                 ▼
         Use HIGH         Use LOW          Dual Stream:
         for main         for both         HIGH main +
                                           LOW sub
```

---

## 🙏 Acknowledgments

This guide was built on the back of:
- The [Blue Iris community at ipcamtalk.com](https://ipcamtalk.com/) — invaluable forum posts
- [Ubiquiti's Integration API documentation](https://help.ui.com/hc/en-us/articles/Protect-Integration-API)
- Many, many hours of trial and error
- A patient client who let us experiment on their 62-camera system
- AI-assisted research and documentation (Claude, Codex)

**Special shoutout** to whoever at Perspective Software decided to make the sub stream field `ip_subpath` instead of `ip_path2` and then didn't document it anywhere. You kept us up until 4 AM. Twice.

---

## 🔗 Further Reading & Resources

| Resource | Link |
|---|---|
| Blue Iris Official Site | [blueirissoftware.com](https://blueirissoftware.com/) |
| BI6 Changelog | [changelog6.pdf](https://blueirissoftware.com/changelog6.pdf) |
| IPCamTalk Forums (BI6 Thread) | [ipcamtalk.com](https://ipcamtalk.com/threads/version-6.83954/) |
| IPCamTalk Hardware Wiki | [Choosing Hardware for BI](https://ipcamtalk.com/wiki/choosing-hardware-for-blue-iris/) |
| IPCamTalk CPU Optimization | [Optimizing CPU Usage](https://ipcamtalk.com/wiki/optimizing-blue-iris-s-cpu-usage/) |
| IPCamTalk Sub-Stream Guide | [Sub-Stream Setup](https://ipcamtalk.com/wiki/sub-stream-guide/) |
| IPCamTalk Storage Calculator | [HDD Sizing](https://ipcamtalk.com/wiki/calculating-required-hard-drive-size/) |
| BiUpdateHelper (Backup Tool) | [GitHub](https://github.com/bp2008/biupdatehelper) |
| UniFi Official API Docs | [Getting Started](https://help.ui.com/hc/en-us/articles/30076656117655-Getting-Started-with-the-Official-UniFi-API) |
| UniFi Developer Portal | [Site Manager API](https://developer.ui.com/site-manager-api/gettingstarted) |
| Adding Ubiquiti Cameras to BI | [Chris Hammond's Guide](https://www.chrishammond.com/Blog/itemId/3077/Adding-Ubiquiti-Cameras-into-BlueIris-with-RTSP) |

---

## 📝 Version History

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-02-18 | Initial release — based on 62-camera migration |
| 1.1 | 2026-04-20 | **Critical bug documented.** Added the resolution-field-mismatch section (the silent-killer bug: updating RTSP tokens without also updating `xres`/`yres`/`mainxres`/`mainyres`/`zrect_*` leaves BI in a permanent Socket error retry loop). `scripts/Refresh-Tokens.ps1` now updates resolution fields and supports `-GetOnly` mode for current Protect firmware where `POST /rtsps-stream` returns HTTP 400. Registry Injection example in Part 3 now includes resolution fields. New Troubleshooting entry. Discovered during a real incident that bricked 4 of 62 cameras for hours. |
| 1.2 | 2026-05-03 | **Storage rotation silent-failure modes documented.** Added a new top-level "🚨 Critical: Storage Rotation Silent-Failure Modes" section covering the three independent ways rotation can break with the same external symptom (drives 100% full, "Disk full" log spam): (1) **broken cascade dead-end** — `moveto` pointing at an unconfigured Aux folder with empty `path` halts rotation silently; (2) **`archmb` is the real quota field, not `limit`** — `limit` is cosmetic in BI 6, only `archmb` (megabytes, 1024-based) is enforced; (3) **clip DB desync** signaled by `DB clips (X) > Disk usage (Y), run a repair` — phantom DB entries from prior crashes/cleanups make purge no-op until repaired. Added recovery sequence to Troubleshooting. Documented the `BlueIris` (no space) service-name gotcha. Discovered during a real recurrence that bypassed all the v1.1 hardening. |

---

## 📄 License

This guide is released under the [MIT License](LICENSE). Use it, share it, improve it.

If it saves you time, consider starring the repo. ⭐

---

<p align="center">
  <em>Written with ☕ and 🤬 at 3 AM by someone who really should have been sleeping.</em>
</p>

---

*Built by [KCCS](https://kccsonline.com) with [Claude Code](https://claude.ai/code)*
