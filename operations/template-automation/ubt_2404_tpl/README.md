# ubt_2404_tpl

Packer + Ansible project that builds the Ubuntu 24.04 LTS Desktop Omnissa
Horizon instant-clone golden image, automating the manual procedure at
[Omnissa Horizon – Ubuntu 24.04 Desktop Instant Clone Template](https://tech.iot-it.no/omnissa-horizon-ubuntu-24-04-desktop-instant-clone-template/)
step for step. Assumes the shared automation platform is already set up - see
[Omnissa Horizon Golden Images – Setting Up the Automation Platform](https://tech.iot-it.no/?page_id=24914)
if not.

## Drop-in location

This whole `ubt_2404_tpl/` folder goes under `~/golden-images/images/` on the
control node, alongside `scripts/build.sh` (goes under `~/golden-images/scripts/`)
and `inventory/group_vars/ubt_2404_tpl.yml` (goes under
`~/golden-images/inventory/group_vars/`) from this same archive.

## One-time setup before the first build

1. **Stage the Horizon Agent tarball.** Omnissa gates the download behind a
   portal login, so it can't be fetched automatically - download it once per
   agent version and place it at `files/Omnissa-horizonagent-linux-x86_64-<ver>-*.tar.gz`,
   matching whatever you set `horizon_agent_tarball` to in
   `inventory/group_vars/ubt_2404_tpl.yml`.
2. **(Optional) stage the Devolutions RDM `.deb`**, if you want it in the
   image - `files/RemoteDesktopManager_*_amd64.deb`. The `apps` role skips it
   silently if it isn't there.
3. **Edit `inventory/group_vars/ubt_2404_tpl.yml`** - cluster, datastore,
   network, reserved IP, computer OU DN, NFS server/export. Every value in
   that file is a placeholder from a lab environment.
4. **Add a host group entry to the shared `inventory/hosts.ini`**:

   ```ini
   [ubt_2404_tpl]
   ubt_2404_tpl ansible_host=192.0.2.50
   ```

   Use the same IP as `guest_ip_cidr` in `group_vars/ubt_2404_tpl.yml`.
5. **Reserve that IP and a matching DNS A record** ahead of time - see the
   platform post's "One inventory, one vault" section for why, and for how to
   pre-pick a MAC address if you want the DHCP reservation to actually stick
   from the very first boot.
6. No new vault entries are needed - this project only uses
   `vault_vcenter_username`, `vault_vcenter_password`,
   `vault_linux_domain_join_password`, and `vault_local_admin_password`, all
   of which the platform's vault already has.

## Running a build

```
scripts/build.sh
```

That resolves every var (including the vault) through Ansible, checks that
`guest_hostname.domain_fqdn` already has a DNS A record pointing at
`guest_ip_cidr` (queried directly against `guest_dns_servers[0]` via `dig`,
bypassing `/etc/hosts` and any local resolver cache - falls back to the
system resolver with a warning if `dig` isn't installed), then runs
`packer init` / `packer validate` / `packer build`, and - once Packer confirms
the VM is powered off - snapshots it as `gi-ubt2404-<YYYYMMDD>`. Point the
HZUBTP1 desktop pool's snapshot at that name in Horizon Console once it's
proven out.

The DNS check exists because Packer's own HCL has no way to run a real
pre-flight check before a build starts - there's no network access in
variable validation blocks, and provisioners (even `shell-local`) only run
after the VM is already up, which for `vsphere-iso` means after the ISO has
booted and the ~20-30 minute autoinstall has already finished. Catching a
missing or stale DNS record here means failing in seconds instead of
partway through (or after) that wait - it's exactly the "reserve the IP and
create a matching DNS A record first" step from one-time setup step 5,
checked in code instead of by hand. If it fails, fix whichever of the DNS
record or `guest_ip_cidr` is wrong and re-run.

Every run's full output - the resolve step, Packer's own init/validate/build
output, and the post-build snapshot play - is also written to a timestamped
transcript under `logs/` (e.g. `logs/gi-ubt2404-20260819-143012.log`), on top
of printing to the terminal as normal. Kept per-project rather than in a
shared location, and out of git (see `.gitignore`), so a failed build can be
reviewed or handed off without having to reproduce it.

## What's deliberately different from the manual procedure

- **One final snapshot, not five.** The manual walkthrough takes an
  incremental snapshot after every step for rollback convenience during
  interactive work. A failed automated build is just deleted and re-run, so
  this project only takes the one snapshot Horizon actually needs.
- **Domain join and Horizon Agent install are two separate steps**, not one
  wizard. The manual procedure's `easyinstall_viewagent.sh` bundles both
  behind an interactive prompt with no documented unattended mode; this
  project does the domain join with `realm`/`adcli` directly (role
  `domain_join`) and installs the agent with `install_viewagent.sh`'s own
  command-line flags (role `horizon_agent`), which *is* built for
  non-interactive use.
- **No `convert_to_template`.** Horizon instant clones are built from a
  snapshot on an ordinary VM, not a vSphere template, so Packer is configured
  to just power the VM off and leave it as-is.
