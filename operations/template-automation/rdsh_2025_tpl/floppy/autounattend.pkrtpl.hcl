<?xml version="1.0" encoding="utf-8"?>
<!--
  autounattend.pkrtpl.hcl
  Windows Server 2025 unattend answer file, templated by rdsh_2025_tpl.pkr.hcl's
  local.autounattend and delivered via floppy_content (see that file's header
  comment for why floppy_content rather than the source guide's genisoimage+
  CD-ROM approach). Adapted from the Omnissa Community guide's
  packer/autounattend-rdsh.xml with $${...} Terraform template interpolation
  in place of that guide's __TOKEN__ / Ansible replace() substitution -
  same adaptation ubt_2404_tpl.pkr.hcl's user-data.pkrtpl.hcl already made
  for the Linux side.

  No Secure Boot / BitLocker-suppression-is-still-needed-anyway note: Server
  editions don't turn on device encryption by default the way Windows 11
  Home/Pro does, but the auditUser commands below still explicitly disable it
  (same as the source guide) as defense-in-depth against a policy or image
  default doing so unexpectedly mid-build.

  REWRITTEN 2026-09-16, per the user's explicit request after reviewing
  Omnissa's own "Manually creating optimized Windows images for Horizon VMs"
  PDF end to end (its "Enter audit mode" chapter, page 16): that guide enters
  Audit Mode DURING Windows installation - immediately after the very first
  post-install boot, before OOBE ever runs - by pressing CTRL+SHIFT+F3 at
  the first OOBE screen. That's a manual, interactive keypress, but the same
  outcome is documented as achievable purely through answer-file settings
  (Microsoft Learn, "Boot Windows to Audit Mode or OOBE":
  https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/boot-windows-to-audit-mode-or-oobe) -
  quoting that page directly: "To configure Windows to boot to audit mode,
  add the Microsoft-Windows-Deployment | Reseal | Mode = audit answer file
  setting", and separately, critically: "Settings in an answer file from the
  oobeSystem configuration pass do not appear in audit mode" - confirming
  that adding Reseal/Mode=Audit causes Setup to skip oobeSystem's own
  settings entirely and process auditSystem/auditUser instead (Microsoft
  Learn, "auditSystem": "the auditSystem configuration pass and the
  auditUser unattended Windows Setup settings are processed" when booting to
  audit mode - https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/auditsystem).
  Reseal/Mode's own component reference confirms Audit/OOBE as its two valid
  values and oobeSystem as one of its three valid passes (the other two,
  auditSystem/auditUser, are for a LATER reseal decision, not this one):
  https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-reseal-mode.

  This REPLACES the pipeline's previous two-stage approach: complete a full
  OOBE-based first boot (this file's own old oobeSystem pass: OOBE/
  UserAccounts/AutoLogon/FirstLogonCommands, same shape ubt_2404_tpl's own
  Linux answer file uses), THEN have roles/enter_audit_mode trigger a
  SEPARATE `sysprep /audit /reboot /unattend:...` over WinRM once Ansible
  connects. That worked (confirmed on real builds), but the PDF makes clear
  it's not how Omnissa's own guide builds an RDSH/Windows 11 template at
  all - audit mode is meant to be the FIRST state the machine ever reaches,
  not something bolted on after a full OOBE boot. Skipping the OOBE detour
  entirely is also strictly less to go wrong: one boot into the real target
  state instead of two, and roles/enter_audit_mode no longer has to trigger
  or wait for a reboot it used to own (see that role's own header for what
  it does now instead - verification, not triggering).

  What moved where, and why:
    - windowsPE, specialize passes: UNCHANGED. Both always run regardless
      of audit-vs-OOBE (specialize completes before Setup ever decides
      which of the two comes next), so ComputerName/TimeZone/locale/
      SkipAutoActivation and the Administrator account
      activation/password/lockout-threshold/PasswordNeverExpires
      RunSynchronousCommand block below are all still exactly where they
      need to be.
    - oobeSystem pass: GUTTED. Its old International-Core/OOBE/
      UserAccounts/AutoLogon/FirstLogonCommands content is now dead code
      per the "settings ... do not appear in audit mode" quote above -
      replaced with nothing but the Reseal/Mode=Audit trigger itself. The
      locale settings it used to duplicate are already covered by
      specialize's own Microsoft-Windows-International-Core component
      above, so nothing is lost by removing the duplicate.
    - auditSystem, auditUser passes: NEW - this is where OOBE's old job
      moves to. Content is adapted directly from
      roles/enter_audit_mode/templates/audit_answer.xml.j2 (now DELETED -
      see enter_audit_mode's own header for the full pointer), which
      already proved this exact auditSystem/auditUser split correct on
      real builds for the pipeline's SECOND, later audit-mode entry -
      reused here verbatim for the FIRST one instead of being written from
      scratch:
        - auditSystem: UserAccounts/AdministratorPassword + AutoLogon
          together (Microsoft's own AdministratorPassword schema
          reference: "Both ... Autologon and ... AdministratorPassword
          sections are now needed for autologon in audit mode to work.
          Both of these settings should be added to the auditSystem
          configuration pass" -
          https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-administratorpassword).
          LogonCount=999, not 1 - this session has to survive every reboot
          from here through osot_generalize's own exit from Audit Mode
          (dotnet35/windows_update's loop/apps/osot_optimize all now run
          inside this same Audit Mode session from the very first boot
          onward, one boot earlier than before).
        - auditUser: Microsoft-Windows-Deployment/RunSynchronous/
          RunSynchronousCommand - audit mode's equivalent of
          FirstLogonCommands (RunSynchronous's own documented valid passes
          are auditUser and specialize only, confirmed against Microsoft's
          component reference, same citation audit_answer.xml.j2's header
          already used). Carries, in order: the same
          PasswordNeverExpires/PasswordExpired fix and WinRM bootstrap
          (quickconfig/auto-start/AllowUnencrypted/Basic/Negotiate/
          firewall/Private-profile/restart) audit_answer.xml.j2 already
          proved works, UNCHANGED - then, newly appended, the BitLocker-
          prevention and VMware Tools install commands that used to live
          in oobeSystem's own FirstLogonCommands (same commands, just
          re-homed under RunSynchronousCommand's simpler
          Order+Path-only shape instead of SynchronousCommand's
          Order+Description+CommandLine+RequiresUserInput one - no
          Description/RequiresUserInput equivalent exists on this
          element, hence the XML comments carrying what each command
          does). windows-vmtools.ps1 itself has no OOBE-specific
          assumptions (checked directly - plain CD-ROM detection + silent
          install), and the floppy stays attached/mounted as A:\ for the
          life of the build regardless of reboots or which configuration
          pass is running, so referencing A:\windows-vmtools.ps1 from here
          instead of oobeSystem is safe.
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
              <!-- Must match an edition name inside install.wim exactly -
                   list them with: dism /Get-WimInfo /WimFile:D:\sources\install.wim -->
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
      <!-- Windows NetBIOS computer names cap at 15 characters - keep
           guest_hostname under that (see variables.pkr.hcl's comment) or
           this gets silently truncated. -->
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
        <!-- Activate + password the built-in Administrator account here,
             during specialize - before oobeSystem's own AdministratorPassword
             block runs - so the account is already usable the moment setup
             reaches OOBE, not left disabled/passwordless in between. -->
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c net user Administrator /active:yes</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <!-- build_password is plaintext here, same tradeoff ubt_2404_tpl's
               shutdown_command comment already flags for its own sudo pipe:
               this breaks if the password itself contains a double-quote.
               Keep build_password free of double-quotes for this reason. -->
          <Path>cmd.exe /c net user Administrator "${build_password}"</Path>
        </RunSynchronousCommand>

        <!-- ADDED 2026-09-14, SECOND round: the oobeSystem FirstLogonCommands
             fix below (order 7, "Clear must change password on
             Administrator") turned out NOT to be durable - a real build got
             past it fine on first boot (WinRM worked, enter_audit_mode's
             Ansible tasks all succeeded, sysprep /audit /reboot triggered
             cleanly), then came back up staring at an interactive "Your
             password has expired and must be changed" lock screen, meaning
             the must-change flag was back by the time Windows re-evaluated
             the account crossing into Audit Mode - and since that screen
             blocks AutoLogon from ever completing, audit_answer.xml.j2's own
             auditUser/RunSynchronousCommand block never even gets a chance
             to run a fix of its own; nothing inside that file can self-heal
             this.
             Root-caused this round to the WRONG kind of fix, not the wrong
             cause: PasswordExpired=0 only clears the current one-time
             "must change" bit, it doesn't stop Windows re-deriving that same
             bit later from the account's password-age/expiration POLICY -
             and sysprep transitioning into Audit Mode is exactly the kind of
             re-evaluation point that can re-derive it. Set-LocalUser
             -PasswordNeverExpires $true addresses the actual policy, not
             just its current symptom - added here, in specialize, before
             this account is ever logged into or rebooted for the first
             time, specifically so it's in force before ANY of the many
             reboots this account has to survive (oobeSystem AutoLogon,
             audit mode entry/exit, windows_update's loop, osot_optimize,
             osot_generalize's own Sysprep reboot - see the lockoutthreshold
             comment below for the same "protect every reconnection, not
             just the one that surfaced this" reasoning). Kept alongside the
             existing PasswordExpired=0 clears (now also upgraded to include
             this) rather than replacing them - belt and suspenders, since
             it's still not confirmed with certainty that PasswordNeverExpires
             alone is sufficient on its own. -->
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd.exe /c powershell -Command "Set-LocalUser -Name Administrator -PasswordNeverExpires $true; $u=[ADSI]('WinNT://'+$env:COMPUTERNAME+'/Administrator,user'); $u.Put('PasswordExpired',0); $u.SetInfo()"</Path>
        </RunSynchronousCommand>

        <!-- Disable local account lockout entirely - ADDED 2026-09-14 after
             a real build's enter_audit_mode reconnection failed with
             "the specified credentials were rejected by the server", and a
             long console debugging session (correct password proven via a
             freshly-set test password, LocalAccountTokenFilterPolicy already
             correctly 1, TrustedHosts/client-side AllowUnencrypted both
             fine, Basic AND Negotiate both failing identically, zero
             Security-log 4625 entries for any of it) eventually traced it to
             the built-in Administrator account being locked out - confirmed
             directly via `net use \\<ip>\C$ /user:Administrator <pw>`
             returning "System error 1909... currently locked out", and
             resolved instantly by unlocking the account (Local Users and
             Groups > Administrator > uncheck "Account is locked out", or the
             ADSI WinNT provider equivalent). WinRM/WS-Man itself never
             surfaces lockout distinctly - both Test-WSMan and Ansible's own
             wait_for_connection just report a generic "Access is denied" /
             "credentials were rejected", identical to what a wrong password
             or a dozen other causes would also produce - net use over SMB
             was what actually named the real cause.
             Root cause of the lockout itself: wait_for_connection retries
             roughly every 15s for up to 1800s against a brand-new VM's
             freshly-created SAM database - if even a handful of the
             earliest retries reach the WinRM service while it's still
             mid-transition (before this same specialize pass's later
             WinRM-bootstrap FirstLogonCommands, or auditUser's own
             RunSynchronousCommand block in
             roles/enter_audit_mode/templates/audit_answer.xml.j2, have
             fully settled) and get treated as failed logons, that's
             plausibly enough to cross a hardened environment's lockout
             threshold within the first minute - after which every
             subsequent retry for the rest of that window fails identically
             regardless of how correct the real credentials are, until
             Ansible's own timeout gives up.
             Fix: disable lockout entirely for this account/image rather
             than chase the exact number of early retries that trip it.
             Defensible specifically because this is a single-purpose,
             ephemeral build VM, destroyed after every run - account-lockout
             brute-force protection has no real security value here, and
             this environment's own default lockout policy is exactly what
             turned an otherwise-transient timing hiccup into a full build
             failure. Placed here (specialize, before this pass's own later
             WinRM-bootstrap FirstLogonCommands run) so it protects every
             single WinRM reconnection for the rest of this image's build -
             enter_audit_mode's, but also windows_update's loop,
             osot_optimize's reboot, and osot_generalize's Sysprep reboot -
             not just the one that originally surfaced this. -->
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>cmd.exe /c net accounts /lockoutthreshold:0</Path>
        </RunSynchronousCommand>

        <!-- winrmadmin (dedicated local admin account for WinRM, added
             2026-09-14 after Administrator's WinRM logons kept failing all
             session) REMOVED again the same day, per the user's explicit
             request, after the very next real build hung at a different
             point (Packer's own initial WinRM communicator connection, with
             the console showing a fully-booted desktop entirely
             unresponsive to input) - which looks like an ESXi/vCenter-level
             pending-question VM pause, not something this account addition
             would cause, but removing it narrows things down while that
             gets checked separately. variables.pkr.hcl's build_username is
             back to "Administrator" - see that variable's own comment for
             the full history if this needs revisiting. -->
      </RunSynchronous>
    </component>

  </settings>

  <settings pass="oobeSystem">

    <!-- This is now the ENTIRE oobeSystem pass - see file header for why.
         Its only job is to tell Setup to reseal straight into Audit Mode
         instead of ever running OOBE, which is also why nothing else in
         this pass (locale, UserAccounts, AutoLogon, FirstLogonCommands)
         is still here - none of it would ever be processed anyway. -->
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

    <!-- Both UserAccounts/AdministratorPassword and AutoLogon are required
         TOGETHER here - see file header's Microsoft-quote citation.
         LogonCount=999: this session has to survive every reboot from here
         through osot_generalize's own exit from Audit Mode, not just this
         first one. -->
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

    <!-- Audit mode's equivalent of oobeSystem's FirstLogonCommands -
         Microsoft-Windows-Deployment/RunSynchronous/RunSynchronousCommand,
         valid only in the auditUser and specialize passes. Orders 1-9 are
         the WinRM bootstrap this pipeline already proved working (moved
         verbatim from the now-deleted audit_answer.xml.j2 - see that
         role's own header). Orders 10-15 are newly appended: the
         BitLocker-prevention and VMware Tools install commands that used
         to live in oobeSystem's own FirstLogonCommands, now homeless
         since that pass no longer runs - functionally identical commands,
         just under RunSynchronousCommand's simpler Order+Path shape
         (no Description/RequiresUserInput equivalent exists here, hence
         the comments). -->
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>

        <!-- ── Administrator account hardening, same fix already proven in
             audit_answer.xml.j2 - see this file's header for the primary
             source. Placed first, before the WinRM commands, so nothing
             tries a network logon against this account while any
             must-change/expiry flag might still be set. ─────────────── -->
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c powershell -Command "Set-LocalUser -Name Administrator -PasswordNeverExpires $true; $u=[ADSI]('WinNT://'+$env:COMPUTERNAME+'/Administrator,user'); $u.Put('PasswordExpired',0); $u.SetInfo()"</Path>
        </RunSynchronousCommand>

        <!-- ── WinRM bootstrap, so Packer's own communicator + the ansible
             provisioner can reach this VM ─────────────────────────── -->
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>cmd.exe /c winrm quickconfig -quiet</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd.exe /c sc config winrm start= auto</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <!-- Build network only - see rdsh_2025_tpl.pkr.hcl's winrm_use_ssl
               comment. -->
          <Path>cmd.exe /c winrm set winrm/config/service @{AllowUnencrypted="true"}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Path>cmd.exe /c winrm set winrm/config/service/auth @{Basic="true"}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>6</Order>
          <!-- Negotiate (NTLM) - see rdsh_2025_tpl.pkr.hcl's
               ansible_winrm_transport=ntlm comment for why this pipeline's
               Ansible connection uses it. -->
          <Path>cmd.exe /c winrm set winrm/config/service/auth @{Negotiate="true"}</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>7</Order>
          <Path>cmd.exe /c netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in action=allow protocol=TCP localport=5985</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>8</Order>
          <!-- Windows Firewall's Public-profile default blocks WinRM even
               after quickconfig - a well-known real-world gotcha, not
               optional cleanup. -->
          <Path>cmd.exe /c powershell -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>9</Order>
          <Path>cmd.exe /c net stop winrm &amp; net start winrm</Path>
        </RunSynchronousCommand>

        <!-- ── BitLocker: defense-in-depth, see file header note - moved
             from oobeSystem's own FirstLogonCommands ────────────────── -->
        <RunSynchronousCommand wcm:action="add">
          <Order>10</Order>
          <!-- Prevent BitLocker device encryption -->
          <Path>cmd.exe /c reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>11</Order>
          <!-- Stop BitLocker Drive Encryption Service -->
          <Path>cmd.exe /c sc.exe stop BDESVC</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>12</Order>
          <!-- Disable BitLocker Drive Encryption Service at startup -->
          <Path>cmd.exe /c sc.exe config BDESVC start= disabled</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>13</Order>
          <!-- Turn off device encryption on C: if already started -->
          <Path>cmd.exe /c manage-bde -off C:</Path>
        </RunSynchronousCommand>

        <!-- ── VMware Tools - moved from oobeSystem's own
             FirstLogonCommands. windows-vmtools.ps1 ships on the same
             floppy as this file - vsphere-iso's floppy_content mounts as
             A:\ for the life of the build, unaffected by which
             configuration pass is currently running. ────────────────── -->
        <RunSynchronousCommand wcm:action="add">
          <Order>14</Order>
          <!-- Set Execution Policy -->
          <Path>cmd.exe /c powershell -Command "Set-ExecutionPolicy Bypass -Scope LocalMachine -Force"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>15</Order>
          <!-- Install VMware Tools -->
          <Path>cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File A:\windows-vmtools.ps1</Path>
        </RunSynchronousCommand>

      </RunSynchronous>
    </component>

  </settings>

</unattend>
