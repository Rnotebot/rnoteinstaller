# Review: Tiered fallback for installer-partition detection (AtlasOS stripped WinPE)

Scope: logic/correctness review of the TIERED FALLBACK added around installer-partition
detection in `windows-setup.bat`. Not runtime-verifiable (broken terminal, needs live VPS);
per instructions I did NOT run `windows-setup.bat` or any diskpart/PE command. I read the diff,
`windows-setup.bat`, and `trans.sh` to confirm the tier-3 marker is real.

Verdict: APPROVED — no blocking findings.

---

## Evidence relied on

- `git diff HEAD -- windows-setup.bat`: the only working-tree change.
- `git diff --name-only HEAD` = `windows-setup.bat`; `git diff --cached --name-only` = empty;
  `git log origin/main..HEAD` = empty. Nothing staged, committed, or pushed — git-safety reject
  condition does not apply.
- `git show HEAD:windows-setup.bat` for the original detection block (baseline comparison).
- Byte scan: `CRLF=421, LonelyLF=0, TotalBytes=13115` — all CRLF, no lone LF.
- `grep` for `find.exe|findstr|cscript|wscript|\| find|/i "SCSI` in the file: every hit is a
  `rem` comment line or a historical commented-out command. No active banned tool remains.
- `trans.sh` lines 6886-6906: file-copy staging onto the installer partition (tier-3 marker proof).
- Coder's recorded verification note: `.agents/tasks/atlas-pe-fix-review.md` / `.json`
  (prior pass flagged Chinese/verbose comments as the only blocker; current diff uses concise
  English comments, so that blocker is resolved).

---

## Criterion-by-criterion

### (a) Three tiers in order, cmd-builtin only — PASS
- Tier 1: `echo list vol | diskpart > X:\vol.txt`; `for /f "delims="` over the file;
  delayed-expansion substring test `if not "!line: installer =!"=="!line!"`; nested
  `for /f "tokens=2"` extracts the volume index. Builtins only (`echo`, `for /f`, `if`, `set`,
  `%var:x=y%`). The pipe is INTO `diskpart` (a required present PE tool), not into `find`.
- Tier 2: guarded by `if "%VolIndex%"==""`; re-scans the same `X:\vol.txt`; substring test
  `if not "!line:installer=!"=="!line!"`, then a word loop that captures the token after the
  literal `Volume`. Builtins only.
- Tier 3: guarded by `if "%VolIndex%"==""`; `for %%d in (C D E ... Z) do if not defined T3Letter
  if exist %%d:\sources\` (pure `if exist` builtin), then maps the letter back to a volume index
  via `list vol` with `for /f "tokens=2,3"` (`%%b`=index, `%%c`=letter). Builtins only.
- No `find.exe`, `findstr.exe`, `cscript`, `wscript`, or WSH anywhere in any tier (grep-confirmed).

### (b) Tier 1 identical to current normal-Windows path — PASS
- Original: `for /f "tokens=2" %%a in ('echo list vol ^| diskpart ^| find " installer "')` →
  token 2 of the ` installer ` line = volume index; last match wins.
- Tier 1: same ` installer ` substring with identical spacing, same `for /f "tokens=2"`, same
  default delimiters, same last-match-wins. Behavior equivalent. Tiers 2 and 3 are reached only
  when `%VolIndex%` is still empty, so a normal Windows/Server ISO (which has the ` installer `
  label row) is resolved entirely by Tier 1 — no regression.

### (c) Every tier assigns the same downstream variable — PASS
- All three promote their result into `VolIndex` via `endlocal & set "VolIndex=%T1%"` /
  `%T2%` / `%T3%` (RHS expands at parse time, before `endlocal`, so the value survives).
- `VolIndex` is exactly what downstream consumes: `(echo select vol %VolIndex% & echo assign
  letter=Y) | diskpart`, the `list disk` selection, etc. Downstream is unchanged.

### (d) Final guard fires only after all three tiers — PASS
- `if "%VolIndex%"=="" ( echo Error: Cannot find installer partition. >&2  exit /b 1 )` is
  unchanged from baseline. Because tiers 2/3 are each gated on `%VolIndex%==""` and set the same
  variable, the guard trips only when all three produced nothing. No behavior change otherwise.

### (e) Tier-3 marker matches what the engine actually stages — PASS
- Marker: `if exist %%d:\sources\`.
- `trans.sh` 6886-6906 copies ISO content onto the installer partition:
  ```
  cd /iso
  find . -type f -not -iname boot.wim -not -iname install.wim \
      -not -iname install.esd -not -iname 'install*.swm' \
      -exec cp -r --parents {} /os/installer/ \;
  ```
  `cp -r --parents` preserves the ISO's directory layout under the installer mount. Only the WIM
  payloads are excluded; every other `sources\*` file (setup support files, lang resources,
  `sources\setup.exe`, etc.) is copied, so the `sources\` directory is created on the installer
  partition. The marker is real, not invented.
- Corroboration inside `windows-setup.bat` itself: the pre-existing setup-exe search already
  treats `Y:\sources\setup.exe` (installer partition = Y) as an expected path, confirming the
  engine stages `sources\` there.
- `source_install_wim` (typically `sources/install.wim`) is excluded, but that only removes the
  one WIM file; the directory still exists because of the other copied `sources\` files.

### (f) CRLF line endings retained — PASS
- Byte scan: `CRLF=421, LonelyLF=0`. No LF-only lines introduced.

### (g) Protected paths untouched — PASS
- `git diff --name-only HEAD` = `windows-setup.bat` only. The dd path, VirtIO offline injection,
  hivex merge, `windows.xml`, and Server unattend/EMS flow live in `trans.sh` / `windows.xml`,
  which are unmodified. The unattend/EMS logic inside `windows-setup.bat` is not touched by the diff.

### (h) Change stays small, comments minimal — PASS
- The tiered block is compact and each added comment is one concise English line of rationale.
  The prior-pass blocker (Chinese/verbose comments) is resolved in the current diff.

### Git safety — PASS
- Nothing staged, committed, or pushed (working-tree change only). Reject-on-commit/push does not apply.

---

## Notes (non-blocking, not filed as findings)

- The same diff also swaps the main-disk producer (`| find "* "` removed), the EFI/BIOS detector
  (`| find " efi "` -> substring scan), `:sleep` (WSH -> `ping` loopback wait), and
  `:drvload_if_scsi` (`find /i "SCSIAdapter"` -> builtin substring scan). These are part of the
  same approved AtlasOS PE fix, each replaces a banned external tool with a cmd builtin, none
  touch protected paths, and none introduce a reachable correctness/security/data defect. They
  are outside the narrow tiered-fallback scope of this step but were checked and are clean.
- Tier 3 omits drive letter `X` (the PE RAM drive), which is correct. If `sources\` is found but
  no matching volume row exists, `T3` stays empty and control falls through to the guard — safe.
