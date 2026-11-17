# New-UagCsr.ps1

A PowerShell script that connects to **Omnissa Unified Access Gateway (UAG)** over SSH and generates a private key and Certificate Signing Request (CSR) for TLS certificate renewal.

It uses the OpenSSH client built into Windows (`ssh.exe`). No PowerCLI, Posh-SSH or other modules required.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![No dependencies](https://img.shields.io/badge/dependencies-none-green)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

Blog post: [Omnissa Unified Access Gateway – Generate CSR with PowerShell](https://tech.iot-it.no/vmware/vmware-unified-access-gateway/vmware-unified-access-gateway-generate-csr/)

---

## What it does

- **Port check:** verifies that TCP 22 on the UAG is reachable and answers with an SSH banner
- **Generates key + CSR on the UAG** with `openssl`, in a temporary directory (umask 077) that is wiped afterwards
  - SHA-256, RSA 2048 / 3072 / 4096
  - `serverAuth` extended key usage
  - The CN is added to the SAN list automatically, duplicates removed, wildcards accepted
  - Optional O, OU, L, ST and C subject fields
- **One SSH session:** you type the password once. The remote commands are sent base64-encoded to avoid CRLF and quoting issues
- **Saves locally** to `C:\UagCert\<cn>-<timestamp>\`:
  - `<cn>.csr`
  - `<cn>.key` (ACL restricted to the current user)
  - `<cn>.cnf`
- **Verifies** the subject and SANs and copies the CSR to the clipboard
- **Changed host key:** if the UAG has been redeployed and its SSH host key changed, the script explains how to verify the fingerprint and asks before removing the old entry from `known_hosts`

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7, in a **regular console or Windows Terminal**
  - **Not PowerShell ISE.** ISE can't show ssh's password prompt, so the script refuses to run there
- **OpenSSH Client** for Windows. If it's missing, install it under Settings → Optional features, or run:
  ```powershell
  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
  ```
- **SSH enabled on the UAG**, plus an account that can log in over SSH (for example `root` or `admin`) and its password
- **TCP 22** open from your workstation to the UAG, and the UAG FQDN resolvable in DNS
- Rights to create `C:\UagCert`, or another folder passed with `-OutputFolder`
- A certificate authority to sign the CSR, either internal or public

---

## Usage

### Interactive (prompts for everything)

```powershell
.\New-UagCsr.ps1
```

### With parameters

```powershell
.\New-UagCsr.ps1 `
    -UagFqdn         uag01.lab.local `
    -User            admin `
    -CommonName      horizon.example.com `
    -SubjectAltNames uag01.example.com, remote.example.com `
    -KeySize         2048
```

### Troubleshooting

```powershell
.\New-UagCsr.ps1 -Verbose    # adds ssh -v output
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-UagFqdn` | No* | FQDN or IP of the UAG. Prompted if not given |
| `-User` | No | SSH user. Default `root`, and you're prompted to confirm |
| `-Port` | No | SSH port. Default `22` |
| `-CommonName` | No* | Certificate Common Name. Prompted if not given |
| `-SubjectAltNames` | No* | Alternate DNS names. The CN is added automatically. Prompted if not given |
| `-KeySize` | No | `2048` (default), `3072` or `4096` |
| `-Organization` | No | Subject O |
| `-OrganizationalUnit` | No | Subject OU |
| `-Locality` | No | Subject L |
| `-State` | No | Subject ST |
| `-Country` | No | Subject C (two letters) |
| `-OutputFolder` | No | Working folder. Default `C:\UagCert` |

\* Prompted interactively if not given.

---

## After the CA has signed the certificate

Use [ConvertTo-UagCertificate](../ConvertTo-UagCertificate/) to turn the signed `.cer` into a PEM chain or a password-protected PFX, then upload it in the UAG Admin UI under the TLS Server Certificate settings.

Afterwards, delete the local `.key` file or move it somewhere secure. It is saved **without a passphrase**.

---

## License

MIT - see [LICENSE](LICENSE)

## Author

bjosoren - [tech.iot-it.no](https://tech.iot-it.no)
