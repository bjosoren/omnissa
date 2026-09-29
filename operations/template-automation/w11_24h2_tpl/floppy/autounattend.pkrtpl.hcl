<?xml version="1.0" encoding="utf-8"?>
<!--
  Windows 11 unattend answer file, rendered by w11_24h2_tpl.pkr.hcl
  (templatefile) and delivered on the virtual floppy.
  windowsPE    - disk layout, edition, GVLK; LabConfig bypass for the TPM (and,
                 without Secure Boot, the Secure Boot) hardware check
  specialize   - hostname, locale, Administrator password, no lockout,
                 no automatic device encryption
  oobeSystem   - Reseal to Audit Mode: first boot goes straight into Audit Mode
  auditSystem  - Administrator password + auto-logon
  auditUser    - network Private, WinRM (HTTP, Basic + Negotiate), BitLocker off,
                 VMware Tools from A:\windows-vmtools.ps1
  WinRM is unencrypted HTTP: use an isolated build network only.
-->

<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>${win_language}</UILanguage>
      </SetupUILanguage>
      <InputLocale>${win_keyboard}</InputLocale>
      <SystemLocale>${win_language}</SystemLocale>
      <UILanguage>${win_language}</UILanguage>
      <UILanguageFallback>${win_language}</UILanguageFallback>
      <UserLocale>${win_language}</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
%{ if !secure_boot ~}

        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>cmd.exe /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
%{ endif ~}
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd.exe /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Size>550</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>EFI</Type>
              <Size>100</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>4</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>WINRE</Label>
              <Format>NTFS</Format>
              <TypeID>DE94BBA4-06D1-4D40-A16A-BFD50179D6AC</TypeID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>4</Order>
              <PartitionID>4</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>

              <Value>${win_image_name}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>4</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <ProductKey>
          <Key>${win_kms_key}</Key>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>${win_full_name}</FullName>
        <Organization>${win_org_name}</Organization>
      </UserData>

    </component>
  </settings>

  <settings pass="specialize">

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

      <ComputerName>${guest_hostname}</ComputerName>
      <TimeZone>${timezone}</TimeZone>
    </component>

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>${win_keyboard}</InputLocale>
      <SystemLocale>${win_language}</SystemLocale>
      <UILanguage>${win_language}</UILanguage>
      <UserLocale>${win_language}</UserLocale>
    </component>

    <component name="Microsoft-Windows-Security-SPP-UX"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SkipAutoActivation>true</SkipAutoActivation>
    </component>

    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>

        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c net user Administrator /active:yes</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>

          <Path>cmd.exe /c net user Administrator "${build_password}"</Path>
        </RunSynchronousCommand>

        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd.exe /c powershell -Command "Set-LocalUser -Name Administrator -PasswordNeverExpires $true; $u=[ADSI]('WinNT://'+$env:COMPUTERNAME+'/Administrator,user'); $u.Put('PasswordExpired',0); $u.SetInfo()"</Path>
        </RunSynchronousCommand>

        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>cmd.exe /c net accounts /lockoutthreshold:0</Path>
        </RunSynchronousCommand>

        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Path>cmd.exe /c reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>

  </settings>

  <settings pass="oobeSystem">

    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Reseal>
        <Mode>Audit</Mode>
      </Reseal>
    </component>

  </settings>

  <settings pass="auditSystem">

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <AdministratorPassword>
          <Value>${build_password}</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>

      <AutoLogon>
        <Password>
          <Value>${build_password}</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>999</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
    </component>

  </settings>

  <settings pass="auditUser">

    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>

        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c powershell -Command "Set-LocalUser -Name Administrator -PasswordNeverExpires $true; $u=[ADSI]('WinNT://'+$env:COMPUTERNAME+'/Administrator,user'); $u.Put('PasswordExpired',0); $u.SetInfo()"</Path>
        </RunSynchronousCommand>

        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>

          <Path>cmd.exe /c powershell -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd.exe /c winrm quickconfig -quiet</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>cmd.exe /c sc config winrm start= auto</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>

          <Path>cmd.exe /c winrm set winrm/config/service @{AllowUnencrypted="true"}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>6</Order>
          <Path>cmd.exe /c winrm set winrm/config/service/auth @{Basic="true"}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>7</Order>

          <Path>cmd.exe /c winrm set winrm/config/service/auth @{Negotiate="true"}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>8</Order>
          <Path>cmd.exe /c netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in action=allow protocol=TCP localport=5985</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>9</Order>
          <Path>cmd.exe /c net stop winrm &amp; net start winrm</Path>
        </RunSynchronousCommand>

        <RunSynchronousCommand wcm:action="add">
          <Order>10</Order>

          <Path>cmd.exe /c reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>11</Order>

          <Path>cmd.exe /c sc.exe stop BDESVC</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>12</Order>

          <Path>cmd.exe /c sc.exe config BDESVC start= disabled</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>13</Order>

          <Path>cmd.exe /c manage-bde -off C:</Path>
        </RunSynchronousCommand>

        <RunSynchronousCommand wcm:action="add">
          <Order>14</Order>

          <Path>cmd.exe /c powershell -Command "Set-ExecutionPolicy Bypass -Scope LocalMachine -Force"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>15</Order>

          <Path>cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File A:\windows-vmtools.ps1</Path>
        </RunSynchronousCommand>

      </RunSynchronous>
    </component>

  </settings>

</unattend>
