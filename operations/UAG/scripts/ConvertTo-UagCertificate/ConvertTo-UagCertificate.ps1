<#
.SYNOPSIS
    Converts a CA-signed certificate into files UAG accepts: a PEM chain, or a PFX
    with a password. You pick the certificate from a menu.

.DESCRIPTION
    1. Asks for (or takes) a folder and lists every *.cer in it, including subfolders
    2. You choose which certificate to convert
    3. You choose the output:
         PEM : <name>-chain.pem  (leaf first, then intermediates). Use it with the existing <name>.key
         PFX : <name>.pfx        (private key + leaf + intermediates), password protected
    The chain is built from the certs in the file, the Windows certificate store and AIA download.
    The private key is looked up next to the certificate (<name>.key, or the only .key in that folder).

    PFX/key-match engine:
      - PowerShell 7+ : built-in .NET
      - Windows PowerShell 5.1 : openssl.exe (must be in PATH)

    UAG Admin UI > TLS Server Certificate Settings:
      PEM : Private Key = <name>.key, Certificate Chain = <name>-chain.pem
      PFX : Upload PFX = <name>.pfx, Password = the PFX password

.EXAMPLE
    .\ConvertTo-UagCertificate.ps1
.EXAMPLE
    .\ConvertTo-UagCertificate.ps1 -Folder C:\UagCert
.EXAMPLE
    .\ConvertTo-UagCertificate.ps1 -Folder C:\UAG -IncludeRoot
.LINK
    https://tech.iot-it.no/vmware/vmware-unified-access-gateway/vmware-unified-access-gateway-generate-csr/

.LINK
    https://github.com/bjosoren/omnissa/tree/main/operations/UAG/scripts/ConvertTo-UagCertificate

.NOTES
    Author  : bjosoren (https://github.com/bjosoren)
    Blog    : https://tech.iot-it.no
    License : MIT
#>
[CmdletBinding()]
param(
    [string] $Folder,
    [switch] $IncludeRoot,   # also include the root CA in the PEM chain / PFX
    [switch] $NoRecurse,     # only list *.cer directly in -Folder
    [switch] $Legacy         # openssl only: create the PFX with legacy (3DES/SHA1) encryption
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$X509    = 'System.Security.Cryptography.X509Certificates'
$isPs7   = $PSVersionTable.PSVersion.Major -ge 7
$openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue

# ================= Helpers =================
function Read-CertificateFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text  = [Text.Encoding]::ASCII.GetString($bytes)
    $coll  = New-Object "$X509.X509Certificate2Collection"
    if ($text -match '-----BEGIN CERTIFICATE-----') {
        foreach ($m in [regex]::Matches($text, '(?s)-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----')) {
            $der = [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
            [void]$coll.Add((New-Object "$X509.X509Certificate2" (, $der)))
        }
    } elseif ($text -match '(?s)-----BEGIN PKCS7-----(.+?)-----END PKCS7-----') {
        $coll.Import([Convert]::FromBase64String(($Matches[1] -replace '\s', '')))
    } else {
        $coll.Import($bytes)   # DER certificate or DER PKCS#7
    }
    return , $coll
}

function Get-LeafCertificate($Collection) {
    $leaf = $Collection | Where-Object {
        $bc = $_.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }
        -not $bc -or -not ([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$bc).CertificateAuthority
    } | Select-Object -First 1
    if (-not $leaf) { $leaf = $Collection[0] }
    return $leaf
}

function Find-PrivateKey([string]$CertPath) {
    $dir  = Split-Path -Parent $CertPath
    $base = [IO.Path]::GetFileNameWithoutExtension($CertPath)
    $same = Join-Path $dir "$base.key"
    if (Test-Path -LiteralPath $same) { return $same }
    $keys = @(Get-ChildItem -LiteralPath $dir -Filter *.key -File)
    if ($keys.Count -eq 1) { return $keys[0].FullName }
    return $null
}

function ConvertTo-Pem([byte[]]$Der) {
    $b64 = [Convert]::ToBase64String($Der)
    $lines = for ($p = 0; $p -lt $b64.Length; $p += 64) { $b64.Substring($p, [Math]::Min(64, $b64.Length - $p)) }
    "-----BEGIN CERTIFICATE-----`n" + ($lines -join "`n") + "`n-----END CERTIFICATE-----`n"
}

function Read-Choice([string]$Prompt, [int]$Min, [int]$Max) {
    while ($true) {
        $in = Read-Host $Prompt
        if ($in -match '^[Qq]$') { return $null }
        $n = 0
        if ([int]::TryParse($in, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host "  Enter a number between $Min and $Max (or Q to quit)." -ForegroundColor Yellow
    }
}

function Read-PfxPassword {
    while ($true) {
        $s1 = Read-Host 'PFX password' -AsSecureString
        $s2 = Read-Host 'Confirm PFX password' -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2)
        try {
            $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        if (-not $p1)       { Write-Host '  Password cannot be empty.' -ForegroundColor Yellow; continue }
        if ($p1 -ne $p2)    { Write-Host '  Passwords do not match.'   -ForegroundColor Yellow; continue }
        return $p1
    }
}

# ================= 1. Folder =================
if (-not $Folder) { $Folder = Read-Host 'Folder with certificates' }
$Folder = $Folder.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Folder not found: $Folder" }
$Folder = (Resolve-Path -LiteralPath $Folder).Path

# ================= 2. Enumerate *.cer =================
$gciArgs = @{ LiteralPath = $Folder; Filter = '*.cer'; File = $true }
if (-not $NoRecurse) { $gciArgs.Recurse = $true }
$files = @(Get-ChildItem @gciArgs | Sort-Object FullName)
if ($files.Count -eq 0) { throw "No *.cer files found in $Folder" }

$list = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $item = [pscustomobject]@{ File = $f; Leaf = $null; Key = (Find-PrivateKey $f.FullName); Error = $null }
    try   { $item.Leaf = Get-LeafCertificate (Read-CertificateFile $f.FullName) }
    catch { $item.Error = $_.Exception.Message }
    $list.Add($item)
}

Write-Host ''
Write-Host "Certificates in $Folder" -ForegroundColor Cyan
Write-Host ('{0,-4} {1,-55} {2,-36} {3,-10} {4}' -f '#', 'File', 'Subject', 'Expires', 'Key') -ForegroundColor DarkGray
for ($i = 0; $i -lt $list.Count; $i++) {
    $it  = $list[$i]
    $rel = $it.File.FullName.Substring($Folder.Length).TrimStart('\')
    if ($rel.Length -gt 55) { $rel = '...' + $rel.Substring($rel.Length - 52) }
    if ($it.Error) {
        Write-Host ('[{0,-2}] {1,-55} {2}' -f ($i + 1), $rel, '(unreadable)') -ForegroundColor Red
        continue
    }
    $subj = ($it.Leaf.Subject -replace '^CN=', '')
    if ($subj.Length -gt 36) { $subj = $subj.Substring(0, 33) + '...' }
    $exp   = $it.Leaf.NotAfter.ToString('yyyy-MM-dd')
    $key   = if ($it.Key) { 'yes' } else { 'no' }
    $color = if ($it.Leaf.NotAfter -lt (Get-Date)) { 'DarkYellow' } else { 'Gray' }
    Write-Host ('[{0,-2}] {1,-55} {2,-36} {3,-10} {4}' -f ($i + 1), $rel, $subj, $exp, $key) -ForegroundColor $color
}
Write-Host ''

# ================= 3. Select certificate =================
$sel = Read-Choice "Select certificate [1-$($list.Count)] (Q = quit)" 1 $list.Count
if (-not $sel) { Write-Host 'Aborted.'; return }
$chosen = $list[$sel - 1]
if ($chosen.Error) { throw "Cannot read $($chosen.File.FullName): $($chosen.Error)" }

$CertFile = $chosen.File.FullName
$certDir  = $chosen.File.DirectoryName
$baseName = $chosen.File.BaseName
$KeyFile  = $chosen.Key
if (-not $KeyFile) {
    $in = Read-Host "No matching .key found next to the certificate. Path to private key (Enter = none)"
    if ($in) {
        $in = $in.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $in)) { throw "Key file not found: $in" }
        $KeyFile = (Resolve-Path -LiteralPath $in).Path
    }
}

# ================= Build chain =================
$certs = Read-CertificateFile $CertFile
$leaf  = Get-LeafCertificate $certs

$chain = New-Object "$X509.X509Chain"
$chain.ChainPolicy.RevocationMode = 'NoCheck'
$chain.ChainPolicy.ExtraStore.AddRange($certs)
$built    = $chain.Build($leaf)
$elements = @($chain.ChainElements | ForEach-Object { $_.Certificate })
$root     = $elements | Where-Object { $_.Subject -eq $_.Issuer } | Select-Object -Last 1
$output   = @($elements | Where-Object { $IncludeRoot -or $_.Subject -ne $_.Issuer })

Write-Host ''
Write-Host "Certificate : $CertFile" -ForegroundColor Cyan
Write-Host "Private key : $(if ($KeyFile) { $KeyFile } else { '(none)' })" -ForegroundColor Cyan
Write-Host '--- Chain ---' -ForegroundColor Green
for ($i = 0; $i -lt $elements.Count; $i++) {
    $c    = $elements[$i]
    $role = if ($i -eq 0) { 'Leaf' } elseif ($c.Subject -eq $c.Issuer) { 'Root' } else { 'Intermediate' }
    $inc  = if ($output -contains $c) { '' } else { ' (not included)' }
    Write-Host ("[{0}] {1,-12} {2}  (expires {3:yyyy-MM-dd}){4}" -f $i, $role, $c.Subject, $c.NotAfter, $inc)
}
$san = $leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
if ($san) { Write-Host "SANs: $($san.Format($false))" -ForegroundColor DarkGray }
if (-not $root) {
    Write-Warning "The chain is incomplete: no root CA found, so intermediates may be missing. Import the CA certificates on this machine, or use a .p7b/.cer that contains the full chain."
} elseif (-not $built) {
    $status = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() } | Where-Object { $_ }) -join '; '
    if ($status) { Write-Warning "Chain status: $status" }
}

# Leaf + chain as PEM text (used by both outputs)
$chainPem = ($output | ForEach-Object { ConvertTo-Pem $_.RawData }) -join ''
$utf8     = New-Object System.Text.UTF8Encoding($false)

# ================= Key match =================
if ($KeyFile) {
    $match = $null
    if ($isPs7) {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.ImportFromPem((Get-Content -LiteralPath $KeyFile -Raw))
        $match = [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus) -eq
                 [Convert]::ToBase64String($leaf.GetRSAPublicKey().ExportParameters($false).Modulus)
    } elseif ($openssl) {
        $tmpLeaf = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmpLeaf, (ConvertTo-Pem $leaf.RawData), $utf8)
            $mCert = & $openssl.Source x509 -noout -modulus -in $tmpLeaf 2>$null
            $mKey  = & $openssl.Source rsa  -noout -modulus -in $KeyFile 2>$null
            $match = $mCert -and ($mCert -eq $mKey)
        } finally { Remove-Item -LiteralPath $tmpLeaf -Force -ErrorAction SilentlyContinue }
    }
    if ($match -eq $false) { throw "The private key $KeyFile does NOT match the certificate. Wrong key/CSR?" }
    if ($match -eq $true)  { Write-Host 'Key match   : OK (certificate matches private key)' -ForegroundColor Green }
    else                   { Write-Host 'Key match   : skipped (needs PowerShell 7 or openssl)' -ForegroundColor DarkGray }
}

# ================= 4. Output format =================
Write-Host ''
Write-Host '[1] PEM  - certificate chain file (use with the existing .key)'
Write-Host '[2] PFX  - private key + chain, password protected'
$fmt = Read-Choice 'Output format [1-2] (Q = quit)' 1 2
if (-not $fmt) { Write-Host 'Aborted.'; return }

if ($fmt -eq 1) {
    # ---------- PEM ----------
    $chainPath = Join-Path $certDir "$baseName-chain.pem"
    [IO.File]::WriteAllText($chainPath, $chainPem, $utf8)
    Write-Host ''
    Write-Host "Chain PEM   : $chainPath" -ForegroundColor Green
    Write-Host ''
    Write-Host 'UAG Admin UI > TLS Server Certificate Settings (PEM):' -ForegroundColor Yellow
    Write-Host "  Private Key       = $(if ($KeyFile) { Split-Path -Leaf $KeyFile } else { '<your private key>' })" -ForegroundColor Yellow
    Write-Host "  Certificate Chain = $(Split-Path -Leaf $chainPath)" -ForegroundColor Yellow
    return
}

# ---------- PFX ----------
if (-not $KeyFile) { throw 'A PFX needs the private key. No key file was found or given.' }
if (-not $isPs7 -and -not $openssl) {
    throw 'Creating a PFX needs PowerShell 7 (pwsh) or openssl.exe in PATH. Run the script in pwsh, or choose PEM.'
}

$alias = Read-Host "Alias / friendly name [$baseName]"
if (-not $alias) { $alias = $baseName }
$pfxPath = Join-Path $certDir "$baseName.pfx"
if (Test-Path -LiteralPath $pfxPath) {
    $ow = Read-Host "$pfxPath exists. Overwrite? (y/N)"
    if ($ow -notmatch '^[Yy]') { Write-Host 'Aborted.'; return }
}
$pfxPass = Read-PfxPassword

try {
    if ($isPs7 -and -not $Legacy) {
        $leafWithKey = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
                           (ConvertTo-Pem $leaf.RawData), (Get-Content -LiteralPath $KeyFile -Raw))
        if ($IsWindows) { $leafWithKey.FriendlyName = $alias }
        $coll = New-Object "$X509.X509Certificate2Collection"
        [void]$coll.Add($leafWithKey)
        $output | Select-Object -Skip 1 | ForEach-Object { [void]$coll.Add($_) }
        [IO.File]::WriteAllBytes($pfxPath, $coll.Export('Pkcs12', $pfxPass))
        $engine = '.NET'
    } else {
        if (-not $openssl) { throw '-Legacy needs openssl.exe in PATH.' }
        $tmpChain = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmpChain, $chainPem, $utf8)
            $env:UAG_PFX_PASS = $pfxPass           # passed via env var, not visible on the command line
            $osArgs = @('pkcs12', '-export', '-inkey', $KeyFile, '-in', $tmpChain,
                        '-name', $alias, '-out', $pfxPath, '-passout', 'env:UAG_PFX_PASS')
            if ($Legacy) { $osArgs += '-legacy' }
            $osOut = & $openssl.Source @osArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "openssl failed: $($osOut -join ' ')" }
        } finally {
            Remove-Item Env:\UAG_PFX_PASS -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmpChain -Force -ErrorAction SilentlyContinue
        }
        $engine = 'openssl' + $(if ($Legacy) { ' (legacy)' } else { '' })
    }
} finally {
    $pfxPass = $null
}

Write-Host ''
Write-Host "PFX         : $pfxPath  (created with $engine)" -ForegroundColor Green
Write-Host ''
Write-Host 'UAG Admin UI > TLS Server Certificate Settings (PFX):' -ForegroundColor Yellow
Write-Host "  Upload PFX = $(Split-Path -Leaf $pfxPath)" -ForegroundColor Yellow
Write-Host '  Password   = the password you just entered' -ForegroundColor Yellow
Write-Host "  Alias      = $alias (optional)" -ForegroundColor Yellow
