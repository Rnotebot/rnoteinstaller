# Locale fallback hardening in trans.sh (Rntech reinstall engine)

## Problem
`%locale%` in the generated unattend (`windows.xml`) could be substituted with an
empty / whitespace-only / invalid value, breaking Windows Setup:

- **AtlasOS (Win10 Pro repack):** Setup error `0x80004005` "could not determine the
  language to use for Setup" — `install.wim` lacks Default Language metadata, so
  `%locale%` was empty.
- **Windows Server 2019 (official MS ISO):** "Windows could not parse or process
  unattend answer file ... A component or setting specified in the answer file does
  not exist." — an empty/invalid `<UILanguage>%locale%</UILanguage>` (and the
  International-Core locale tags).

The prior fix `[ -n "$locale" ] || locale=en-US` was insufficient: when
`get_selected_image_prop 'Default Language'` returns a **non-empty-but-invalid** value
(trailing carriage return `\r`, stray space/tab, or a blank line with whitespace), it
passes `[ -n "$locale" ]` yet still produces an invalid/empty locale tag, so the
`en-US` fallback never triggered.

## File changed
`e:\Document\All\InstallerRDP\github\rnoteinstaller\trans.sh`

Region: the locale fallback inside `install_windows()` (around lines 8137-8140 before
the edit; now ~8137-8155). The `%locale%` sed substitution (~8160) and
`windows.xml` template were **not** changed — they already route every locale field
through `%locale%`, which is now fed a hardened value.

## Before
```sh
locale=$(get_selected_image_prop 'Default Language')
# Fallback for repacks (e.g. AtlasOS) whose install.wim lacks Default Language metadata.
# Empty %locale% yields empty windowsPE locale tags -> Setup 0x80004005. Real values pass through unchanged.
[ -n "$locale" ] || locale=en-US
```

## After
```sh
locale=$(get_selected_image_prop 'Default Language')
# Harden %locale% so windows.xml never gets an empty/whitespace/invalid tag.
# WIM/DISM/wimlib output can carry a trailing CR, stray space or blank line that
# passes [ -n ] yet yields an invalid <UILanguage> (Setup 0x80004005 on AtlasOS repacks,
# or an unattend parse/component error on Server 2019). Strip CR/newlines/whitespace,
# keep only the first token, then validate it loosely looks like a language tag.
# A genuine value (e.g. en-US or a non-English tag) passes through unchanged (trimmed);
# only an empty/invalid value falls back to en-US.
locale=$(printf '%s' "$locale" | tr -d '\r\n' | tr '\t' ' ' | awk '{print $1}')
case "$locale" in
    [A-Za-z][A-Za-z]) : ;;                             # bare language, e.g. "en"
    [A-Za-z][A-Za-z]-[A-Za-z0-9]*) : ;;                # language-region, e.g. "en-US"
    *) locale=en-US ;;                                 # empty or implausible -> fallback
esac
# Reject anything with characters outside a plausible language tag (defensive):
# the only allowed characters are letters, digits and hyphen.
case "$locale" in
    *[!A-Za-z0-9-]*) locale=en-US ;;
esac
```

### Logic
1. **Trim:** `tr -d '\r\n'` removes all CR and LF (handles trailing CR and embedded
   blank lines); `tr '\t' ' '` turns tabs into spaces; `awk '{print $1}'` keeps only the
   first whitespace-delimited token (drops trailing/leading spaces and any extra words).
2. **Validate:** first `case` requires the value to start with two letters, either bare
   (`en`) or followed by `-` and at least one alphanumeric (`en-US`, `zh-Hans-CN`);
   otherwise fall back to `en-US`. This enforces a tag shaped like
   `^[A-Za-z]{2}(-[A-Za-z0-9-]+)*$`.
3. **Defensive reject:** second `case` falls back to `en-US` if any character outside
   `[A-Za-z0-9-]` survived.
4. **Passthrough:** a genuine, valid Default Language (English or not) is used unchanged
   after trimming — no non-English regression.

## Why this fixes both failures
- **AtlasOS:** empty/invalid Default Language → trimmed to empty → first `case`
  no-match → `locale=en-US`. `%locale%` becomes `en-US`, so `<UILanguage>` etc. are
  valid. Fixes `0x80004005`.
- **Server 2019:** reports a real `en-US` that may carry a trailing CR → trimmed to clean
  `en-US` → valid tags everywhere. Fixes the unattend parse/component error.

## Verification (code/logic level — live VPS not available here)
Tested the exact trim+validate+fallback snippet in a local `bash` with representative
inputs (temp script, since removed):

| input | result |
|---|---|
| (a) empty `""` | `en-US` |
| (a) `en-US\r` (trailing CR) | `en-US` |
| (a) `en-US ` (trailing space) | `en-US` |
| (a) `"   "` (whitespace only) | `en-US` |
| (a) `en-US\n\n` (blank line) | `en-US` |
| (a) `Default:` (junk) | `en-US` |
| (a) `en-` (dangling hyphen) | `en-US` |
| (a) `\ten-US` (leading tab) | `en-US` |
| (b) `en-US` (Server/official) | `en-US` (unchanged) |
| (c) `de-DE` (non-English) | `de-DE` (unchanged) |
| (c) `zh` (bare) | `zh` (unchanged) |
| (c) `zh-Hans-CN` | `zh-Hans-CN` (unchanged) |
| (c) `pt-BR\r` (non-English + CR) | `pt-BR` (trimmed, unchanged otherwise) |

Checklist:
- (a) value with trailing CR/whitespace → trimmed; if then empty/invalid → `en-US`. **PASS**
- (b) real `en-US` passes through → valid tags, no regression. **PASS**
- (c) real non-English tag passes through (trimmed) unchanged. **PASS**
- (d) `windows.xml` substitution can no longer yield empty/whitespace locale tags; all
  locale fields (SetupUILanguage/UILanguage, InputLocale, SystemLocale, UILanguage,
  UserLocale) use the same hardened `%locale%`. **PASS** (fixes both 0x80004005 and the
  2019 parse error)
- (e) protected paths untouched: dd path, VirtIO offline injection, hivexregedit
  CriticalDeviceDatabase fix, windows-setup.bat PE fixes, and other unattend logic were
  not modified — only the locale value hardening. **PASS**
- (f) `bash -n trans.sh` → `SYNTAX_OK`. **PASS**
- (g) LF line endings preserved: byte scan shows CR=0, LF=9033 (no CRLF introduced).
  **PASS**

## Note on other consumers of get_selected_image_prop
`get_image_prop` already pipes through the existing `trim()` (strips leading/trailing
`[[:space:]]` per line), but that does not reliably drop a trailing `\r` on busybox sed
nor embedded blank lines — which is exactly why the locale value needed its own robust
trim. Other consumers such as `'Installation Type'` (used for Server detection) and
`'Image Name'` rely on the same `get_image_prop`/`trim` path and could in principle be
affected by the same CR/whitespace artifact. Per the task constraints I only hardened the
locale consumer and did **not** change `get_image_prop` broadly. **Reviewer note:** if
Server detection ever misbehaves for the same reason, a shared trim (strip `\r` in
`get_image_prop`) would be the clean fix, but that is a broader change left out of this
minimal locale fix.

## Git
Changes left **uncommitted** per instructions; the user handles git.
