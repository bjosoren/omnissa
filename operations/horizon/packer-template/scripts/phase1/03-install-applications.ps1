<#
.SYNOPSIS
    03-install-applications.ps1
    Installs common applications during audit mode.
    Set APPS_SOURCE env var to a UNC share path, or place installers in C:\Temp.
#>

$ErrorActionPreference = "Continue"
Write-Output "=== Installing Common Applications ==="

# Determine source path
$appsSource = $env:APPS_SOURCE
if ($appsSource -and (Test-Path $appsSource)) {
    Write-Output "Using APPS_SOURCE: $appsSource"
    $localTemp = "C:\Temp\Apps"
    New-Item -ItemType Directory -Path $localTemp -Force | Out-Null
    Copy-Item "$appsSource\*" $localTemp -Recurse -Force -ErrorAction SilentlyContinue
    $installSource = $localTemp
} else {
    Write-Warning "APPS_SOURCE not set or unreachable. Using C:\Temp for locally uploaded installers."
    $installSource = "C:\Temp"
}

# Application install helper
function Install-App {
    param(
        [string]$Name,
        [string]$Installer,
        [string]$Arguments,
        [string]$Type = "exe"
    )
    $path = Join-Path $installSource $Installer
    if (-not (Test-Path $path)) {
        Write-Warning "[$Name] Installer not found at '$path'. Skipping."
        return
    }
    Write-Output "Installing: $Name"
    if ($Type -eq "msi") {
        $proc = Start-Process msiexec.exe -ArgumentList "/i `"$path`" $Arguments" -Wait -PassThru -NoNewWindow
    } else {
        $proc = Start-Process $path -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    }
    Write-Output "[$Name] Exit code: $($proc.ExitCode)"
}

# -- Install applications ------------------------------------------------------
Install-App -Name "7-Zip"                              -Installer "7z-x64.msi"                          -Arguments "/qn /norestart"                    -Type "msi"
Install-App -Name "Notepad++"                          -Installer "npp.Installer.x64.exe"               -Arguments "/S"
Install-App -Name "Google Chrome"                      -Installer "GoogleChromeStandaloneEnterprise64.msi" -Arguments "/qn /norestart"                 -Type "msi"
Install-App -Name "Microsoft Edge WebView2 Runtime"   -Installer "MicrosoftEdgeWebView2RuntimeInstallerX64.exe" -Arguments "/silent /install"
Install-App -Name "Visual C++ 2015-2022 Redistributable x64" -Installer "VC_redist.x64.exe"            -Arguments "/install /quiet /norestart"
Install-App -Name "Microsoft 365 Apps"                 -Installer "Office365\setup.exe"                 -Arguments "/configure Office365\configuration.xml"

# -- Disable auto-updaters -----------------------------------------------------
Write-Output "Disabling auto-updaters..."

# Chrome auto-update
reg add "HKLM\SOFTWARE\Policies\Google\Update" /v AutoUpdateCheckPeriodMinutes /t REG_DWORD /d 0 /f 2>$null | Out-Null

# Windows Store auto-updates
reg add "HKLM\SOFTWARE\Policies\Microsoft\WindowsStore" /v AutoDownload /t REG_DWORD /d 2 /f 2>$null | Out-Null

Write-Output "=== Application installation complete ==="
