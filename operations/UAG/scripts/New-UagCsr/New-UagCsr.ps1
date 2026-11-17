<#
.SYNOPSIS
    Generates a private key + CSR on an Omnissa Unified Access Gateway (UAG) over SSH
    and saves the CSR, key and openssl config locally.

.DESCRIPTION
    Uses the native Windows OpenSSH client (ssh.exe). No PowerCLI / Posh-SSH required.
    One SSH session = one password prompt. The remote script is sent base64-encoded
    to avoid CRLF/quoting issues. Everything is generated in a mktemp dir (umask 077)
    on the UAG and wiped afterwards.

    Prerequisites:
      - SSH enabled on the UAG and root login allowed
      - Windows OpenSSH client installed (Settings > Optional features > OpenSSH Client)

.EXAMPLE
    .\New-UagCsr.ps1 -UagFqdn uag01.lab.local -CommonName horizon.example.com `
                     -SubjectAltNames horizon.example.com,uag01.example.com

.EXAMPLE
    .\New-UagCsr.ps1    # prompts for everything, output in C:\UagCert\<cn>-<timestamp>

.LINK
    https://tech.iot-it.no/vmware/vmware-unified-access-gateway/vmware-unified-access-gateway-generate-csr/

.LINK
    https://github.com/bjosoren/omnissa/tree/main/operations/UAG/scripts/New-UagCsr

.NOTES
    Author  : bjosoren (https://github.com/bjosoren)
    Blog    : https://tech.iot-it.no
    License : MIT
#>
[CmdletBinding()]
param(
    [string]   $UagFqdn,
    [string]   $User = 'root',
    [int]      $Port = 22,
    [string]   $CommonName,
    [string[]] $SubjectAltNames,
    [ValidateSet(2048, 3072, 4096)]
    [int]      $KeySize = 2048,

    # Optional subject fields - leave empty to omit
    [string]   $Organization,
    [string]   $OrganizationalUnit,
    [string]   $Locality,
    [string]   $State,
    [ValidatePattern('^$|^[A-Za-z]{2}$')]
    [string]   $Country,

    [string]   $OutputFolder = 'C:\UagCert'
)

$ErrorActionPreference = 'Stop'

# ---------- Working folder ----------
if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    Write-Host "Created working folder $OutputFolder" -ForegroundColor DarkGray
}
Set-Location -LiteralPath $OutputFolder

# ---------- Prereqs ----------
if ($Host.Name -eq 'Windows PowerShell ISE Host') {
    throw "PowerShell ISE can't handle interactive prompts from ssh.exe (password input hangs). Run this script from a normal Windows PowerShell / pwsh console or Windows Terminal."
}
$sshExe = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $sshExe) {
    throw "ssh.exe not found. Install 'OpenSSH Client' (Settings > Apps > Optional features) or: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
}

# ---------- Input ----------
if (-not $UagFqdn)    { $UagFqdn    = Read-Host 'UAG FQDN/IP' }
$UagFqdn = $UagFqdn.Trim()

# ---------- SSH port check ----------
function Test-SshPort {
    param([string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs = 5000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return [pscustomobject]@{ Open = $false; Banner = $null; Error = "Timeout after $($TimeoutMs/1000)s (filtered/firewall?)" }
        }
        $client.EndConnect($iar)
        # SSH servers send their identification string first (e.g. "SSH-2.0-OpenSSH_9.x")
        $banner = $null
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $buf = New-Object byte[] 256
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { $banner = ([Text.Encoding]::ASCII.GetString($buf, 0, $n)).Trim() }
        } catch { }
        return [pscustomobject]@{ Open = $true; Banner = $banner; Error = $null }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        return [pscustomobject]@{ Open = $false; Banner = $null; Error = $msg }
    } finally {
        $client.Close()
    }
}

Write-Host "Checking TCP $Port on $UagFqdn..." -NoNewline
$portCheck = Test-SshPort -TargetHost $UagFqdn -TargetPort $Port
if (-not $portCheck.Open) {
    Write-Host ' FAILED' -ForegroundColor Red
    throw "Cannot reach ${UagFqdn}:$Port - $($portCheck.Error). Verify DNS, firewall, and that SSH is enabled on the UAG."
}
if ($portCheck.Banner -match '^SSH-') {
    Write-Host " OK ($($portCheck.Banner))" -ForegroundColor Green
} else {
    Write-Host ' OPEN' -ForegroundColor Yellow
    Write-Warning "Port $Port is open but no SSH banner was received. It may not be an SSH service."
    $cont = Read-Host 'Continue anyway? (y/N)'
    if ($cont -notmatch '^[Yy]') { Write-Host 'Aborted.'; return }
}

$inUser = Read-Host "SSH user [$User]"
if ($inUser) { $User = $inUser }
if (-not $CommonName) { $CommonName = Read-Host 'Certificate Common Name (CN)' }
if (-not $SubjectAltNames) {
    $sanInput = Read-Host 'Alternate DNS names (comma separated, CN is added automatically)'
    $SubjectAltNames = $sanInput -split '[,; ]+' | Where-Object { $_ }
}

$CommonName = $CommonName.Trim()
$fqdnRegex  = '^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

# CN first, then the rest, de-duplicated (case-insensitive)
$sanList = New-Object System.Collections.Generic.List[string]
foreach ($n in @($CommonName) + @($SubjectAltNames)) {
    $n = "$n".Trim().ToLower()
    if (-not $n) { continue }
    if ($n -notmatch $fqdnRegex) { throw "Invalid DNS name: '$n'" }
    if (-not $sanList.Contains($n)) { $sanList.Add($n) }
}

# ---------- Build openssl config ----------
$dn = @("CN = $CommonName")
if ($Organization)       { $dn += "O = $Organization" }
if ($OrganizationalUnit) { $dn += "OU = $OrganizationalUnit" }
if ($Locality)           { $dn += "L = $Locality" }
if ($State)              { $dn += "ST = $State" }
if ($Country)            { $dn += "C = $($Country.ToUpper())" }

$i = 0
$alt = $sanList | ForEach-Object { $i++; "DNS.$i = $_" }

$cnf = @"
[ req ]
default_bits       = $KeySize
default_md         = sha256
prompt             = no
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
$($dn -join "`n")

[ req_ext ]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
$($alt -join "`n")
"@ -replace "`r", ''

# ---------- Remote script (runs on UAG / Photon OS) ----------
$remote = @"
set -e
umask 077
WD=`$(mktemp -d /tmp/csr.XXXXXX)
trap 'rm -rf "`$WD"' EXIT
cat > "`$WD/req.cnf" <<'__CNF_EOF__'
$cnf
__CNF_EOF__
openssl req -new -newkey rsa:$KeySize -nodes -config "`$WD/req.cnf" -keyout "`$WD/key.pem" -out "`$WD/req.csr" 2>"`$WD/err.log" || { echo '===ERROR==='; cat "`$WD/err.log"; exit 1; }
echo '===CSR==='
cat "`$WD/req.csr"
echo '===KEY==='
cat "`$WD/key.pem"
echo '===TEXT==='
openssl req -in "`$WD/req.csr" -noout -verify -subject 2>&1
openssl req -in "`$WD/req.csr" -noout -text | grep -A1 -E 'Subject Alternative Name|Public-Key'
echo '===END==='
"@ -replace "`r", ''

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$remoteCmd = "echo $b64 | base64 -d | sh"

# ---------- Summary ----------
Write-Host ''
Write-Host "UAG      : $User@${UagFqdn}:$Port" -ForegroundColor Cyan
Write-Host "Subject  : $($dn -join ', ')"      -ForegroundColor Cyan
Write-Host "SANs     : $($sanList -join ', ')" -ForegroundColor Cyan
Write-Host "Key      : RSA $KeySize"           -ForegroundColor Cyan
Write-Host ''
$go = Read-Host 'Continue? (Y/n)'
if ($go -and $go -notmatch '^[Yy]') { Write-Host 'Aborted.'; return }

# ---------- Execute ----------
Write-Host "Connecting to $UagFqdn (enter the $User password when prompted)..." -ForegroundColor Yellow
# Don't capture ssh output with $x = & ssh ... : with stdout piped into PowerShell,
# the host-key question / password prompt can end up invisible and ssh just waits.
# Instead: stdout -> temp file, stdin/stderr stay on the console (prompts, banner, errors visible).
$sshOpts = @(
    '-T'
    '-p', $Port
    '-o', 'ConnectTimeout=15'
    '-o', 'StrictHostKeyChecking=accept-new'                       # no hidden yes/no prompt on first connect
    '-o', 'PreferredAuthentications=keyboard-interactive,password' # UAG uses keyboard-interactive (as seen in PuTTY)
    '-o', 'PubkeyAuthentication=no'
)
if ($VerbosePreference -eq 'Continue') { $sshOpts += '-v' }

$argLine = ($sshOpts -join ' ') + " $User@$UagFqdn `"$remoteCmd`""
$knownHostsEntry = if ($Port -eq 22) { $UagFqdn } else { "[$UagFqdn]:$Port" }

function Invoke-UagSsh {
    $tmpOut = Join-Path $OutputFolder ("ssh-out-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    try {
        $proc = Start-Process -FilePath $sshExe.Source -ArgumentList $argLine `
                              -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut
        $text = ''
        if (Test-Path -LiteralPath $tmpOut) {
            $text = ([IO.File]::ReadAllText($tmpOut)) -replace "`r", ''
        }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text }
    } finally {
        # temp file contains the private key - always remove it
        if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
    }
}

$result = Invoke-UagSsh

# Exit 255 with no output = ssh-level failure (host key, auth, network).
# Typical after a UAG redeploy/upgrade: new host keys -> "REMOTE HOST IDENTIFICATION HAS CHANGED".
if ($result.ExitCode -eq 255 -and -not $result.Output) {
    $existing = & ssh-keygen.exe -F $knownHostsEntry 2>$null
    if ($existing) {
        Write-Host ''
        Write-Warning "ssh failed. If the message above says 'REMOTE HOST IDENTIFICATION HAS CHANGED', the UAG presents a new host key (normal after redeploy/upgrade)."
        Write-Host    "Verify the new fingerprint first, e.g. on the UAG console:" -ForegroundColor Yellow
        Write-Host    "    ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub" -ForegroundColor Yellow
        Write-Host    "or compare with the fingerprint PuTTY shows (PuTTY keeps its own cache in the registry)." -ForegroundColor Yellow
        $fix = Read-Host "Fingerprint verified - remove old key for '$knownHostsEntry' from known_hosts and retry? (y/N)"
        if ($fix -match '^[Yy]') {
            & ssh-keygen.exe -R $knownHostsEntry | Out-Null
            Write-Host "Old host key removed (backup: known_hosts.old). Retrying..." -ForegroundColor Yellow
            $result = Invoke-UagSsh
        }
    }
}

$rc  = $result.ExitCode
$out = $result.Output

if ($out -match '===ERROR===') {
    throw "openssl failed on UAG:`n$(($out -split '===ERROR===')[1])"
}
if ($rc -ne 0 -or $out -notmatch '===CSR===') {
    throw "SSH/remote execution failed (exit $rc). Output:`n$out"
}

$csr  = [regex]::Match($out, '(?s)===CSR===\n(.*?)\n===KEY===').Groups[1].Value.Trim()
$key  = [regex]::Match($out, '(?s)===KEY===\n(.*?)\n===TEXT===').Groups[1].Value.Trim()
$info = [regex]::Match($out, '(?s)===TEXT===\n(.*?)\n===END===').Groups[1].Value.Trim()

if ($csr -notmatch 'BEGIN CERTIFICATE REQUEST' -or $key -notmatch 'BEGIN (RSA )?PRIVATE KEY') {
    throw "Could not parse CSR/key from output:`n$out"
}

# ---------- Save ----------
$stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$safeName = ($CommonName -replace '\*', 'wildcard') -replace '[^A-Za-z0-9.-]', '_'
$dir      = Join-Path $OutputFolder "$safeName-$stamp"
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$csrPath = Join-Path $dir "$safeName.csr"
$keyPath = Join-Path $dir "$safeName.key"
$cnfPath = Join-Path $dir "$safeName.cnf"
[IO.File]::WriteAllText($csrPath, ($csr -replace "`r", '') + "`n", $utf8NoBom)
[IO.File]::WriteAllText($keyPath, ($key -replace "`r", '') + "`n", $utf8NoBom)
[IO.File]::WriteAllText($cnfPath, $cnf + "`n", $utf8NoBom)

# Lock the private key down to the current user
try {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $me  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
    Set-Acl -Path $keyPath -AclObject $acl
} catch { Write-Warning "Could not restrict ACL on key file: $_" }

Write-Host ''
Write-Host '--- Verification (from UAG openssl) ---' -ForegroundColor Green
Write-Host $info
Write-Host ''
Write-Host "CSR : $csrPath" -ForegroundColor Green
Write-Host "Key : $keyPath  (private key - protect it!)" -ForegroundColor Green
Write-Host "Cnf : $cnfPath" -ForegroundColor Green
Write-Host ''
Write-Host $csr
try { Set-Clipboard -Value $csr; Write-Host "`n(CSR copied to clipboard)" -ForegroundColor DarkGray } catch {}
