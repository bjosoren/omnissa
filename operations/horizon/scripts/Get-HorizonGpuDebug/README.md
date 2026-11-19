# Get-HorizonGpuDebug.ps1

A PowerShell script that searches **Omnissa Horizon Connection Server** debug logs for vGPU and instant clone provisioning failures, such as:

```
Fault type is UNKNOWN_FAULT_FATAL - No GPU capable host is available for provisioning <vm> with profile nvidia_l40s-16a.
```

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![No dependencies](https://img.shields.io/badge/dependencies-none-green)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

Blog post: [Omnissa Horizon – "No GPU capable host is available" with NVIDIA L40S vGPU](https://tech.iot-it.no/?p=26330)

---

## What it does

- **`-TraceError` mode:** finds the first `No GPU capable host` error in the debug logs and prints the preceding lines from the **same thread**. That is usually where Horizon logs why it rejected each host, for example:
  ```
  [CPHost] {HIC} VGPU_PROFILE is null or unknown.
  ```
- **Search mode (default):** searches the debug logs for vGPU and provisioning keywords (`nvidia_`, `vgpu`, `VGPU_PROFILE`, `Resync`, `cp-template`, `InsufficientResources` and more) within a UTC time window
  - Prints a table and exports `horizon-gpu-debug.csv` with 2 lines of context before and after each hit
- **Local or remote:** runs on the current Connection Server, or against several Connection Servers through `Invoke-Command` (WinRM)
- **Both log paths:** checks `C:\ProgramData\Omnissa\Horizon\logs` and `C:\ProgramData\VMware\VDM\logs`

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Run on a Connection Server, or from a machine with **WinRM** access to the Connection Servers
- Local administrator rights on the Connection Servers (to read the log folder)

---

## Usage

### Trace back from the first error (start here)

Run it on the Connection Server listed in the **Source** column in Horizon Console → Events:

```powershell
.\Get-HorizonGpuDebug.ps1 -TraceError
```

Or against all Connection Servers remotely:

```powershell
.\Get-HorizonGpuDebug.ps1 -TraceError -ConnectionServers cs01.domain.local, cs02.domain.local
```

### Search a time window

Times are **UTC**, matching the timestamps in the debug logs:

```powershell
.\Get-HorizonGpuDebug.ps1 -From '2026-11-19T11:15' -To '2026-11-19T11:25'
```

### Custom search pattern

```powershell
.\Get-HorizonGpuDebug.ps1 -Pattern 'rdsh-16a|VGPU_PROFILE' -HoursBack 24
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ConnectionServers` | No | Connection Servers to query remotely. Omit to run locally |
| `-From` | No | Start of time window, UTC (`yyyy-MM-ddTHH:mm`). Default 1 hour ago |
| `-To` | No | End of time window, UTC. Default now |
| `-Pattern` | No | Regex used in search mode |
| `-HoursBack` | No | Only scan log files written in the last N hours. Default `6` |
| `-TraceError` | No | Trace back from the first `No GPU capable host` error |
| `-TraceLines` | No | Lines to look back in `-TraceError` mode. Default `500` |
| `-Local` | No | Force local execution even if `-ConnectionServers` is given |
| `-OutFile` | No | CSV output in search mode. Default `.\horizon-gpu-debug.csv` |

---

## Reading the result

| You see | Meaning |
|---------|---------|
| `[CPHost] VGPU_PROFILE is null or unknown` | The Connection Server doesn't know the vGPU profile. Add it to `graphic-profiles.properties` on every Connection Server (see the blog post) |
| No clone task in vCenter at the time of the error | Horizon rejected the placement internally |
| `InsufficientResources` / power-on errors in vCenter | A real placement problem: vGPU profile lock (Same Size mode), A/Q series mismatch, or no free vGPU slots. Check with `nvidia-smi vgpu` on the hosts |

---

## License

MIT - see [LICENSE](LICENSE)

## Author

bjosoren - [tech.iot-it.no](https://tech.iot-it.no)
