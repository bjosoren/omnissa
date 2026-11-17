# ConvertTo-UagCertificate.ps1

A PowerShell script that converts a CA-signed certificate into files **Omnissa Unified Access Gateway (UAG)** accepts: a **PEM certificate chain** or a **password-protected PFX**.

It is the follow-up to [New-UagCsr](../New-UagCsr/), which generates the private key and CSR on the UAG.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![No modules](https://img.shields.io/badge/modules-none-green)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

Blog post: [Omnissa Unified Access Gateway – Generate CSR with PowerShell](https://tech.iot-it.no/vmware/vmware-unified-access-gateway/vmware-unified-access-gateway-generate-csr/)

---

## What it does

1. **Lists** every `*.cer` in a folder you choose, including subfolders. For each one it shows the subject, the expiry date and whether a matching `.key` was found
2. **You select** which certificate to convert
3. **Builds the chain** (leaf → intermediate(s) → root) from:
   - the certificates in the file (DER, Base64/PEM or PKCS#7)
   - the Windows certificate store
   - AIA download
4. **Checks** that the certificate matches the private key
5. **You choose the output:**
   - **PEM:** `<name>-chain.pem`, with the leaf first, then the intermediates. Use it together with the existing `<name>.key`
   - **PFX:** `<name>.pfx`, containing the private key, leaf and intermediates. You set the password and alias

The private key is looked up next to the certificate: `<name>.key`, or the only `.key` in that folder. If neither exists, you're prompted for the path.

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- The private key as an unencrypted PEM file (`New-UagCsr.ps1` creates it this way)
- **For PFX output and the key-match check:**
  - **PowerShell 7:** built-in .NET, nothing extra needed
  - **Windows PowerShell 5.1:** `openssl.exe` in `PATH`
- To build a complete chain, the issuing CA certificates must be either:
  - trusted on the machine (an internal CA on a domain-joined PC), or
  - downloadable via AIA, or
  - included in the `.cer`/`.p7b`

---

## Usage

```powershell
.\ConvertTo-UagCertificate.ps1                          # prompts for the folder
.\ConvertTo-UagCertificate.ps1 -Folder C:\UagCert       # lists all *.cer under C:\UagCert
.\ConvertTo-UagCertificate.ps1 -Folder C:\UAG -IncludeRoot
```

Example menu:

```
#    File                                                    Subject                              Expires    Key
[1 ] tos-t6-uag01.ksat.ksat.no-20261117-0813\tos-t6-uag... tos-t6-uag01.ksat.ksat.no            2027-11-17 yes
[2 ] tos-t6-uag02.ksat.ksat.no-20261117-0740\tos-t6-uag... tos-t6-uag02.ksat.ksat.no            2027-11-17 yes

Select certificate [1-2] (Q = quit): 2
...
[1] PEM  - certificate chain file (use with the existing .key)
[2] PFX  - private key + chain, password protected
Output format [1-2] (Q = quit): 2
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Folder` | No | Folder to search for `*.cer`. Prompted if not given |
| `-NoRecurse` | No | Only list `*.cer` directly in `-Folder` |
| `-IncludeRoot` | No | Also include the root CA in the PEM chain or PFX |
| `-Legacy` | No | openssl only: create the PFX with legacy (3DES/SHA1) encryption, in case the target doesn't accept the OpenSSL 3 default (AES) |

---

## Upload in UAG

**Admin UI → TLS Server Certificate Settings** (for the Internet or Admin interface):

| Certificate Type | Field | File |
|------------------|-------|------|
| PEM | Private Key | `<name>.key` |
| PEM | Certificate Chain | `<name>-chain.pem` |
| PFX | Upload PFX | `<name>.pfx` |
| PFX | Password | the password you entered |
| PFX | Alias | the alias you entered (optional) |

When the openssl engine is used, the PFX password is passed to openssl through an environment variable, so it never appears on the command line.

---

## License

MIT - see [LICENSE](LICENSE)

## Author

bjosoren - [tech.iot-it.no](https://tech.iot-it.no)
