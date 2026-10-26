# Review — VirtIO offline CriticalDeviceDatabase parent-key fix

Scope: single uncommitted change to `trans.sh`, function `add_driver_virtio_offline()`.

## Evidence base
- Diff: `git diff -- trans.sh` → 1 hunk, `@@ -8394,6 +8394,14 @@`, 8 insertions, 0 deletions.
- Source: read `trans.sh` lines ~8360-8460 (the full function and its call guard).
- Coder note: `.agents/tasks/virtio-cdd-fix-notes.md` (bash -n exit 0; terminal was functional for the coder).
- Did not re-run syntax check / build per instruction; fix is not runtime-verifiable without a live VPS.

## The change
Inside the `cat <<'EOF' >"$reg"` heredoc, after the viostor service stanza and before
the first CriticalDeviceDatabase child, the coder inserted:

```
; (4-line English comment)
[\ControlSet001\Control]

[\ControlSet001\Control\CriticalDeviceDatabase]

```

Purely additive — the diff contains zero deletions.

## Findings against required checks

1. Parent before child — PASS. `[\ControlSet001\Control\CriticalDeviceDatabase]` is
   declared on its own line (empty stanza) before
   `[\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000]`.
   `[\ControlSet001\Control]` is declared before that, completing the chain. The .reg
   uses hive-relative key form (`[\ControlSet001\...]`), which matches the merge target
   (`hivexregedit --merge "$to_system_hive"`) and exactly the path the error reported.
   This removes the "parent ... does not exist" abort on stripped (Atlas) images.

2. Every other child key's parent chain present — PASS.
   - `[\ControlSet001\Services\viostor]`, `[\ControlSet001\Services\netkvm]`: parent
     `\ControlSet001\Services` is the boot-critical services root, present on any
     bootable Windows image (viostor itself is being registered there).
   - `[\ControlSet001\Control]`: parent `\ControlSet001` is the active control set root,
     always present. Now explicitly declared anyway.
   - The three `pci#ven_1af4&dev_1001&subsys_*` children: parent
     `CriticalDeviceDatabase` is now declared ahead of them.
   No authored child has a plausibly-missing, undeclared parent.

3. Value lines unchanged / byte-identical — PASS. Diff shows 0 deletions. Confirmed in
   source: viostor `"Start"=dword:00000000` (boot-start), `"ImagePath"="system32\\drivers\\viostor.sys"`
   with doubled backslashes intact; netkvm `"Start"=dword:00000003`,
   `"ImagePath"="system32\\drivers\\netkvm.sys"` doubled backslashes intact; the three
   CriticalDeviceDatabase `"Service"="viostor"` / ClassGUID mappings unchanged. Change is
   additive (two empty key stanzas + one comment block) only.

4. Idempotent on normal images — PASS. An empty `[...]` stanza instructs
   Win::Hivex::Regedit to ensure the key exists; declaring an already-present key is a
   no-op. Normal images are unaffected.

5. Server path / boot.wim DriverPaths byte-identical — PASS. The call is guarded by
   `if [ "$windows_type" = client ] && [ -d /os/os-drivers ]; then add_driver_virtio_offline; fi`.
   The single-hunk diff confirms nothing outside this heredoc changed, so the Server
   path is untouched.

6. dd path / autounattend-into-ISO — PASS. No dd-path change; the dormant
   `if false` autounattend branch is untouched; single hunk confirms no reintroduction.

7. New comments minimal and English only — PASS. One 4-line `;` comment, English.

## Verdict
No blocking findings. APPROVED.
