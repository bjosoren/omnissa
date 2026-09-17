// ubt_2404_tpl.pkr.hcl
// Builds the Ubuntu 24.04 LTS Desktop golden image for the HZUBTP1 Omnissa Horizon
// instant-clone pool: boots the Desktop ISO under vSphere, feeds it an autoinstall
// answer file over Packer's own HTTP server, then hands off to Ansible for
// everything in-guest. Mirrors the manual procedure at
// https://tech.iot-it.no/omnissa-horizon-ubuntu-24-04-desktop-instant-clone-template/
// one-for-one - see playbook.yml and roles/ for the step-by-step mapping.
//
// This does NOT convert the VM to a vSphere template: Horizon instant clones are
// built from a snapshot on a normal VM, not a vCenter template.
//
// vm_name (and mac_address, guest_ip_cidr, etc.) stays fixed across every run -
// scripts/build.sh runs `packer build -force` so this same-named VM gets
// destroyed and rebuilt from scratch each time, rather than a fresh
// timestamped VM per run like earlier versions of this project did. That
// change came from a real failure: once a build's finished VM got published
// to the Horizon pool, Horizon locks it, but it kept holding the same pinned
// MAC/static IP the next build's own guest also configured, and the two
// live VMs fighting over one identity on the network is what caused
// intermittent SSH-after-reboot failures on the next run. scripts/build.sh's
// post-build step now clones this VM to a separate, uniquely timestamped VM
// (with its own, freshly assigned MAC) before snapshotting - that clone,
// not this VM, is what actually gets published to Horizon. See
// variables.pkr.hcl's vm_name/mac_address comments and post_build_snapshot.yml.

packer {
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "~> 1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1"
    }
  }
}

locals {
  # Rendered once and reused for both the boot_command interpolation and the
  # templated user-data file, so the two can't drift apart.
  user_data = templatefile("${path.root}/http/user-data.pkrtpl.hcl", {
    guest_hostname      = var.guest_hostname
    guest_ip_cidr       = var.guest_ip_cidr
    guest_gateway       = var.guest_gateway
    guest_dns_servers   = var.guest_dns_servers
    timezone            = var.timezone
    locale              = var.locale
    keyboard_layout     = var.keyboard_layout
    build_username      = var.build_username
    build_password_hash = var.build_password_hash
    ssh_public_key      = var.ssh_public_key
  })
}

source "vsphere-iso" "ubt_2404_tpl" {
  # ---- vCenter ----
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection
  datacenter          = var.vcenter_datacenter
  cluster             = var.vcenter_cluster
  datastore           = var.vcenter_datastore
  folder              = var.vcenter_folder

  # ---- VM identity & placement ----
  vm_name       = var.vm_name
  guest_os_type = "ubuntu64Guest"
  CPUs          = var.vm_cpu_count
  RAM           = var.vm_mem_size_mb
  firmware      = "efi"

  storage {
    disk_size             = var.vm_disk_size_mb
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.vcenter_network
    network_card = "vmxnet3"
    mac_address  = var.mac_address
  }

  # ---- Install media ----
  # Already staged on the datastore/content library - Packer mounts it
  # directly, no download and no iso_checksum needed.
  iso_paths = var.iso_paths

  # ---- Autoinstall handoff ----
  # http_content (rather than http_directory) lets the user-data file above be an
  # HCL template instead of a static file, so all the guest-network/identity vars
  # end up in one place (variables.pkr.hcl) instead of being duplicated by hand.
  http_content = {
    "/user-data" = local.user_data
    "/meta-data" = ""
  }

  boot_order = "disk,cdrom"
  boot_wait  = "10s"

  # Packer's default is 100ms between keystroke groups, sent over vSphere's
  # remote-keystroke API - too fast on this platform: a screenshot from an
  # earlier attempt caught the linux line mid-type ("...ds=no_") with typing
  # having visibly stalled, and other attempts landed back on the plain
  # live-installer GUI with no error, consistent with keystrokes being
  # dropped rather than the command itself being wrong. Slowing this down is
  # the officially documented fix ("if you notice missing keys, tune
  # boot_keygroup_interval") - cheaper and more targeted than adding more
  # <wait> padding around keystrokes that are already arriving correctly.
  # Bumped from 500ms to 1000ms after a real build still fell through to the
  # plain interactive live installer even at 500ms (same silent-seed-URL
  # symptom, same fix - this is a keystroke-drop issue, not a config bug, so
  # there's no way to confirm it's fixed for good short of enough repeat runs
  # never showing it again; if it recurs even at 1000ms, this value is the
  # first thing to keep raising, not something else to suspect first).
  boot_keygroup_interval = "1000ms"

  boot_command = [
    # A brand-new disk is blank, so the firmware falls through boot_order to
    # cdrom on its own - no menu, no keystrokes needed to get there - as long
    # as the CD-ROM device actually has a valid, connected ISO. (The one time
    # it doesn't - e.g. iso_paths pointing at a file that doesn't exist on the
    # datastore - vSphere's EFI firmware stops at its own interactive "Boot
    # Manager" chooser instead of erroring, since neither device has anything
    # bootable; that's a datastore/iso_paths problem to fix, not something
    # boot_command should try to click through.) So by boot_wait above, we're
    # already sitting at GRUB's own menu (confirmed - it gives a ~30s
    # countdown before auto-booting its default entry, plenty of slack to
    # press "c" and drop into its command line, same as a BIOS/legacy boot).
    #
    # The "\;" (not a bare ";") below is load-bearing: GRUB's command line
    # treats an unescaped ";" as a statement separator, same as a shell -
    # confirmed the hard way by booting this with a plain ";" and then
    # checking /proc/cmdline afterwards, which showed "ds=nocloud-net" with
    # the whole "s=http://..." seed URL silently chopped off (GRUB had split
    # it into a second, harmless no-op command). No seed URL means
    # cloud-init's nocloud-net datasource has nowhere to fetch from, so it
    # gives up quietly and casper falls through to the normal interactive
    # live session - no error anywhere, which is exactly what made this one
    # so slow to pin down.
    "c",
    "<wait2>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ",
    "<enter>",
    "<wait2>",
    "initrd /casper/initrd",
    "<enter>",
    "<wait2>",
    "boot",
    "<enter>",

    # ---- Poke the graphical installer awake ----
    # A real build surfaced a display bug that's independent of everything
    # above: once casper finishes booting into the live session, the Desktop
    # ISO's graphical installer (the Flutter-based UI autoinstall drives
    # non-interactively) launches on schedule and IS running the autoinstall
    # answers, but its window itself renders as a blank white rectangle in
    # the vSphere VNC console until it receives some input event - confirmed
    # live: a manual click in that white rectangle is what makes it start
    # actually painting/progressing. This is a known class of bug with
    # GPU-rendered (GTK4/Flutter) UIs over a software/remote framebuffer -
    # nothing paints the first frame until an input event forces a
    # recomposite - and it has nothing to do with autoinstall's own answers
    # being wrong or not being consumed; it's purely the console display not
    # drawing what's already happening underneath.
    #
    # v26 shipped a bare left-Alt on/off tap here, spaced out over the first
    # several minutes after boot, on the theory (widely reported for this
    # exact GTK/Flutter-over-VNC symptom) that ANY input event triggers the
    # same redraw a click does, not specifically a mouse event. That theory
    # is now confirmed WRONG by a real, tested build: v26 ran, the taps
    # fired on schedule, and the window still needed a manual click - a
    # modifier key alone genuinely doesn't substitute for a mouse click for
    # this UI.
    #
    # Root cause of why boot_command can't send the literal click at all,
    # confirmed via HashiCorp's own bootcommand package docs: vsphere-iso's
    # boot_command is strictly keyboard-only, no mouse/pointer sequence
    # exists - and there's no VNC session for boot_command to piggyback a
    # click onto either, since (unlike vmware-iso) this builder drives the
    # console through vSphere's own guest keyboard HID API, not raw VNC. So
    # a real fix needs a real pointer event sent from OUTSIDE boot_command
    # entirely - most likely over a WebMKS session (the same mechanism the
    # vSphere HTML5 console itself uses for mouse input), launched by
    # scripts/build.sh alongside packer build. That's the next step if this
    # attempt also fails - not another round of wait-time tuning, since v26
    # already showed timing isn't what's wrong here.
    #
    # Before building that bigger change, one cheaper theory is worth ruling
    # out first: a bare modifier toggle may not even reach the compositor as
    # a normal dispatched key event the way a real key does - some input
    # stacks track modifier state separately and never schedule a repaint
    # for it alone. <tab> is swapped in below instead: a genuine
    # KeyPress/KeyRelease pair GTK's own focus manager processes, so more
    # likely to force a redraw than a state-only modifier - while staying
    # just as safe as the Alt taps under the same original reasoning: Tab
    # only moves focus, it doesn't "activate" whatever it lands on (that
    # needs a follow-up Enter/Space, deliberately never sent here), so it
    # can't corrupt an in-progress screen even in the worst case of landing
    # somewhere unexpected. Same spread-over-5-minutes cadence as v26,
    # unchanged since v26 already showed that part isn't what's being
    # tested here.
    #
    # If a manual click is still needed after this ships, that confirms
    # it's specifically pointer-vs-keyboard, not "which key" - report back
    # either way, since a fail here goes straight to the WebMKS mouse-click
    # build rather than yet another keyboard variant.
    "<wait30>",
    "<tab>",
    "<wait30>",
    "<tab>",
    "<wait60>",
    "<tab>",
    "<wait60>",
    "<tab>",
    "<wait120>",
    "<tab>"
  ]

  # ---- Guest connection once the OS is up ----
  communicator          = "ssh"
  ssh_username          = var.build_username
  ssh_private_key_file  = var.ssh_private_key_file
  ssh_timeout           = "45m" # autoinstall + first boot on a Desktop ISO is slow

  ip_wait_timeout = "45m"

  # Packer runs this itself once every provisioner below has finished, and
  # waits for the VM to actually reach powered-off before returning control -
  # that's what scripts/build.sh's snapshot step depends on. No
  # convert_to_template here on purpose (see file header).
  #
  # sudo's -S reads the password from stdin, but nothing fed it one here -
  # build_username isn't NOPASSWD (same reason the ansible provisioner needs
  # ansible_become_password above), so this command sat blocked waiting on a
  # password that never came until Packer's own shutdown timeout gave up
  # ("timeout while waiting for machine to shutdown") - confirmed live: every
  # prior build had failed earlier in the playbook, so nothing ever actually
  # reached this line before. var.build_password (the same value already used
  # for ansible_become_password) is piped in over stdin instead - it's marked
  # sensitive in variables.pkr.hcl, so Packer redacts it from its own
  # console/log output here exactly like everywhere else it's used. One real
  # caveat: this only works if the password itself contains no single quote
  # (it would break out of the ''); there's no stdin-injection equivalent of
  # Ansible's own `stdin:` parameter available for a builder-level
  # shutdown_command, so unlike the domain-join and Horizon Agent install
  # passwords, this one can't avoid shell quoting entirely.
  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
}

build {
  sources = ["source.vsphere-iso.ubt_2404_tpl"]

  provisioner "ansible" {
    playbook_file = "${path.root}/playbook.yml"
    user          = var.build_username
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False"
    ]
    extra_arguments = [
      # Pull in the shared, non-secret platform vars and the shared vault, plus
      # this project's own non-secret vars, so the playbook sees the exact same
      # vcenter_server/domain_fqdn/computer_ou_dn/vault_linux_domain_join_password/
      # etc. as every other project on the platform - nothing project-specific
      # gets redeclared here, it's all already in these three files.
      "-e", "@${var.inventory_dir}/group_vars/all.yml",
      "-e", "@${var.inventory_dir}/group_vars/all/vault.yml",
      "-e", "@${var.inventory_dir}/group_vars/ubt_2404_tpl.yml",
      "--vault-password-file", "~/.vault_pass",
      # The freshly autoinstalled build_username account isn't NOPASSWD, so
      # every "become: true" task (playbook.yml's very first one is
      # Gathering Facts) fails with "Missing sudo password" without this.
      # var.build_password is marked sensitive - Packer redacts it from its
      # own console/log output the same way it already does for
      # vcenter_password; it only exists in plaintext for the duration of
      # this one ansible-playbook subprocess, never written to disk.
      "-e", "ansible_become_password=${var.build_password}",
      # horizon_agent_install_flags is deliberately NOT one of the three
      # group_vars files above - it's an optional override (default "-A yes"
      # in variables.pkr.hcl) that scripts/build.sh already resolves via
      # resolve_vars.yml and exports as PKR_VAR_horizon_agent_install_flags,
      # same as every other var here. This one just needs its own explicit
      # -e, same reasoning as ansible_become_password above: it's consumed
      # by roles/horizon_agent/tasks/main.yml as
      # {{ horizon_agent_install_flags }}, and Packer variables never
      # automatically become Ansible variables just because both tools read
      # the same group_vars files - each one needed here has to be forwarded
      # explicitly, and this one was missed until a real build finally got
      # far enough to hit it ("'horizon_agent_install_flags' is undefined").
      #
      # This has to be JSON ('{"key": "value"}'), NOT the plain key=value
      # form used for ansible_become_password above - confirmed the hard way
      # against a real build. Ansible's plain "-e key=value" syntax doesn't
      # treat the whole string as one value; it re-splits on whitespace and
      # rebuilds it as a series of key=value pairs (that's what lets
      # `-e "a=1 b=2"` set two vars from a single -e). This value's default
      # is "-A yes" - the one value in this whole file with a space in it -
      # so the plain form split it into "horizon_agent_install_flags=-A" and
      # a bare second token "yes" with no "=" in it, which got silently
      # dropped instead of being glued back onto the value. A live build
      # confirmed this exactly: install_viewagent.sh ran with argv ending at
      # bare "-A" (confirmed via /proc/<pid>/cmdline), which is itself a
      # valid-but-incomplete flag that install_viewagent.sh then sat forever
      # waiting on stdin to complete interactively - stdin the command
      # module never feeds, so the task just hangs rather than failing
      # outright. JSON routes through Ansible's JSON parser instead of the
      # space-splitting key=value one, so it's immune to this regardless of
      # what the value's own content is.
      "-e", "{\"horizon_agent_install_flags\": \"${var.horizon_agent_install_flags}\"}",
    ]
  }

}
