#!/usr/bin/env python3
"""
Replace a VM's network adapter with one using an automatic MAC, on the same
port group, connected at power-on. Called by post_build_snapshot.yml on the
build VM before it is cloned, so a pinned build MAC never reaches the
published clone.

Environment: VC_HOST, VC_USER, VC_PASSWORD, VC_VM_NAME
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

def backing_for_same_network(old_backing):
    """Build a fresh backing object pointing at the same network the
    existing adapter was using, whether that's a standard portgroup or a
    distributed one. Raises if the existing backing type isn't one of
    those two, rather than guessing."""
    if isinstance(old_backing, vim.vm.device.VirtualEthernetCard.NetworkBackingInfo):
        new_backing = vim.vm.device.VirtualEthernetCard.NetworkBackingInfo()
        new_backing.deviceName = old_backing.deviceName
        new_backing.network = old_backing.network
        return new_backing, old_backing.deviceName

    if isinstance(old_backing, vim.vm.device.VirtualEthernetCard.DistributedVirtualPortBackingInfo):
        new_backing = vim.vm.device.VirtualEthernetCard.DistributedVirtualPortBackingInfo()
        new_backing.port = vim.dvs.PortConnection()
        new_backing.port.portgroupKey = old_backing.port.portgroupKey
        new_backing.port.switchUuid = old_backing.port.switchUuid
        return new_backing, f"dvportgroup {old_backing.port.portgroupKey!r}"

    raise TypeError(
        f"existing adapter's backing is {type(old_backing).__name__!r} - "
        "neither a standard portgroup nor a distributed portgroup, don't "
        "know how to carry this network forward safely"
    )

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

        old_nic = None
        for device in vm.config.hardware.device:
            if isinstance(device, vim.vm.device.VirtualEthernetCard):
                old_nic = device
                break

        if old_nic is None:
            print(f"ERROR: {vm_name!r} has no Ethernet adapter", file=sys.stderr)
            sys.exit(1)

        old_start_connected = (
            old_nic.connectable.startConnected if old_nic.connectable is not None else None
        )
        print(f"Found {old_nic.deviceInfo.label} on {vm_name} - current "
              f"type={type(old_nic).__name__} addressType={old_nic.addressType!r} "
              f"macAddress={old_nic.macAddress!r} startConnected={old_start_connected!r}")

        new_backing, network_desc = backing_for_same_network(old_nic.backing)
        print(f"Carrying network forward unchanged: {network_desc}")

        new_nic = vim.vm.device.VirtualVmxnet3()
        new_nic.backing = new_backing
        new_nic.addressType = "generated"
        new_nic.wakeOnLanEnabled = True
        new_nic.connectable = vim.vm.device.VirtualDevice.ConnectInfo()
        new_nic.connectable.startConnected = True
        new_nic.connectable.allowGuestControl = True
        new_nic.connectable.connected = False
        new_nic.deviceInfo = vim.Description()
        new_nic.deviceInfo.label = old_nic.deviceInfo.label
        new_nic.deviceInfo.summary = network_desc
        new_nic.key = -1

        remove_spec = vim.vm.device.VirtualDeviceSpec()
        remove_spec.operation = vim.vm.device.VirtualDeviceSpec.Operation.remove
        remove_spec.device = old_nic

        add_spec = vim.vm.device.VirtualDeviceSpec()
        add_spec.operation = vim.vm.device.VirtualDeviceSpec.Operation.add
        add_spec.device = new_nic

        spec = vim.vm.ConfigSpec()
        spec.deviceChange = [remove_spec, add_spec]

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
                print(f"After reconfigure - type={type(device).__name__} "
                      f"addressType={device.addressType!r} macAddress={device.macAddress!r} "
                      f"startConnected={after_start_connected!r}")
                break

        print("Done.")
    finally:
        Disconnect(si)

if __name__ == "__main__":
    main()
