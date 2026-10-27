# Revert erroneous SetupUILanguage block from windowsPE Setup component

A previously-added `<SetupUILanguage>` block (with a nested `<UILanguage>%locale%</UILanguage>`) and its explanatory comment were removed from the `Microsoft-Windows-Setup` component in the `windowsPE` pass of `windows.xml`. That block was rejected by Windows Setup on both Windows Server 2019 (official MS ISO) and AtlasOS with "Windows could not parse or process unattend answer file ... A component or setting specified in the answer file does not exist." `SetupUILanguage` is not a valid child of this component in these images, so its presence failed answer-file validation for the whole `windowsPE` pass. The revert restores the component to the upstream (bin456789/reinstall) known-good shape, while the `Microsoft-Windows-International-Core-WinPE` component and the `trans.sh` en-US locale hardening that feeds it are left untouched.

Watch for: nothing blocking. The deletion is exactly the four lines it should be, the file remains well-formed, and the language path for both OSes is preserved through International-Core-WinPE (confirmed).

**Verdict**: APPROVED

## High-level view

The failure was an answer-file schema violation, not a locale-value problem. Windows Setup validates every element in a pass against the component schema before processing it; an element the component does not define aborts the entire pass with the "does not exist" parse error. The reverted `SetupUILanguage` block was that invalid element, and removing it is the correct, minimal fix for both the Server 2019 and AtlasOS regressions.

The language configuration both OSes actually rely on lives in the separate `Microsoft-Windows-International-Core-WinPE` component, which still sets `InputLocale`, `SystemLocale`, `UILanguage`, and `UserLocale` all to `%locale%`. That value is hardened upstream in `trans.sh` (trim CR/whitespace, validate as a language tag, fall back to `en-US`), so Atlas repacks with missing Default Language metadata still receive a valid language. None of that was touched.

The change is confined to one file and one hunk: four contiguous lines deleted, zero added, no reflow, no reindent, no line-ending change. Every other protected area (dd path, VirtIO offline injection, hivexregedit CriticalDeviceDatabase fix, windows-setup.bat PE fixes, the trans.sh fallback) is outside the diff entirely.

<details>
<summary>Issues (0)</summary>

No blocking or non-blocking action items. All review criteria (a)-(e) verified.

</details>

<details>
<summary>Details</summary>

### The deleted block and why it broke Setup (confirmed)

The removed lines were:

```xml
<!-- Explicit Setup UI language (same %locale% as International-Core, with trans.sh en-US fallback) -->
<SetupUILanguage>
    <UILanguage>%locale%</UILanguage>
</SetupUILanguage>
```

These sat at the top of the `Microsoft-Windows-Setup` component in `windowsPE`. Windows Setup validates each pass's answer-file elements against the component schema up front; an element the component's schema does not accept fails validation for the whole pass, producing exactly the reported "A component or setting specified in the answer file does not exist" error. That is why both a clean Server 2019 ISO and an AtlasOS repack failed identically — the trigger was schema shape, independent of what `%locale%` resolved to. Deleting the block removes the offending element.

### Matches upstream known-good shape (confirmed)

Upstream `windows.xml` (bin456789/reinstall, `main`) was reachable and fetched. Its `Microsoft-Windows-Setup` component opens directly with the `<!-- 安装过程可节省一点内存... -->` comment followed by `<EnableFirewall>false</EnableFirewall>` and carries no `<SetupUILanguage>`. The reverted local file now opens the same way. Criterion (a) holds against the actual upstream source, not just inference.

### Language path preserved via International-Core-WinPE (confirmed)

The adjacent `Microsoft-Windows-International-Core-WinPE` component is unchanged and still carries all four tags set to `%locale%`:

```xml
<InputLocale>%locale%</InputLocale>
<SystemLocale>%locale%</SystemLocale>
<UILanguage>%locale%</UILanguage>
<UserLocale>%locale%</UserLocale>
```

`%locale%` is substituted by the `trans.sh` sed at the region around line 8160, fed by the hardened value computed at ~8137-8155 (trim CR/newlines/tabs, keep first token, validate as a language tag, else fall back to `en-US`). So AtlasOS repacks whose `install.wim` lacks Default Language metadata still get a valid `en-US`, and the UI language is still set for WinPE — just through the correct component. Criterion (c) holds. Note the deleted `SetupUILanguage` was redundant with this component's `UILanguage` even if it had been schema-valid.

### Edit is minimal and isolated (confirmed)

`git diff` for the working tree is `windows.xml | 4 ----`, one file, four deletions, zero insertions. `git diff --check` reports no whitespace errors. The file is consistently CRLF (181 CRLF line terminators, 0 bare LF) with no mixing introduced. `trans.sh` and `windows-setup.bat` show no pending changes, so the dd path, VirtIO offline injection, hivexregedit CriticalDeviceDatabase fix, windows-setup.bat PE fixes, and the trans.sh locale fallback are all outside this diff. Criteria (d) and (e) hold.

### XML well-formedness (confirmed)

Non-mutating parse via `[xml]` succeeded; document element is `unattend`. The removal did not leave a dangling tag or unbalanced element. Criterion (b) holds.

</details>

<details>
<summary>File map</summary>

- `windows.xml` — removed the invalid `<SetupUILanguage>` block and its comment from the `windowsPE` `Microsoft-Windows-Setup` component (4-line deletion). Full diff: `git diff HEAD -- windows.xml`.

</details>
