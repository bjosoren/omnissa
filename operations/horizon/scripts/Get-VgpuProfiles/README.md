# Get-VgpuProfiles.ps1

A PowerShell script that connects to **vCenter** and lists the NVIDIA vGPU profiles available on the ESXi hosts in a cluster (or on specific hosts), together with the physical GPUs and their graphics mode.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Requires PowerCLI](https://img.shields.io/badge/requires-PowerCLI-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

Blog post: [Omnissa Horizon – "No GPU capable host is available" with NVIDIA L40S vGPU](https://tech.iot-it.no/?p=26330)

---

## What it does

Per host it reads, through the vSphere API:

| Property | Used for |
|----------|----------|
| `Config.GraphicsInfo` | Physical GPUs: model, memory, current mode |
| `Config.GraphicsConfig` | Host default graphics type (vGPU needs **Shared Direct**) |
| `Config.SharedPassthruGpuTypes` | vGPU profiles the host offers, e.g. `grid_a40-8q`, `nvidia_l40s-16a` |

Output:

1. **Physical NVIDIA GPUs** per host: model, memory, PCI ID, mode, and VMs associated with the GPU
2. **Available vGPU profiles**, decoded: GPU, framebuffer, series (Q / B / A / C), MIG slices, max per GPU, and which hosts offer the profile
3. Optional **CSV export**, one row per host and profile

Both the older `grid_…` and the newer `nvidia_…` profile names are recognised.

### Warnings

- A host's default graphics type isn't **Shared Direct**
- A host has an NVIDIA GPU but reports no vGPU profiles (usually a missing NVIDIA host driver VIB, or no reboot after switching to Shared Direct)
- A profile isn't offered on every host, so VMs using it can't move freely between all hosts
- A host is disconnected and was skipped

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- **PowerCLI** (`Install-Module VCF.PowerCLI -Scope CurrentUser`, older name `VMware.PowerCLI`)
- A vCenter account with read access to the hosts

---

## Usage

```powershell
.\Get-VgpuProfiles.ps1 -VCenter vc01.lab.local -User administrator@vsphere.local -Cluster GPU-Cluster
```

Specific hosts, untrusted vCenter certificate, CSV export:

```powershell
.\Get-VgpuProfiles.ps1 -VCenter vc01.lab.local -User administrator@vsphere.local `
    -VMHost esx01.lab.local, esx02.lab.local -SkipCertificateCheck -ExportCsv C:\Temp\vgpu.csv
```

The password is asked for in the console at runtime and is never stored.

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-VCenter` | Yes | vCenter FQDN |
| `-User` | Yes | vCenter user, e.g. `administrator@vsphere.local` |
| `-Cluster` | No* | Cluster name. All hosts in the cluster are checked |
| `-VMHost` | No* | One or more ESXi host names. Combined with `-Cluster`, only these hosts in that cluster are checked |
| `-SkipCertificateCheck` | No | Ignore an untrusted vCenter certificate for this session only |
| `-ExportCsv` | No | Write the decoded profile list to CSV |

\* At least one of `-Cluster` or `-VMHost` is required.

---

## Notes on interpreting the output

- **The profile list is static.** It shows what the hosts *can* run on an empty GPU, not what each GPU accepts right now. In *Same Size* mode a GPU is locked to the profile of the first running vGPU VM. Use `nvidia-smi vgpu` on the host to see what is actually running.
- **Max/GPU is an estimate**: reported GPU memory divided by the profile's framebuffer. With ECC enabled the reported memory is lower than the card's nominal size, so the largest profile may show `0` and other values can be lower than NVIDIA's official maximums. NVIDIA's vGPU user guide is the reference.
- **VMs** is the number of VMs in the host's `GraphicsInfo.Vm` list for that GPU. It doesn't necessarily mean running vGPU VMs, and it can differ from the "VMs associated with the graphics device" list in the vSphere Client. Confirm with `nvidia-smi vgpu`.
- A profile listed here can still be rejected by Horizon if the Connection Server doesn't know it. See [Get-HorizonGpuDebug](../Get-HorizonGpuDebug/) and the blog post.

---

## License

MIT - see [LICENSE](LICENSE)

## Author

bjosoren - [tech.iot-it.no](https://tech.iot-it.no)
