# Per-VM overrides

Optional. A file here named `<vm>.conf` is sourced after everything has been
derived for that VM, so it can override anything in `config/omavm.conf` for
that VM alone. Most VMs need no file at all.

It is plain shell, sourced by `manage-agent-vm.sh`.

```bash
# config/vm/api.conf — a heavier VM for a build-intensive project
VM_MEM_MB="10240"
VM_VCPUS="6"
```

Things worth overriding here, and nothing else:

| Setting | Effect |
|---|---|
| `VM_MEM_MB`, `VM_VCPUS` | Sizing for this VM |
| `VIDEO_WIDTH`, `VIDEO_HEIGHT` | A different viewport for this VM |
| `SHARE_DIR` | A share somewhere other than `$SHARE_ROOT/<vm>` |
| `SHARE_READONLY` | Make this VM's share read-only |
| `ACCEL3D`, `GL_ENABLE` | Turn 3D off for this VM after a mesa breakage |

**Do not set the address, MAC or disk paths here.** They are derived from the
DHCP reservation, which is the registry of which VMs exist. Overriding them
would make the script and libvirt disagree about what this VM is.
