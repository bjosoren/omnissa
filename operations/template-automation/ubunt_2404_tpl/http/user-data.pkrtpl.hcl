#cloud-config
# Rendered by Packer's templatefile() from ubt_2404_tpl.pkr.hcl - don't hand-edit
# a copy of this, edit the .pkrtpl.hcl source and re-run the build.
#
# Deliberately NOT using "mode: oem" - that defers setup to a GNOME first-boot
# wizard aimed at end users, which is exactly what the manual procedure's Step 10
# removes for a golden image. Providing "identity" directly here does a normal
# unattended install with no wizard at all.
autoinstall:
  version: 1
  locale: "${locale}"
  keyboard:
    layout: "${keyboard_layout}"
  timezone: "${timezone}"

  source:
    id: ubuntu-desktop

  # Desktop autoinstall defaults to the "hwe" kernel flavor (Canonical's own
  # autoinstall reference: "generic" for Server, "hwe" for Desktop) - pinning
  # to "generic" avoids pulling in a kernel variant that's less likely to
  # already be sitting in the ISO's own package pool. Turned out not to be
  # the real fix for what follows below, but there's no reason to prefer
  # "hwe" for a fixed VDI golden image, so it stays.
  kernel:
    flavor: generic

  # A prior version of this file restricted apt to the ISO's own file:/cdrom
  # pool, on the theory that this VM's build VLAN couldn't resolve DNS
  # inside curtin's install chroot. That diagnosis was half right and half
  # wrong: `cat /target/etc/resolv.conf` from a terminal mid-failure came
  # back empty, even though the live session's own DNS/internet access
  # works fine - but cdrom-only made things worse, not better: `find
  # /cdrom/pool -iname "linux-image*" -o -iname "linux-generic*" -o -iname
  # "linux-modules*" -o -iname "linux-headers*"` came back completely
  # empty. This ISO's own local package pool ships NO kernel package at
  # all - the live session's kernel is baked into the squashfs directly,
  # not exposed as an installable .deb - so a real disk install of ANY
  # kernel flavor always needs network access to fetch it from
  # noble-updates, full stop. So apt needs archive.ubuntu.com reachable.
  #
  # A LATER version of this file (still wrong, corrected below) tried to
  # fix that empty resolv.conf, plus a couple of other apt reliability
  # issues found the same way, by writing files directly into /target via
  # a top-level `write_files:` key here. That never actually worked - not
  # "worked sometimes," never worked at all - which took a full live
  # diagnostic pass to catch: `write_files` is a cloud-init user-data
  # directive that only applies on the INSTALLED system's first boot, not
  # something subiquity/curtin process during the install itself (unlike
  # `network:`/`storage:`/`identity:`/`apt:` below, which genuinely are
  # autoinstall keys curtin consumes directly). Confirmed two ways: (1) a
  # build's `subiquity-curthooks.conf` - the literal config file curtin
  # was invoked with - showed subiquity's own auto-generated write_files
  # entries (keyboard layout, machine-id, netplan) present, but zero trace
  # of our own resolv_conf/apt_retries/apt_prefer_archive entries anywhere
  # in it; (2) Canonical's own autoinstall reference and curtin's apt_source
  # docs confirm `write_files` isn't a documented autoinstall/curtin key at
  # all. So every apt-reliability "fix" attempted that way was a silent
  # no-op the whole time - the file always looked right, curtin logged
  # "Applying write_files from config." like it was doing something, and
  # none of it ever reached /target.
  #
  # The real, curtin-native mechanism for this is the `apt:` key below,
  # which IS documented as passed straight through to curtin (see the
  # kernel/no-"apt:"-override note above - this is that same key, now
  # actually used). `conf:` and `preferences:` under `apt:` are curtin's
  # own supported fields (github.com/canonical/curtin, examples/apt-
  # source.yaml) - curtin's apt_config.py renders them to real files on
  # the target at fixed, curtin-owned paths: `conf:` to
  # /etc/apt/apt.conf.d/94curtin-config, `preferences:` to
  # /etc/apt/preferences.d/90curtin.pref - and, critically, curtin applies
  # this configuration BEFORE curthooks' own package/kernel install step,
  # which is exactly the timing write_files was trying and failing to get.
  #
  # What's carried over from the old (inert) write_files entries:
  #   - apt_retries' content (Acquire::Retries/Timeout/ForceIPv4) - a real
  #     build got partway through the several-hundred-MB linux-firmware
  #     download before hitting "Error reading from server - read (104:
  #     Connection reset by peer)", and apt's default config doesn't retry
  #     a dropped connection on a large in-flight transfer.
  #   - apt_prefer_archive's content (prefer archive.ubuntu.com over
  #     security.ubuntu.com when both offer the same version) - a real
  #     build reproduced, every time, `sudo chroot /target apt-get install
  #     --download-only linux-generic` 404ing on security.ubuntu.com's copy
  #     of linux-generic/linux-image-generic while archive.ubuntu.com
  #     served the identical version fine - Ubuntu's mirrors briefly
  #     disagreeing with each other, not something apt's retry logic can
  #     fix since the file just isn't at that URL yet on any attempt. This
  #     pin doesn't remove security.ubuntu.com as a source, only breaks the
  #     tie when both origins offer the same version - real security-only
  #     updates (not yet promoted to -updates) are unaffected.
  #
  # What's NOT carried over: the resolv_conf entry. There's no equivalent
  # verified-working curtin mechanism for statically seeding /target's
  # resolv.conf ahead of curthooks (Canonical's own autoinstall reference
  # explicitly doesn't document how DNS resolution inside curtin's target
  # chroot is handled pre-boot), and since it never actually applied in
  # any build to date, dropping it changes nothing about observed
  # behavior. If a real build hits a DNS-resolution failure specifically
  # (as opposed to the 404/connection-reset issues conf/preferences below
  # target) once this is in place, that'll be new evidence pointing at an
  # actual problem with curtin's own default DNS handling, worth
  # diagnosing on its own rather than guessing at another mechanism now.
  #
  # 90curtin.pref has to persist in /target for curtin's install-kernel
  # curthook to see it - so unlike 94curtin-config (retries/timeouts are
  # fine to keep permanently), it isn't safe to leave in the finished
  # image indefinitely: permanently deprioritizing security.ubuntu.com
  # would mean a stale archive.ubuntu.com mirror could someday shadow a
  # real security fix. roles/cleanup/tasks/main.yml removes
  # /etc/apt/preferences.d/90curtin.pref as the very last step of the
  # build, so it only ever affects this one early apt run inside curtin,
  # never the shipped golden image.
  apt:
    conf: |
      Acquire::Retries "5";
      Acquire::http::Timeout "180";
      Acquire::https::Timeout "180";
      Acquire::ForceIPv4 "true";
    preferences:
      - package: "*"
        pin: 'origin "archive.ubuntu.com"'
        pin-priority: 990
      - package: "*"
        pin: 'origin "security.ubuntu.com"'
        pin-priority: 100

  # renderer: networkd - load-bearing, not a style choice. Ubuntu DESKTOP's
  # netplan default renderer is NetworkManager (Server defaults to
  # systemd-networkd), and a real build caught NetworkManager transiently
  # dropping this static config in favor of an automatic/DHCP profile right
  # around the Horizon Agent install + its own reboot: vCenter's guest-IP
  # summary showed the VM briefly holding a completely different,
  # DHCP-leased address (the pinned MAC never changed, ruling out a second
  # VM/DHCP-reservation collision) before quietly reclaiming guest_ip_cidr
  # on its own a bit later. Omnissa's Linux Horizon Agent is known to touch
  # NetworkManager for its own VDI network detection, which is the most
  # likely trigger. The self-correction is exactly what makes this so
  # disruptive rather than just cosmetic: Packer's own SSH reconnect logic
  # re-polls VMware Tools for the guest's current IP whenever a provisioner
  # step (like the reboot below) drops the connection, and if that poll
  # lands during the transient window it latches onto the wrong, short-lived
  # address - then keeps retrying that stale IP even after the guest has
  # already moved back to the correct one, which is exactly the
  # "dial tcp <wrong-ip>:22: i/o timeout" loop this surfaced as.
  # systemd-networkd applies a static config as a plain deterministic
  # service with no "automatic connection profile" fallback behavior to
  # revert to, and netplan marks a networkd-rendered device unmanaged in
  # NetworkManager so nothing else can contest it afterward.
  network:
    version: 2
    renderer: networkd
    ethernets:
      builder0:
        match:
          name: "en*"
        set-name: eth0
        # Explicit, not just implied by omission - belt-and-suspenders
        # alongside the renderer change above, so this config can never be
        # interpreted as anything other than static.
        dhcp4: false
        dhcp6: false
        addresses: ["${guest_ip_cidr}"]
        gateway4: "${guest_gateway}"
        nameservers:
          addresses: [%{ for ip in guest_dns_servers ~}"${ip}", %{ endfor ~}]

  storage:
    layout:
      name: lvm

  identity:
    hostname: "${guest_hostname}"
    username: "${build_username}"
    password: "${build_password_hash}"

  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - "${ssh_public_key}"

  packages:
    - openssh-server
    - open-vm-tools-desktop

  # Everything else - fixing the installer's 127.0.1.1 /etc/hosts entry,
  # disabling IPv6, domain join, Horizon Agent, SSSD, NFS, app installs,
  # hardening, cleanup - happens in playbook.yml once Packer's ansible
  # provisioner connects over SSH. Keeping this file to just what's needed to
  # get a reachable, up-to-date base install is what keeps it stable across
  # Ubuntu point releases; the roles in playbook.yml are easier to read, diff
  # and re-run than late-commands shell one-liners against /target.

  shutdown: reboot
