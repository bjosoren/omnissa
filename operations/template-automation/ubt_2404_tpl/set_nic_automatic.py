#!/usr/bin/env python3
"""
set_nic_automatic.py - invoked by post_build_snapshot.yml (see the task
"Flip the published clone's inherited NIC to Automatic MAC" there) as the
last step of getting the published clone off vm_name's pinned MAC.

Flips an existing VM's first Ethernet adapter from Manual to Automatic MAC
address type via a SINGLE in-place reconfigure of that same device - the
same operation as vCenter's Edit Settings "MAC Address: Automatic"
dropdown. This replaced an earlier two-task delete-then-recreate approach
(via community.vmware.vmware_guest_network) that, per that module's own
docs, should have produced the same result but in real-world testing did
not: both tasks reported success, yet Edit Settings kept showing the
adapter as Manual with the clone's inherited (pinned) MAC, and Horizon's
instant-clone forking kept handing every spawned VDI that same MAC/IP
identity as a result. A real, confirmed fix - manually flipping the
dropdown to Automatic in vCenter's UI - was traced to a single in-place
reconfigure of the existing device, not a remove/re-add, which this script
reproduces directly via pyVmomi rather than through vmware_guest_network
(which has no equivalent "reset this adapter to auto-generated" option).

Note: the vSphere API reports the result back as addressType='assigned'
rather than 'generated' - both are vCenter-generated (not user-pinned)
addresses and both display identically as "Automatic" in the vSphere
Client; 'assigned' is simply what a vCenter-managed VM gets since vCenter,
not the ESXi host, is doing the allocating. Confirmed directly: Edit
Settings on the fixed VM shows "Automatic", same as the working manual fix.

Also forces connectable.startConnected (Edit Settings' "Connect At Power
On") to True on the same device, in the same reconfigure. Nothing in this
project ever explicitly sets that field - not here, not in playbook.yml,
not in any role - so its being unchecked on the published clone traces
back to the clone task itself: community.vmware.vmware_guest's clone path,
given a bare `networks: [{name: ...}]` with no connected/start_connected
key, doesn't appear to carry over the source adapter's true value. Left
unfixed, every VDI Horizon forks from this VM would inherit a NIC that's
disconnected at boot - a real image, right MAC and all, that still can't
reach the network. Setting connected the same way as addressType (a direct
field edit on the live device object, not a rebuilt one) means every other
property of the adapter - including this one, if it's ever fixed upstream
in the clone task - keeps flowing through untouched.

Reads connection details from environment variables (not argv) so nothing
sensitive ends up in `ps` output:
  VC_HOST, VC_USER, VC_PASSWORD, VC_VM_NAME
"""
import os
import ssl
import sys
import time

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def find_vm_by_name(content, name):
    view = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True
    )
    try:
        for vm in view.view:
            if vm.name == name:
                return vm
    finally:
        view.Destroy()
    return None


def main():
    host = os.environ["VC_HOST"]
    user = os.environ["VC_USER"]
    password = os.environ["VC_PASSWORD"]
    vm_name = os.environ["VC_VM_NAME"]

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    si = SmartConnect(host=host, user=user, pwd=password, sslContext=ctx)
    try:
        content = si.RetrieveContent()
        vm = find_vm_by_name(content, vm_name)
        if vm is None:
            print(f"ERROR: no VM named {vm_name!r} found", file=sys.stderr)
            sys.exit(1)

        nic = None
        for device in vm.config.hardware.device:
            if isinstance(device, vim.vm.device.VirtualEthernetCard):
                nic = device
                break

        if nic is None:
            print(f"ERROR: {vm_name!r} has no Ethernet adapter", file=sys.stderr)
            sys.exit(1)

        start_connected_before = (
            nic.connectable.startConnected if nic.connectable is not None else None
        )
        print(f"Found {nic.deviceInfo.label} on {vm_name} - current "
              f"addressType={nic.addressType!r} macAddress={nic.macAddress!r} "
              f"startConnected={start_connected_before!r}")

        nic.addressType = "generated"
        nic.macAddress = ""

        if nic.connectable is None:
            # No connectable block at all is unusual but not impossible -
            # build a minimal one rather than assume it exists.
            nic.connectable = vim.vm.device.VirtualDevice.ConnectInfo()
        nic.connectable.startConnected = True
        # Deliberately not touching .connected here - that's the LIVE
        # runtime connection state, meaningless (and not reliably settable)
        # on a VM that's powered off, which this one always is at this
        # point in the pipeline. startConnected is what actually persists
        # and is what Edit Settings' "Connect At Power On" reflects.

        spec = vim.vm.ConfigSpec()
        dev_spec = vim.vm.device.VirtualDeviceSpec()
        dev_spec.operation = vim.vm.device.VirtualDeviceSpec.Operation.edit
        dev_spec.device = nic
        spec.deviceChange = [dev_spec]

        task = vm.ReconfigVM_Task(spec=spec)
        while task.info.state in (vim.TaskInfo.State.running, vim.TaskInfo.State.queued):
            time.sleep(1)

        if task.info.state == vim.TaskInfo.State.error:
            print(f"ERROR: reconfigure failed: {task.info.error.msg}", file=sys.stderr)
            sys.exit(1)

        vm.Reload()
        for device in vm.config.hardware.device:
            if isinstance(device, vim.vm.device.VirtualEthernetCard):
                after_start_connected = (
                    device.connectable.startConnected
                    if device.connectable is not None else None
                )
                print(f"After reconfigure - addressType={device.addressType!r} "
                      f"macAddress={device.macAddress!r} "
                      f"startConnected={after_start_connected!r}")
                break

        print("Done.")
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
