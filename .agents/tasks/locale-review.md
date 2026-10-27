# Review: locale-fallback hardening in trans.sh

## Scope reviewed
- Change note: `.agents/tasks/locale-fix-note.md`
- Working-tree diff of `trans.sh` (`git diff`): one hunk at lines ~8137-8158, replacing
  `[ -n "$locale" ] || locale=en-US` with a trim + validate + fallback block.
- Substitution site `-e "s|%locale%|$locale|"` (~8160) and the `windows.xml` template.
- Producer chain: `get_selected_image_prop` (6704) -> `get_image_prop` (6585) ->
  `wiminfo | grep | cut | trim` (6590); `trim()` at 1377.

## Evidence
Diff confirmed as the only change (`git diff --name-only` => `trans.sh` only;
`--stat` => 18 insertions, 3 deletions, single hunk). HEAD commit unchanged
(`81ea805`), change left uncommitted. `git status --porcelain` => ` M trans.sh` only.

Edited region (post-change):
```sh
locale=$(get_selected_image_prop 'Default Language')
locale=$(printf '%s' "$locale" | tr -d '\r\n' | tr '\t' ' ' | awk '{print $1}')
case "$locale" in
    [A-Za-z][A-Za-z]) : ;;
    [A-Za-z][A-Za-z]-[A-Za-z0-9]*) : ;;
    *) locale=en-US ;;
esac
case "$locale" in
    *[!A-Za-z0-9-]*) locale=en-US ;;
esac
```

Narrow syntax spot-check (specific doubt: shell `case` glob semantics of the
language-tag patterns). `bash -n` on an extracted copy of the block => exit 0.
Behavioral run of the extracted block:

| input | output |
|---|---|
| `` (empty) | `en-US` |
| `en-US` | `en-US` |
| `en-US\r` | `en-US` |
| `en-US ` (trailing space) | `en-US` |
| `   ` (whitespace only) | `en-US` |
| `de-DE` | `de-DE` |
| `zh` | `zh` |
| `zh-Hans-CN` | `zh-Hans-CN` |
| `pt-BR\r` | `pt-BR` |
| `Default:` | `en-US` |
| `en-` (dangling hyphen) | `en-US` |
| `\ten-US` (leading tab) | `en-US` |

(Extracted copy was removed after the check; no production code modified.)

LF line endings: CR count in `trans.sh` = 0 (no CRLF introduced).

## Criteria assessment

(a) Trim + fallback on CR/whitespace. `tr -d '\r\n'` strips CR/LF; `tr '\t' ' '`
normalizes tabs; `awk '{print $1}'` drops leading/trailing space and keeps the first
token (empty on whitespace-only input). Empty/invalid result -> `en-US`. Spot-check
rows for `en-US\r`, trailing space, whitespace-only, leading tab all yield `en-US` or a
clean tag. **PASS**

(b) Real `en-US` (Server 2019 / official ISO) passes through unchanged and is a valid
tag, fixing the "could not parse or process unattend answer file ... component or
setting ... does not exist" error caused by an empty/CR-tainted `<UILanguage>`. Even a
CR-tainted `en-US\r` is cleaned to `en-US`. **PASS**

(c) Non-English tags pass through trimmed-but-otherwise-unchanged: `de-DE`, `zh`,
`zh-Hans-CN`, `pt-BR` all preserved. The glob `[A-Za-z][A-Za-z]-[A-Za-z0-9]*` matches
multi-subtag forms because `*` in a `case` glob matches any remaining characters
(including further hyphens). No regression of upstream any-language support. **PASS**

(d) The `%locale%` substitution can no longer yield empty/whitespace tags: `$locale`
is guaranteed non-empty and shaped like a language tag before `sed`. All five fields in
`windows.xml` (`SetupUILanguage/UILanguage`, `InputLocale`, `SystemLocale`,
`UILanguage`, `UserLocale`) use `%locale%` and inherit the hardened value, fixing the
Atlas `0x80004005` "could not determine the language to use for Setup". **PASS**

(e) Protected areas untouched. `git diff --name-only` lists only `trans.sh`, and the
single hunk is confined to the locale value. dd path, VirtIO offline injection,
hivexregedit CriticalDeviceDatabase fix, windows-setup.bat PE fixes, and unattend logic
beyond the locale value are not modified. **PASS**

(f) LF preserved (CR count 0); comments are minimal English; no commit/push done
(HEAD unchanged, change uncommitted). **PASS**

## Non-blocking observations (not findings)
- `get_image_prop`'s shared `trim()` still may leave a `\r` for other consumers
  (`Installation Type`, `Image Name`); the note flags this and intentionally leaves a
  broad `get_image_prop` fix out of scope. Not reachable as a locale defect and out of
  this task's scope.

## Verdict
All criteria (a)-(f) satisfied. No blocking findings.
APPROVED.
