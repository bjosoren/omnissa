#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AsBuilt Report - Offline Setup Script
    Last-updated: 2026-06-24

.DESCRIPTION
    Six-phase script for As Built Report in air-gapped environments.

    PHASE 1 (Download)          : Run on a machine with internet access.
                                  Downloads PowerCLI, PScribo and AsBuiltReport modules
                                  to a local staging folder.

    PHASE 2 (Install)           : Run on the air-gapped machine.
                                  Copies modules to PSModulePath and imports everything.

    PHASE 3 (DownloadPython)    : Downloads Python installer and pip packages to staging folder.

    PHASE 4 (InstallPython)     : Installs Python and packages from staging folder (offline).

    PHASE 5 (DownloadGraphviz)  : Downloads Graphviz Windows installer to staging folder.
                                  Required for Diagrammer.Core / AsBuiltReport.VMware.Horizon diagrams.

    PHASE 6 (InstallGraphviz)   : Installs Graphviz from staging folder (offline) and adds it to PATH.

.PARAMETER Mode
    Download          - Download PS modules to $StagingDir (requires internet)
    Install           - Install and import modules from $StagingDir (offline)
    DownloadPython    - Download Python installer and pip wheels (requires internet)
    InstallPython     - Install Python and pip packages from staging folder (offline)
    DownloadGraphviz  - Download Graphviz installer to staging folder (requires internet)
    InstallGraphviz   - Install Graphviz from staging folder and update PATH (offline)

.PARAMETER StagingDir
    Root folder for download and staging. Can be local path or UNC path.
    Default: C:\AsBuildOffline

.PARAMETER ReportOutputDir
    Folder where completed reports are stored. Default: $StagingDir\AsBuiltReports

.PARAMETER JsonConfigDir
    Folder where JSON configuration files are stored. Default: $StagingDir\Config

.EXAMPLE
    # Phase 1 - download PS modules on internet machine
    .\AsBuilt-Offline.ps1 -Mode Download

    # Phase 2 - install on air-gapped machine
    .\AsBuilt-Offline.ps1 -Mode Install

    # Phase 5 - download Graphviz on internet machine
    .\AsBuilt-Offline.ps1 -Mode DownloadGraphviz

    # Phase 6 - install Graphviz on air-gapped machine
    .\AsBuilt-Offline.ps1 -Mode InstallGraphviz

.NOTES
    - Copy the entire $StagingDir folder to the air-gapped machine before Install phases.
    - PowerCLI is locked to v13.3 for compatibility with Horizon/vCenter.
    - Use Get-Credential when running New-AsBuiltReport to avoid plaintext passwords.
    - On PS7, Save-PSResource is used with -SkipDependencyCheck to avoid corrupt .nupkg errors.
      All required modules are listed explicitly in $ModuleDefinitions so no dependencies are missed.
    - Graphviz is required for diagram features in AsBuiltReport.VMware.Horizon (via Diagrammer.Core/PSGraph).
      Reports still generate without it, but topology diagrams will be absent.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Download', 'Install', 'DownloadPython', 'InstallPython', 'DownloadGraphviz', 'InstallGraphviz')]
    [string]$Mode,

    [string]$StagingDir    = 'C:\AsBuildOffline',
    [string]$ReportOutputDir,
    [string]$JsonConfigDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Derived paths -----------------------------------------------------------
if (-not $ReportOutputDir) { $ReportOutputDir = Join-Path $StagingDir 'AsBuiltReports' }
if (-not $JsonConfigDir)   { $JsonConfigDir   = Join-Path $StagingDir 'Config' }

$ModuleStaging      = Join-Path $StagingDir 'PSModules'
$NuGetDir           = Join-Path $StagingDir 'NuGet'
$PythonStaging      = Join-Path $StagingDir 'Python'
$PythonVersion      = '3.13.14'
$PythonInstaller    = "python-$PythonVersion-amd64.exe"
$PythonUrl          = "https://www.python.org/ftp/python/$PythonVersion/$PythonInstaller"
$GraphvizStaging    = Join-Path $StagingDir 'Graphviz'
$GraphvizVersion    = '15.0.0'
$GraphvizInstaller  = "windows_10_cmake_Release_graphviz-install-$GraphvizVersion-win64.exe"
$GraphvizUrl        = "https://gitlab.com/api/v4/projects/4207231/packages/generic/graphviz-releases/$GraphvizVersion/$GraphvizInstaller"
$GraphvizInstallDir = 'C:\Program Files\Graphviz'

# Minimal base packages - add more as needed
$PythonPackages = @(
    'requests'
    'jinja2'
    'pyyaml'
)

# --- Module definitions ------------------------------------------------------
# All modules listed explicitly. On PS7 we use -SkipDependencyCheck, so every
# dependency must appear here as its own entry.
$ModuleDefinitions = @(
    @{ Name = 'VMware.PowerCLI';                 MaxVersion = '13.3'; SubDir = 'PowerCLI' }
    @{ Name = 'PScribo';                         MaxVersion = $null;  SubDir = 'PScribo'  }
    @{ Name = 'PSGraph';                         MaxVersion = $null;  SubDir = 'AsBuilt'  }
    @{ Name = 'Diagrammer.Core';                 MaxVersion = $null;  SubDir = 'AsBuilt'  }
    @{ Name = 'AsBuiltReport.Core';              MaxVersion = $null;  SubDir = 'AsBuilt'  }
    @{ Name = 'AsBuiltReport.VMware.Horizon';    MaxVersion = $null;  SubDir = 'AsBuilt'  }
    @{ Name = 'AsBuiltReport.VMware.AppVolumes'; MaxVersion = $null;  SubDir = 'AsBuilt'  }
    @{ Name = 'AsBuiltReport.VMware.UAG';        MaxVersion = $null;  SubDir = 'AsBuilt'  }
    @{ Name = 'AsBuiltReport.VMware.vSphere';    MaxVersion = $null;  SubDir = 'AsBuilt'  }
)

# AsBuiltReport JSON config mapping
$ReportConfigs = @(
    @{ Report = 'VMware.Horizon';    Filename = 'AsBuiltHorizon'    }
    @{ Report = 'VMware.AppVolumes'; Filename = 'AsBuiltAppVolumes' }
    @{ Report = 'VMware.UAG';        Filename = 'AsBuiltUAG'        }
    @{ Report = 'VMware.vSphere';    Filename = 'AsBuiltvSphere'    }
)

# --- Helper functions --------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host "`n[*] $Message" -ForegroundColor Cyan
}
function Write-OK {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}
function Write-Warn {
    param([string]$Message)
    Write-Host "    [!]  $Message" -ForegroundColor Yellow
}
function Write-Fail {
    param([string]$Message)
    Write-Host "    [X] $Message" -ForegroundColor Red
}
function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-OK "Created folder: $Path"
    }
}

# =============================================================================
# PHASE 1 - DOWNLOAD
# =============================================================================
function Invoke-Download {
    Write-Host "`n+==============================================+" -ForegroundColor Magenta
    Write-Host "|  AsBuilt Offline - PHASE 1: DOWNLOAD         |" -ForegroundColor Magenta
    Write-Host "+==============================================+`n" -ForegroundColor Magenta

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($dir in @($StagingDir, $ModuleStaging, $NuGetDir, $ReportOutputDir, $JsonConfigDir)) {
        Ensure-Dir $dir
    }

    Write-Step "Checking package provider..."
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        if (-not (Get-Module -Name Microsoft.PowerShell.PSResourceGet -ListAvailable)) {
            Write-Warn "Microsoft.PowerShell.PSResourceGet not found - installing..."
            Install-Module -Name Microsoft.PowerShell.PSResourceGet -Force -AllowClobber
        }
        Write-OK "PS7 detected - will use Save-PSResource with -SkipDependencyCheck"
    } else {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Write-OK "NuGet provider installed (PS5.1)"
    }

    foreach ($mod in $ModuleDefinitions) {
        Write-Step "Downloading: $($mod.Name)$(if ($mod.MaxVersion) { " (max v$($mod.MaxVersion))" })"
        $destPath = Join-Path $ModuleStaging $mod.SubDir
        Ensure-Dir $destPath

        try {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                # PS7: use Save-PSResource with -SkipDependencyCheck to avoid corrupt .nupkg errors.
                # All dependencies are listed explicitly in $ModuleDefinitions above.
                $psrParams = @{
                    Name                 = $mod.Name
                    Repository           = 'PSGallery'
                    Path                 = $destPath
                    TrustRepository      = $true
                    SkipDependencyCheck  = $true
                }
                if ($mod.MaxVersion) { $psrParams['Version'] = "[0.0,$($mod.MaxVersion)]" }
                Save-PSResource @psrParams
            } else {
                $saveParams = @{ Name = $mod.Name; Repository = 'PSGallery'; Path = $destPath }
                if ($mod.MaxVersion) { $saveParams['MaximumVersion'] = $mod.MaxVersion }
                Save-Module @saveParams
            }
            Write-OK "$($mod.Name) saved to $destPath"
        }
        catch {
            Write-Warn "ERROR downloading $($mod.Name): $_"
        }
    }

    Write-Host "`n+==================================================================+" -ForegroundColor Green
    Write-Host "|  DOWNLOAD COMPLETE                                                |" -ForegroundColor Green
    Write-Host "|  Copy the entire folder to the air-gapped machine:               |" -ForegroundColor Green
    Write-Host "|  $($StagingDir.PadRight(60))|" -ForegroundColor Green
    Write-Host "|  Then run:  .\AsBuilt-Offline.ps1 -Mode Install                  |" -ForegroundColor Green
    Write-Host "+==================================================================+`n" -ForegroundColor Green
}

# =============================================================================
# PHASE 2 - INSTALL
# =============================================================================
function Invoke-Install {
    Write-Host "`n+==============================================+" -ForegroundColor Magenta
    Write-Host "|  AsBuilt Offline - PHASE 2: INSTALL          |" -ForegroundColor Magenta
    Write-Host "+==============================================+`n" -ForegroundColor Magenta

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-OK "ExecutionPolicy set to RemoteSigned (CurrentUser)"
    }
    catch { Write-Warn "Could not set ExecutionPolicy: $_ - continuing anyway" }

    # Determine correct PS module path
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $SystemModulePath = ($env:PSModulePath -split ';') |
            Where-Object { $_ -like '*PowerShell\7*' -or $_ -like '*powershell\7*' } |
            Select-Object -First 1
        if (-not $SystemModulePath) {
            # Correct PS7 fallback - must include \7\
            $SystemModulePath = 'C:\Program Files\PowerShell\7\Modules'
            Write-Warn "PS7 module folder not found in PSModulePath, using default: $SystemModulePath"
        }
    } else {
        $SystemModulePath = ($env:PSModulePath -split ';') |
            Where-Object { $_ -like '*Program Files\WindowsPowerShell\Modules*' } |
            Select-Object -First 1
        if (-not $SystemModulePath) {
            $SystemModulePath = 'C:\Program Files\WindowsPowerShell\Modules'
            Write-Warn "PS5.1 module folder not found in PSModulePath, using default: $SystemModulePath"
        }
    }

    Write-OK "Target PSModulePath: $SystemModulePath"

    # Create module path if it doesn't exist (create each segment separately)
    if (-not (Test-Path $SystemModulePath)) {
        New-Item -ItemType Directory -Path $SystemModulePath -Force | Out-Null
        Write-OK "Created: $SystemModulePath"
    }

    foreach ($mod in $ModuleDefinitions) {
        Write-Step "Installing: $($mod.Name)"
        $srcPath = Join-Path $ModuleStaging $mod.SubDir
        if (-not (Test-Path $srcPath)) { Write-Warn "Staging folder not found: $srcPath - skipping"; continue }

        if ($mod.Name -eq 'VMware.PowerCLI') {
            $modFolders = Get-ChildItem -Path $srcPath -Directory
        } else {
            $modFolders = Get-ChildItem -Path $srcPath -Directory | Where-Object { $_.Name -like "$($mod.Name)*" }
        }

        if (-not $modFolders) { Write-Warn "No module folders found for $($mod.Name) in $srcPath"; continue }

        foreach ($folder in $modFolders) {
            $dest = Join-Path $SystemModulePath $folder.Name
            if (Test-Path $dest) { Write-Warn "$($folder.Name) already exists - skipping copy" }
            else {
                Copy-Item -Path $folder.FullName -Destination $dest -Recurse -Force
                Write-OK "Copied: $($folder.Name) -> $dest"
            }
        }

        Get-ChildItem -Path (Join-Path $SystemModulePath "$($mod.Name)*") -Recurse -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    }

    Write-Step "Importing all modules..."

    # Optional diagram modules - load if available, skip silently if not
    foreach ($optMod in @('PSGraph', 'Diagrammer.Core')) {
        if (Get-Module -Name $optMod -ListAvailable) {
            try {
                Import-Module -Name $optMod -ErrorAction Stop -WarningAction SilentlyContinue
                $ver = (Get-Module -Name $optMod).Version
                Write-OK "$optMod v$ver imported (optional)"
            }
            catch { Write-Warn "$optMod failed to import - diagram features unavailable: $_" }
        } else {
            Write-Warn "$optMod not found - diagram features will be unavailable"
        }
    }

    $importOrder = @(
        'VMware.PowerCLI'
        'PScribo'
        'AsBuiltReport.Core'
        'AsBuiltReport.VMware.Horizon'
        'AsBuiltReport.VMware.AppVolumes'
        'AsBuiltReport.VMware.UAG'
        'AsBuiltReport.VMware.vSphere'
    )

    $importErrors = @()
    foreach ($modName in $importOrder) {
        try {
            # VMware.PowerCLI has a known assembly conflict warning on PS7 (VMware.Bindings.Nsx.Policy).
            # Suppressing warnings allows it to load successfully despite the conflict.
            if ($modName -eq 'VMware.PowerCLI') {
                Import-Module -Name $modName -ErrorAction Stop -WarningAction SilentlyContinue
            } else {
                Import-Module -Name $modName -ErrorAction Stop
            }
            $ver = (Get-Module -Name $modName).Version
            Write-OK "$modName v$ver imported"
        }
        catch { $importErrors += $modName; Write-Warn "ERROR importing ${modName}: $_" }
    }

    Write-Step "Configuring PowerCLI (ignore certificate errors, CEIP off)..."
    try {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false | Out-Null
        Write-OK "PowerCLI configured"
    }
    catch { Write-Warn "Could not configure PowerCLI automatically: $_" }

    foreach ($dir in @($ReportOutputDir, $JsonConfigDir)) { Ensure-Dir $dir }
    foreach ($rc in $ReportConfigs) { Ensure-Dir (Join-Path $ReportOutputDir ($rc.Report.Split('.')[-1])) }

    Write-Step "Generating AsBuiltReport JSON configuration files in: $JsonConfigDir"
    foreach ($rc in $ReportConfigs) {
        $jsonPath = Join-Path $JsonConfigDir "$($rc.Filename).json"
        if (Test-Path $jsonPath) { Write-Warn "$($rc.Filename).json already exists - skipping" }
        else {
            try {
                New-AsBuiltReportConfig -Report $rc.Report -FolderPath $JsonConfigDir -Filename $rc.Filename
                Write-OK "Created: $($rc.Filename).json"
            }
            catch { Write-Warn "Could not create $($rc.Filename).json: $_" }
        }
    }

    Write-Host "`n+==================================================================+" -ForegroundColor Green
    Write-Host "|  INSTALL COMPLETE                                                 |" -ForegroundColor Green
    Write-Host "+==================================================================+" -ForegroundColor Green
    if ($importErrors.Count -gt 0) {
        Write-Host "`n  Modules that failed to import:" -ForegroundColor Yellow
        $importErrors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    }
    Write-Host "`n  JSON config:   $JsonConfigDir" -ForegroundColor Cyan
    Write-Host "  Reports:       $ReportOutputDir" -ForegroundColor Cyan
}

# =============================================================================
# PHASE 3 - DOWNLOADPYTHON
# =============================================================================
function Invoke-DownloadPython {
    Write-Host "`n+==============================================+" -ForegroundColor Magenta
    Write-Host "|  AsBuilt Offline - PHASE 3: DOWNLOAD PYTHON  |" -ForegroundColor Magenta
    Write-Host "+==============================================+`n" -ForegroundColor Magenta

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Ensure-Dir $PythonStaging
    $wheelDir = Join-Path $PythonStaging 'wheels'
    Ensure-Dir $wheelDir

    $installerDest = Join-Path $PythonStaging $PythonInstaller
    if (Test-Path $installerDest) {
        Write-Warn "Python installer already exists: $installerDest - skipping download"
    } else {
        Write-Step "Downloading Python $PythonVersion..."
        try {
            Invoke-WebRequest -Uri $PythonUrl -OutFile $installerDest -UseBasicParsing
            $sizeMB = [math]::Round((Get-Item $installerDest).Length / 1MB, 1)
            Write-OK "Python $PythonVersion downloaded ($sizeMB MB): $installerDest"
        }
        catch { Write-Warn "ERROR downloading Python: $_"; return }
    }

    Write-Step "Downloading pip packages..."
    if (-not (Get-Command pip -ErrorAction SilentlyContinue)) {
        Write-Warn "pip not found - Python must be installed on this machine for pip download"
        Write-Host "    Install Python $PythonVersion first, open a new PS session, then re-run DownloadPython." -ForegroundColor Yellow
        return
    }

    foreach ($pkg in $PythonPackages) {
        Write-Step "Downloading: $pkg (with dependencies)..."
        try {
            $result = pip download $pkg --dest $wheelDir --quiet 2>&1
            $files = Get-ChildItem $wheelDir -Filter '*.whl' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-30) }
            Write-OK "$pkg - $($files.Count) wheel file(s) downloaded"
        }
        catch { Write-Warn "ERROR downloading $pkg : $_" }
    }

    $totalWheels = (Get-ChildItem $wheelDir -Filter '*.whl').Count
    Write-Host "`n+======================================================================+" -ForegroundColor Green
    Write-Host "|  DOWNLOADPYTHON COMPLETE                                             |" -ForegroundColor Green
    Write-Host "+======================================================================+" -ForegroundColor Green
    Write-Host "`n  Python installer: $installerDest" -ForegroundColor Cyan
    Write-Host "  Wheel cache:      $wheelDir ($totalWheels files)" -ForegroundColor Cyan
    Write-Host "`n  Copy the entire folder to the air-gapped machine:" -ForegroundColor White
    Write-Host "  $PythonStaging" -ForegroundColor DarkCyan
    Write-Host "`n  Then run: .\AsBuilt-Offline.ps1 -Mode InstallPython`n" -ForegroundColor White
}

# =============================================================================
# PHASE 4 - INSTALLPYTHON
# =============================================================================
function Invoke-InstallPython {
    Write-Host "`n+==============================================+" -ForegroundColor Magenta
    Write-Host "|  AsBuilt Offline - PHASE 4: INSTALL PYTHON   |" -ForegroundColor Magenta
    Write-Host "+==============================================+`n" -ForegroundColor Magenta

    $installerPath = Join-Path $PythonStaging $PythonInstaller
    $wheelDir      = Join-Path $PythonStaging 'wheels'

    if (-not (Test-Path $installerPath)) {
        Write-Fail "Python installer not found: $installerPath"
        Write-Host "  Run: .\AsBuilt-Offline.ps1 -Mode DownloadPython on an internet machine first.`n" -ForegroundColor Yellow
        exit 1
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $installedVer = (python --version 2>&1).ToString().Trim()
        Write-Warn "Python is already installed: $installedVer"
        $answer = Read-Host "    Install Python $PythonVersion anyway? (y/N)"
        if ($answer -notmatch '^[yY]$') {
            Write-Host "  Skipping Python installation - continuing with packages...`n" -ForegroundColor Yellow
        } else { $pythonCmd = $null }
    }

    if (-not $pythonCmd) {
        Write-Step "Installing Python $PythonVersion (silent)..."
        $installArgs = @('/quiet','InstallAllUsers=1','PrependPath=1','Include_test=0','Include_doc=0','Include_launcher=1','Include_pip=1')
        try {
            $proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
            if ($proc.ExitCode -eq 0) { Write-OK "Python $PythonVersion installed" }
            else { Write-Fail "Python installation failed with exit code: $($proc.ExitCode)"; exit 1 }
        }
        catch { Write-Fail "ERROR installing Python: $_"; exit 1 }

        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path','User')
        Write-OK "PATH updated in current session"
    }

    Write-Step "Verifying Python installation..."
    try { $ver = python --version 2>&1; Write-OK "$ver" }
    catch { Write-Fail "python command not found after installation. Restart PowerShell and try again."; exit 1 }

    if (-not (Test-Path $wheelDir)) {
        Write-Warn "Wheel cache not found: $wheelDir - skipping package installation"
    } else {
        $wheelCount = (Get-ChildItem $wheelDir -Filter '*.whl').Count
        Write-Step "Installing pip packages from wheel cache ($wheelCount files)..."
        foreach ($pkg in $PythonPackages) {
            Write-Host "    Installing: $pkg..." -ForegroundColor Gray
            try {
                $result = pip install $pkg --no-index --find-links $wheelDir --quiet 2>&1
                Write-OK "$pkg installed"
            }
            catch { Write-Warn "ERROR installing $pkg : $_" }
        }
        Write-Step "Installed Python packages:"
        pip list --format=columns 2>&1 | Where-Object { $_ -match ($PythonPackages -join '|') } |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGreen }
    }

    Write-Host "`n+======================================================================+" -ForegroundColor Green
    Write-Host "|  INSTALLPYTHON COMPLETE                                              |" -ForegroundColor Green
    Write-Host "+======================================================================+" -ForegroundColor Green
    Write-Host "`n  Python: $(python --version 2>&1)" -ForegroundColor Cyan
    Write-Host "  pip:    $(pip --version 2>&1)" -ForegroundColor Cyan
    Write-Host "`n  Add more packages to `$PythonPackages and re-run DownloadPython/InstallPython." -ForegroundColor Gray
    Write-Host "  Or online: pip install <package>`n" -ForegroundColor Gray
}

# =============================================================================
# PHASE 5 - DOWNLOADGRAPHVIZ
# =============================================================================
function Invoke-DownloadGraphviz {
    Write-Host "`n+==============================================+" -ForegroundColor Magenta
    Write-Host "|  AsBuilt Offline - PHASE 5: DOWNLOAD GRAPHVIZ|" -ForegroundColor Magenta
    Write-Host "+==============================================+`n" -ForegroundColor Magenta

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Ensure-Dir $GraphvizStaging

    $installerDest = Join-Path $GraphvizStaging $GraphvizInstaller
    if (Test-Path $installerDest) {
        Write-Warn "Graphviz installer already exists: $installerDest - skipping download"
    } else {
        Write-Step "Downloading Graphviz $GraphvizVersion..."
        Write-Host "    Source: $GraphvizUrl" -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $GraphvizUrl -OutFile $installerDest -UseBasicParsing
            $sizeMB = [math]::Round((Get-Item $installerDest).Length / 1MB, 1)
            Write-OK "Graphviz $GraphvizVersion downloaded ($sizeMB MB): $installerDest"
        }
        catch { Write-Fail "ERROR downloading Graphviz: $_"; return }
    }

    Write-Host "`n+======================================================================+" -ForegroundColor Green
    Write-Host "|  DOWNLOADGRAPHVIZ COMPLETE                                           |" -ForegroundColor Green
    Write-Host "+======================================================================+" -ForegroundColor Green
    Write-Host "`n  Installer: $installerDest" -ForegroundColor Cyan
    Write-Host "`n  Copy the Graphviz folder to the air-gapped machine:" -ForegroundColor White
    Write-Host "  $GraphvizStaging" -ForegroundColor DarkCyan
    Write-Host "`n  Then run: .\AsBuilt-Offline.ps1 -Mode InstallGraphviz`n" -ForegroundColor White
}

# =============================================================================
# PHASE 6 - INSTALLGRAPHVIZ
# =============================================================================
function Invoke-InstallGraphviz {
    Write-Host "`n+==============================================+" -ForegroundColor Magenta
    Write-Host "|  AsBuilt Offline - PHASE 6: INSTALL GRAPHVIZ |" -ForegroundColor Magenta
    Write-Host "+==============================================+`n" -ForegroundColor Magenta

    $installerPath = Join-Path $GraphvizStaging $GraphvizInstaller

    if (-not (Test-Path $installerPath)) {
        Write-Fail "Graphviz installer not found: $installerPath"
        Write-Host "  Run: .\AsBuilt-Offline.ps1 -Mode DownloadGraphviz on an internet machine first.`n" -ForegroundColor Yellow
        exit 1
    }

    # Check if already installed
    $dotExe = Join-Path $GraphvizInstallDir 'bin\dot.exe'
    if (Test-Path $dotExe) {
        $existingVer = (& $dotExe -V 2>&1).ToString().Trim()
        Write-Warn "Graphviz already installed: $existingVer"
        $answer = Read-Host "    Reinstall Graphviz $GraphvizVersion anyway? (y/N)"
        if ($answer -notmatch '^[yY]$') {
            Write-Host "  Skipping Graphviz installation.`n" -ForegroundColor Yellow
        } else {
            $dotExe = $null
        }
    } else {
        $dotExe = $null
    }

    if (-not $dotExe) {
        Write-Step "Installing Graphviz $GraphvizVersion (silent)..."
        # /S = silent install, /D sets install directory (must be last argument, no quotes)
        try {
            $proc = Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -PassThru
            if ($proc.ExitCode -eq 0) { Write-OK "Graphviz $GraphvizVersion installed to $GraphvizInstallDir" }
            else { Write-Fail "Graphviz installation failed with exit code: $($proc.ExitCode)"; exit 1 }
        }
        catch { Write-Fail "ERROR installing Graphviz: $_"; exit 1 }
    }

    # Add Graphviz bin to system PATH if not already present
    Write-Step "Checking PATH..."
    $graphvizBin = Join-Path $GraphvizInstallDir 'bin'
    $currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($currentPath -notlike "*$graphvizBin*") {
        [System.Environment]::SetEnvironmentVariable('Path', "$currentPath;$graphvizBin", 'Machine')
        Write-OK "Added to system PATH: $graphvizBin"
        Write-Warn "Open a new PowerShell session for PATH to take effect"
    } else {
        Write-OK "Already in system PATH: $graphvizBin"
    }

    # Also update current session PATH so we can verify immediately
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # Verify
    Write-Step "Verifying Graphviz installation..."
    $dotPath = Join-Path $GraphvizInstallDir 'bin\dot.exe'
    if (Test-Path $dotPath) {
        $ver = (& $dotPath -V 2>&1).ToString().Trim()
        Write-OK "dot.exe found: $ver"
    } else {
        Write-Fail "dot.exe not found at $dotPath - installation may have failed"
        exit 1
    }

    Write-Host "`n+======================================================================+" -ForegroundColor Green
    Write-Host "|  INSTALLGRAPHVIZ COMPLETE                                            |" -ForegroundColor Green
    Write-Host "+======================================================================+" -ForegroundColor Green
    Write-Host "`n  Graphviz: $((& $dotPath -V 2>&1).ToString().Trim())" -ForegroundColor Cyan
    Write-Host "  Location: $GraphvizInstallDir" -ForegroundColor Cyan
    Write-Host "`n  Open a new PowerShell session, then re-run:" -ForegroundColor White
    Write-Host "  .\AsBuilt-Offline.ps1 -Mode Install`n" -ForegroundColor White
}

# =============================================================================
# MAIN
# =============================================================================
switch ($Mode) {
    'Download'          { Invoke-Download        }
    'Install'           { Invoke-Install         }
    'DownloadPython'    { Invoke-DownloadPython   }
    'InstallPython'     { Invoke-InstallPython    }
    'DownloadGraphviz'  { Invoke-DownloadGraphviz }
    'InstallGraphviz'   { Invoke-InstallGraphviz  }
}
