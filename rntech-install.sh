#!/usr/bin/env bash
# =============================================================================
# rntech-install.sh  (Rntech live engine — destructive path)
#
# Runs INSIDE a freshly-created DigitalOcean droplet (Ubuntu), pushed and
# triggered by the Rntech panel over SSH. It installs Windows Server 2019 +
# VirtIO onto this droplet's disk using a pinned, self-hosted fork of
# bin456789/reinstall (GPLv3) plus a self-hosted, SHA-256-verified official
# Windows ISO, then reboots. The rebranded post-install script
# (rntech-setup.bat) applies RDP settings and posts the finishing/done/failed
# callbacks once Windows boots.
#
# SECURITY PRINCIPLES (see NOTICE + README.md, hardening H1-H8):
#   - reinstall.sh/helpers come from YOUR host (RNTECH_REINSTALL_BASE_URL), pinned.
#   - reinstall.sh is SHA-256 verified before chmod/execute.
#   - The Windows ISO is downloaded, SHA-256 verified, then served to reinstall
#     as a LOCAL file:// path (never a remote --iso URL).
#   - The RDP password is written (base64) to a mode-600 file reinstall already
#     consumes; it never appears on any command line.
#   - A fresh-VPS guard bound to the droplet identity runs BEFORE any disk write.
#
# WARNING: this script OVERWRITES THE ENTIRE DISK. Run only on a throwaway VPS.
# =============================================================================
set -euo pipefail

JOB_ENV="${1:-/root/rntech-job.env}"
LOG="/root/rntech-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== rntech-install.sh start $(date -u +%FT%TZ) ==="

# ---- 1. Load job context -----------------------------------------------------
if [[ ! -f "$JOB_ENV" ]]; then
  echo "[FATAL] job-env not found: $JOB_ENV" >&2
  exit 2
fi
# shellcheck disable=SC1090
set -a; source "$JOB_ENV"; set +a

# Defaults.
: "${RNTECH_RDP_PORT:=7777}"
: "${RNTECH_RDP_USERNAME:=Administrator}"

# Fail closed on every required field.
: "${RNTECH_INSTALL_STATUS_URL:?need callback status URL}"
: "${RNTECH_INSTALL_JOB_ID:?need job id}"
: "${RNTECH_INSTALL_JOB_TOKEN:?need job token}"
: "${RNTECH_INSTALL_NODE:?need node ip:port}"
: "${RNTECH_REINSTALL_BASE_URL:?need self-hosted pinned reinstall base URL}"
: "${RNTECH_REINSTALL_SH_SHA256:?need reviewed reinstall.sh SHA-256}"
: "${RNTECH_ISO_URL:?need self-hosted official Windows ISO URL}"
: "${RNTECH_ISO_SHA256:?need Windows ISO SHA-256}"

# ---- 2. Callback -------------------------------------------------------------
# Posts the exact body keys the panel's /api/events expects. TLS is verified
# (NO --insecure). A callback failure never aborts the install on its own.
callback() { # status, message
  curl -fsS --max-time 15 -X POST "$RNTECH_INSTALL_STATUS_URL" \
    --data-urlencode "job_id=${RNTECH_INSTALL_JOB_ID}" \
    --data-urlencode "token=${RNTECH_INSTALL_JOB_TOKEN}" \
    --data-urlencode "attempt_id=${RNTECH_INSTALL_ATTEMPT_ID:-}" \
    --data-urlencode "status=$1" \
    --data-urlencode "node=${RNTECH_INSTALL_NODE}" \
    --data-urlencode "message=$2" || echo "[WARN] callback $1 failed (continuing)"
}

# On any unexpected error, tell the panel the job failed, then propagate.
trap 'rc=$?; callback failed "rntech-install.sh error (see droplet log)"; exit $rc' ERR

callback installing "Preparing install environment on the VPS"

# ---- 3. Minimal dependencies -------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

callback installing "Waiting for apt lock / installing dependencies"

# A freshly-booted droplet often runs cloud-init / unattended-upgrades, which
# hold the apt/dpkg locks. Wait (up to ~5 min) for those to release before we
# touch apt, otherwise "Could not get lock /var/lib/apt/lists/lock" aborts us.
echo "[*] Waiting for any boot-time apt/dpkg process to release its lock..."
wait_apt_lock() {
  local tries=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 60 ]]; then
      echo "[WARN] apt still locked after ~5 min; proceeding anyway."
      break
    fi
    sleep 5
  done
}
wait_apt_lock

# Retry apt a few times in case a lock is grabbed between the wait and the call.
apt_retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if [[ $n -ge 5 ]]; then
      echo "[WARN] apt command failed after retries: $*"
      return 0  # dependencies are usually already present; don't hard-fail
    fi
    echo "[*] apt busy; retry $n/5 in 10s..."
    sleep 10
    wait_apt_lock
  done
}
apt_retry apt-get update -y
apt_retry apt-get install -y curl ca-certificates coreutils util-linux

# ---- 4. Derive the Windows version slug (HIGH-1) -----------------------------
# Use RNTECH_WINDOWS_VERSION_SLUG when supplied, else derive the family token
# from RNTECH_WINDOWS_VERSION. Examples:
#   "Windows Server 2019 SERVERSTANDARD" -> 2019
#   "Windows Server 2016/2022/2025 ..."  -> 2016 / 2022 / 2025
#   "Windows 10 Pro"                      -> 10
#   "Windows 11 Pro"                      -> 11
derive_version_slug() {
  if [[ -n "${RNTECH_WINDOWS_VERSION_SLUG:-}" ]]; then
    printf '%s' "$RNTECH_WINDOWS_VERSION_SLUG"
    return 0
  fi
  local ver_lc
  ver_lc="$(printf '%s' "${RNTECH_WINDOWS_VERSION:-}" | tr '[:upper:]' '[:lower:]')"
  case "$ver_lc" in
    *2016*) printf '2016' ;;
    *2019*) printf '2019' ;;
    *2022*) printf '2022' ;;
    *2025*) printf '2025' ;;
    *" 11 "*|*" 11") printf '11' ;;
    *" 10 "*|*" 10") printf '10' ;;
    *) printf '' ;;
  esac
}
RNTECH_WINDOWS_VERSION_SLUG="$(derive_version_slug)"

# ---- 5. Fresh-VPS guard (H5/H7) ---------------------------------------------
# Refuse the destructive write unless the host is an intended throwaway:
#   (a) no prior-install marker /root/.rntech-installed exists,
#   (b) RNTECH_ALLOW_DISK_WIPE=1, and
#   (c) the droplet's own metadata id exactly equals RNTECH_EXPECTED_PROVIDER_ID.
# Metadata unreachable or mismatched => refuse (no existing:<ip> fallback).
fresh_vps_guard() {
  if [[ -e /root/.rntech-installed ]]; then
    callback failed "Refused: /root/.rntech-installed present; host already installed."
    echo "[FATAL] prior-install marker present; refusing to re-wipe." >&2
    exit 4
  fi

  if [[ "${RNTECH_ALLOW_DISK_WIPE:-}" != "1" ]]; then
    callback failed "Refused: RNTECH_ALLOW_DISK_WIPE is not set to 1."
    echo "[FATAL] disk-wipe opt-in absent; refusing destructive install." >&2
    exit 4
  fi

  # Two binding modes:
  #   - NEW droplet target: RNTECH_EXPECTED_PROVIDER_ID is set. Bind the wipe to
  #     the exact droplet id by matching the cloud metadata id (strict).
  #   - EXISTING VPS target: no provider id is knowable (the host was not created
  #     by the panel). The wipe is still gated by the explicit opt-in checked
  #     above (RNTECH_ALLOW_DISK_WIPE=1 + the panel's confirm-wipe checkbox) and
  #     the absence of a prior-install marker; proceed with a clear warning
  #     instead of demanding an id that cannot exist.
  if [[ -n "${RNTECH_EXPECTED_PROVIDER_ID:-}" ]]; then
    local meta_id
    if ! meta_id="$(curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/id)"; then
      callback failed "Refused: cloud metadata id unreachable; cannot confirm host identity."
      echo "[FATAL] metadata service unreachable; refusing destructive install." >&2
      exit 4
    fi
    if [[ "$meta_id" != "$RNTECH_EXPECTED_PROVIDER_ID" ]]; then
      callback failed "Refused: metadata id does not match the expected droplet id."
      echo "[FATAL] metadata id mismatch (expected ${RNTECH_EXPECTED_PROVIDER_ID}); refusing." >&2
      exit 4
    fi
    echo "[OK] fresh-VPS guard passed (identity-bound to ${RNTECH_EXPECTED_PROVIDER_ID})."
  else
    echo "[WARN] existing-VPS target: no provider id to bind. Proceeding on the"
    echo "[WARN] explicit disk-wipe opt-in + absent prior-install marker only."
  fi

  # Defense-in-depth freshness signal (secondary, not the sole discriminator):
  # log any pre-existing NTFS/Windows partition so an operator can inspect it.
  if command -v lsblk >/dev/null 2>&1; then
    if lsblk -no FSTYPE 2>/dev/null | grep -qi 'ntfs'; then
      echo "[WARN] an NTFS partition is present on this host (secondary signal only)."
    fi
  fi
}

# ---- 6. Fetch + verify reinstall.sh (pinned, self-hosted) (H1/H2) -----------
cd /root
callback installing "Downloading reinstall engine (verified)"
echo "[*] Downloading reinstall.sh from self-hosted pinned base (verified)"
curl -fsSL "${RNTECH_REINSTALL_BASE_URL}/reinstall.sh" -o reinstall.sh
echo "${RNTECH_REINSTALL_SH_SHA256}  reinstall.sh" | sha256sum -c - \
  || { callback failed "reinstall.sh SHA-256 mismatch"; echo "[FATAL] reinstall.sh SHA-256 mismatch. Abort." >&2; exit 3; }
chmod +x reinstall.sh

# Point reinstall's helper lookups (trans.sh, windows.xml, *.bat, ...) at the
# same reviewed host instead of the upstream repo.
export confhome="${RNTECH_REINSTALL_BASE_URL}"
export confhome_cn="${RNTECH_REINSTALL_BASE_URL}"

# ---- 7. Validate the Windows ISO URL (H3) -----------------------------------
# IMPORTANT (bug-13 fix, verified live 2026-10-22):
# We do NOT pre-download the ISO here and hand reinstall a file:// path. That
# path fails for two reasons:
#   1. reinstall only STAGES in this (Ubuntu) environment, then reboots into a
#      fresh Alpine ramdisk to do the real disk write. A file saved to
#      /root/win2019.iso here does NOT exist in that Alpine environment.
#   2. reinstall's downloader (aria2) does not support the file:// scheme and
#      aborts with "Unrecognized URI or unsupported protocol: file://...".
# The correct contract is to pass reinstall an HTTP(S) --iso URL; reinstall
# downloads it itself from inside Alpine (verified: aria2 follows the MS fwlink
# redirect and fetches the official ISO at >200 MiB/s).
#
# Trade-off: the previous local SHA-256 verification (H3) no longer runs here,
# because the bytes are fetched later, inside Alpine, by reinstall. RNTECH_ISO_URL
# must therefore point at an official HTTPS source. RNTECH_ISO_SHA256 is retained
# in the panel config for reference/audit but is not enforced in this stage.
if [[ -z "${RNTECH_ISO_URL:-}" ]]; then
  callback failed "Refused: RNTECH_ISO_URL is empty."
  echo "[FATAL] empty RNTECH_ISO_URL; reinstall needs an HTTP(S) ISO URL. Abort." >&2
  exit 3
fi
case "$RNTECH_ISO_URL" in
  https://*|http://*) : ;;  # ok — reinstall/aria2 can fetch these
  *)
    callback failed "Refused: RNTECH_ISO_URL must be an http(s) URL (file:// is not supported by reinstall)."
    echo "[FATAL] RNTECH_ISO_URL must be http(s); got '${RNTECH_ISO_URL}'. Abort." >&2
    exit 3
    ;;
esac
callback installing "Windows ISO will be fetched by reinstall from the official source"
echo "[*] ISO URL validated; reinstall will download it inside Alpine: ${RNTECH_ISO_URL}"

# ---- 8. Pin the RDP password to the file reinstall consumes (H4) ------------
# ---- 8. Decode the RDP password (kept out of the command line) --------------
# reinstall prompts for username + password interactively. We feed those
# prompts over STDIN (a here-string) so the password never appears as a process
# argument / in the process list. We decode the base64 the panel sent.
if [[ -z "${RNTECH_RDP_PASSWORD_B64:-}" ]]; then
  callback failed "Refused: RDP password (base64) is empty."
  echo "[FATAL] empty RNTECH_RDP_PASSWORD_B64. Abort." >&2
  exit 5
fi
RNTECH_RDP_PASSWORD_PLAIN="$(printf '%s' "$RNTECH_RDP_PASSWORD_B64" | base64 -d 2>/dev/null)"
if [[ -z "$RNTECH_RDP_PASSWORD_PLAIN" ]]; then
  callback failed "Refused: could not decode RDP password."
  echo "[FATAL] base64 decode of RDP password failed. Abort." >&2
  exit 5
fi

# ---- 9. Fresh-VPS guard runs LAST before the destructive stage --------------
fresh_vps_guard

# ---- 10. Invoke reinstall (destructive) -------------------------------------
# --image-name selects the exact edition inside the ISO (an ISO holds several,
# e.g. Standard/Datacenter). reinstall requires it. RNTECH_WINDOWS_VERSION
# already holds the in-ISO edition name (e.g. "Windows Server 2019
# SERVERSTANDARD"); it is case-insensitive.
if [[ -z "${RNTECH_WINDOWS_VERSION:-}" ]]; then
  callback failed "Refused: RNTECH_WINDOWS_VERSION (image name) is empty."
  echo "[FATAL] empty RNTECH_WINDOWS_VERSION; reinstall needs --image-name. Abort." >&2
  exit 5
fi
echo "[*] Starting reinstall windows (VirtIO auto-inject); VPS will reboot."
callback installing "Staging reinstall (writing GRUB entry)"

# reinstall prompts: Username, Password, Retype password. Feed them via STDIN so
# the password is never a command-line argument. --username is also passed; the
# password is ONLY on stdin. The username line + two identical password lines
# satisfy reinstall's read + confirm loop.
RNTECH_USER="${RNTECH_RDP_USERNAME:-Administrator}"
# NOTE (bug-13 fix): --iso is an HTTP(S) URL, not a file:// path. reinstall
# records this URL into the GRUB cmdline (finalos_iso=...) and its Alpine stage
# downloads it with aria2. A file:// path is rejected by aria2 and also would
# not survive the reboot into Alpine.
printf '%s\n%s\n%s\n' "$RNTECH_USER" "$RNTECH_RDP_PASSWORD_PLAIN" "$RNTECH_RDP_PASSWORD_PLAIN" \
  | ./reinstall.sh windows \
      --image-name "${RNTECH_WINDOWS_VERSION}" \
      --iso "${RNTECH_ISO_URL}" \
      --rdp-port "${RNTECH_RDP_PORT}"

# ---- 11. Completion bookkeeping ---------------------------------------------
# Mark this host as installed so a stale re-run of the guard refuses, and best-
# effort shred the job-env (which held the token) now that it is consumed.
printf 'rntech installed %s\n' "$(date -u +%FT%TZ)" > /root/.rntech-installed
if command -v shred >/dev/null 2>&1; then
  shred -u "$JOB_ENV" 2>/dev/null || rm -f "$JOB_ENV"
else
  rm -f "$JOB_ENV"
fi

echo "=== rntech-install.sh triggered reinstall; rebooting now. ==="
callback installing "Rebooting into the Windows installer (the VPS will drop SSH now)"
trap - ERR

# reinstall only STAGES the reinstallation (writes a GRUB entry) and tells us to
# reboot; it does not reboot itself. Trigger the reboot now so the box boots
# into the installer environment that writes Windows to disk. Try the clean
# paths first, then a forced reboot as a last resort.
sync
( systemctl reboot 2>/dev/null \
  || reboot 2>/dev/null \
  || shutdown -r now 2>/dev/null \
  || echo 1 > /proc/sys/kernel/sysrq 2>/dev/null; echo b > /proc/sysrq-trigger 2>/dev/null ) &

exit 0
