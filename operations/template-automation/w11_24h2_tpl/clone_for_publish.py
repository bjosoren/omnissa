#!/usr/bin/env python3
"""
Clone the build VM (VC_SOURCE_VM) to the published VM (VC_TARGET_VM).
Called by post_build_snapshot.yml.

A plain clone - no network override, no customization spec. Cloning with a
customization/network spec made Horizon's instant-clone push fail with
AGENT_CUSTOMIZATION_FAULT.

Environment (not argv, so nothing sensitive shows in `ps`):
  VC_HOST, VC_USER, VC_PASSWORD, VC_SOURCE_VM, VC_TARGET_VM,
  VC_DATACENTER, VC_CLUSTER, VC_DATASTORE,
  VC_FOLDER_PATH  - slash-separated, e.g. "EUC/Desktops/HZ-Templates"
"""
import os
import ssl
import sys
import time

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

def find_in_container(content, root, vimtype, name):
    view = content.viewManager.CreateContainerView(root, [vimtype], True)
    try:
        for obj in view.view:
            if obj.name == name:
                return obj
    finally:
        view.Destroy()
    return None

def resolve_folder(datacenter, folder_path):
    """Walk datacenter.vmFolder down a slash-separated path of child folder
    names, e.g. "EUC/Desktops/HZ-Templates". Raises if any segment isn't
    found, rather than silently falling back to the root vm folder."""
    current = datacenter.vmFolder
    if not folder_path:
        return current

    for segment in folder_path.strip("/").split("/"):
        match = None
        for child in current.childEntity:
            if isinstance(child, vim.Folder) and child.name == segment:
                match = child
                break
        if match is None:
            raise LookupError(
                f"folder segment {segment!r} not found under "
                f"{current.name!r} while resolving path {folder_path!r}"
            )
        current = match

    return current

def main():
    host = os.environ["VC_HOST"]
    user = os.environ["VC_USER"]
    password = os.environ["VC_PASSWORD"]
    source_vm_name = os.environ["VC_SOURCE_VM"]
    target_vm_name = os.environ["VC_TARGET_VM"]
    datacenter_name = os.environ["VC_DATACENTER"]
    cluster_name = os.environ["VC_CLUSTER"]
    datastore_name = os.environ["VC_DATASTORE"]
    folder_path = os.environ.get("VC_FOLDER_PATH", "")

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    si = SmartConnect(host=host, user=user, pwd=password, sslContext=ctx)
    try:
        content = si.RetrieveContent()

        datacenter = find_in_container(
            content, content.rootFolder, vim.Datacenter, datacenter_name
        )
        if datacenter is None:
            print(f"ERROR: no datacenter named {datacenter_name!r} found", file=sys.stderr)
            sys.exit(1)

        source_vm = find_in_container(
            content, datacenter.vmFolder, vim.VirtualMachine, source_vm_name
        )
        if source_vm is None:
            print(f"ERROR: no source VM named {source_vm_name!r} found", file=sys.stderr)
            sys.exit(1)

        existing_target = find_in_container(
            content, datacenter.vmFolder, vim.VirtualMachine, target_vm_name
        )
        if existing_target is not None:
            print(f"ERROR: a VM named {target_vm_name!r} already exists - "
                  "refusing to clone over it", file=sys.stderr)
            sys.exit(1)

        cluster = find_in_container(
            content, datacenter.hostFolder, vim.ClusterComputeResource, cluster_name
        )
        if cluster is None:
            print(f"ERROR: no cluster named {cluster_name!r} found", file=sys.stderr)
            sys.exit(1)

        datastore = find_in_container(
            content, datacenter.datastoreFolder, vim.Datastore, datastore_name
        )
        if datastore is None:
            print(f"ERROR: no datastore named {datastore_name!r} found", file=sys.stderr)
            sys.exit(1)

        target_folder = resolve_folder(datacenter, folder_path)

        print(f"Cloning {source_vm_name!r} -> {target_vm_name!r} "
              f"(cluster={cluster_name!r} datastore={datastore_name!r} "
              f"folder={folder_path or '<datacenter vm folder root>'!r})")

        relocate_spec = vim.vm.RelocateSpec()
        relocate_spec.datastore = datastore
        relocate_spec.pool = cluster.resourcePool

        clone_spec = vim.vm.CloneSpec()
        clone_spec.location = relocate_spec
        clone_spec.powerOn = False
        clone_spec.template = False

        task = source_vm.CloneVM_Task(
            folder=target_folder, name=target_vm_name, spec=clone_spec
        )
        while task.info.state in (vim.TaskInfo.State.running, vim.TaskInfo.State.queued):
            time.sleep(2)

        if task.info.state == vim.TaskInfo.State.error:
            print(f"ERROR: clone failed: {task.info.error.msg}", file=sys.stderr)
            sys.exit(1)

        new_vm = task.info.result
        print(f"Clone task completed - new VM {new_vm.name!r} "
              f"(moref={new_vm._moId})")
        print("Done.")
    finally:
        Disconnect(si)

if __name__ == "__main__":
    main()
