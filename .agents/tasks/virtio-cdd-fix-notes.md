# VirtIO offline CriticalDeviceDatabase parent-key fix — verification notes

## Problem
On debloated images (AtlasOS) the offline VirtIO injection aborted the install at
the registry merge step:

```
reg_import: cannot create \ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000
since parent \ControlSet001\Control\CriticalDeviceDatabase\ does not exist
at /usr/lib/perl5/vendor_perl/Win/Hivex/Regedit.pm line 342
Line 0416 return 255
hivexregedit --merge "$to_system_hive" "$reg"
```

AtlasOS strips `CriticalDeviceDatabase`. `Win::Hivex::Regedit` does not auto-create
intermediate parent keys, so the first `pci#ven_...` child insert failed with
return 255 and dropped back to Alpine. The driver files copied fine; only the hive
merge failed.

## Change (file: trans.sh, function add_driver_virtio_offline)
Additive only. In the heredoc that authors `/os/drivers/virtio-offline/system.reg`,
I prepended empty parent-key stanzas before the first `CriticalDeviceDatabase` child
entry. The file uses the hive-relative key form (`[\ControlSet001\...]`), not the
`HKEY_LOCAL_MACHINE\SYSTEM\...` prefix form, so the parent declarations match that
existing style — this is exactly the path form the error message reported.

### Before (ordering)
```
[\ControlSet001\Services\viostor]
... values ...
"ImagePath"="system32\\drivers\\viostor.sys"

[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000]   <-- parent missing on Atlas
```

### After (ordering)
```
[\ControlSet001\Services\viostor]
... values ...
"ImagePath"="system32\\drivers\\viostor.sys"

; Ensure the CriticalDeviceDatabase parent chain exists. (comment)
[\ControlSet001\Control]                                    <-- parent-chain declaration
[\ControlSet001\Control\CriticalDeviceDatabase]             <-- the confirmed-missing parent
[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000]
```

The two new stanzas are empty keys (no value lines). An empty `[...]` stanza makes
`Win::Hivex::Regedit` call `_merge_node`, which ensures the key exists. Declaring a
key that already exists is idempotent, so NORMAL images are unaffected.

## Verification (a) parent declared before child
Confirmed: `[\ControlSet001\Control\CriticalDeviceDatabase]` now appears on its own
line BEFORE `[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000]`.
`[\ControlSet001\Control]` is declared before that, so the full chain is guaranteed.
hivexregedit --merge will no longer hit "parent ... does not exist".

## Verification (b) all other child keys have their parent chain
Every `[...]` stanza authored in the .reg, with its required parent:
- `[\ControlSet001\Services\viostor]` — parent `\ControlSet001\Services` (core boot
  services key; present on every bootable Windows image incl. Atlas).
- `[\ControlSet001\Control]` — now explicitly declared (parent `\ControlSet001` always
  exists; it is the active control set root).
- `[\ControlSet001\Control\CriticalDeviceDatabase]` — now explicitly declared.
- `[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000]`
- `[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00020000]`
- `[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00021af4]`
  — all three now have their declared `CriticalDeviceDatabase` parent.
- `[\ControlSet001\Services\netkvm]` — parent `\ControlSet001\Services` (same as viostor).

`\ControlSet001\Services` is where viostor itself (a boot-critical storage driver) is
being registered; the storage stack cannot boot without that key, so it is present on
any usable image. `CriticalDeviceDatabase` was the one confirmed-stripped key; its
parent chain is now prepended. No other authored child has a plausibly-missing parent.

## Verification (c) value lines unchanged
Confirmed byte-identical to before:
- viostor `"Start"=dword:00000000` (boot-start) and `"Type"`, `"Group"`,
  `"ErrorControl"` unchanged.
- viostor `"ImagePath"="system32\\drivers\\viostor.sys"` — doubled backslashes intact
  (prior fix preserved).
- netkvm `"Start"=dword:00000003`, `"ImagePath"="system32\\drivers\\netkvm.sys"` —
  doubled backslashes intact.
- CriticalDeviceDatabase service mappings (`"Service"="viostor"`, ClassGUID) unchanged.
Only empty parent-key stanzas and one comment block were added.

## Verification (d) Server path untouched
The injection remains guarded by `[ "$windows_type" = client ] && [ -d /os/os-drivers ]`
around the `add_driver_virtio_offline` call. Only the heredoc inside that function was
edited. The Server path / boot.wim DriverPaths flow and the dd path were not touched.
No autounattend-into-ISO reintroduced.

## Parser confirmation
Checked Win/Hivex/Regedit.pm reg_import logic:
- In `outer` state it skips `/^\s*(;.*)?$/` (blank + semicolon comment) and `/^\s*;/`,
  so the added `;` comment lines and blank lines are safely ignored.
- An empty `[...]` stanza transitions to `inner`; the following blank line matches
  `/^\s*(;.*)?$/` which calls `_merge_node`, creating/ensuring the key. This is the
  mechanism that makes the parent declaration work.

## Syntax check
`bash -n trans.sh` -> exit 0 (clean). `dash` is not installed on this host, so only
bash's POSIX-mode parse was run; it passed. (The terminal was functional here, so a
syntax check was possible despite the task noting it might not be.)

## Git
Left uncommitted per instructions. No git add/commit/push performed.
