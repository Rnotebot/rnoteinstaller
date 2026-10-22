# Panel ↔ Engine integration (live mode)

How the Rntech panel (`../web`, proprietary) invokes this GPLv3 engine when
`EXECUTION_MODE=live`. In `simulation`, every step below is mocked by the panel's
job engine and no real DigitalOcean/SSH call occurs.

## Sequence the panel runs per job (new target)

1. **Create droplet** — `POST https://api.digitalocean.com/v2/droplets`
   - Header: `Authorization: Bearer <DO token>` (decrypted in memory only).
   - Body: `name`, `region`, `size`, `image` (default `ubuntu-22-04-x64`, from
     `RNTECH_DROPLET_IMAGE`), and cloud-init `user_data` (**no `ssh_keys`**). The
     `user_data` sets root's password from `RNTECH_DROPLET_ROOT_PASSWORD` (via
     `chpasswd`), sets `ssh_pwauth: true`, and forces `PermitRootLogin yes` /
     `PasswordAuthentication yes` in sshd — so the panel logs in with **password
     auth** and the user never has to register an SSH key in the DO console.
   - Capture `droplet.id` → written into the job-env as `RNTECH_EXPECTED_PROVIDER_ID`.
2. **Poll status** — `GET /v2/droplets/{id}` every ~5s until `status == "active"`
   and a public `networks.v4[].ip_address` exists. Node = `IP:RNTECH_RDP_PORT`.
   A timeout (e.g. 10 min) marks the job `failed`.
3. **Push + trigger over SSH (password auth)**
   - `scp rntech-job.env root@IP:/root/rntech-job.env`
   - `scp rntech-install.sh root@IP:/root/rntech-install.sh`
   - `ssh root@IP 'bash /root/rntech-install.sh /root/rntech-job.env'`
   - Auth is `root` + `RNTECH_DROPLET_ROOT_PASSWORD` (the TEMPORARY Linux droplet
     root password, distinct from the Windows RDP password in the job-env);
     `StrictHostKeyChecking=accept-new` (TOFU).
4. **Detach and wait for callbacks** — the panel does not block on the long
   install. The engine on the VPS reports via `POST /api/events`.

For an **existing** target the panel skips steps 1–2 (no `createServer`, no
poll), sets the node from the operator-supplied IP, and walks
`deploying → installing`. The destructive wipe guard still applies: the panel
writes `RNTECH_ALLOW_DISK_WIPE`/`RNTECH_EXPECTED_PROVIDER_ID` only when the
operator explicitly opts in, so an ordinary existing target fails closed before
any disk write.

## `rntech-job.env` format (every field)

```
RNTECH_INSTALL_SOURCE_MODE=ISO
RNTECH_RDP_PORT=7777
RNTECH_RDP_PASSWORD_B64=<base64 UTF-8 random per-job RDP password>
RNTECH_SETUP_MODE=NORMAL
RNTECH_RDP_USERNAME=Administrator
RNTECH_WINDOWS_VERSION=Windows Server 2019 SERVERSTANDARD
RNTECH_WINDOWS_VERSION_SLUG=2019            # optional; derived if omitted
RNTECH_ACTIVATION_PS1_URL=https://your-panel/api/noop/aktivasi.ps1
RNTECH_INSTALL_STATUS_URL=https://your-panel/api/events
RNTECH_INSTALL_LOG_URL=https://your-panel/api/events
RNTECH_INSTALL_JOB_ID=INSTALL#<n1>#<n2>#<n3>
RNTECH_INSTALL_JOB_TOKEN=<random per-job token>
RNTECH_INSTALL_ATTEMPT_ID=attempt-<hex>
RNTECH_INSTALL_NODE=<public_ip>:7777
# engine-only (not read by rntech-setup.bat):
RNTECH_REINSTALL_BASE_URL=https://files.example/reinstall-<commit>
RNTECH_REINSTALL_SH_SHA256=<sha256>
RNTECH_ISO_URL=https://files.example/win2019.iso
RNTECH_ISO_SHA256=<sha256>
RNTECH_ALLOW_DISK_WIPE=1                     # destructive opt-in (new targets)
RNTECH_EXPECTED_PROVIDER_ID=<droplet.id>     # binds the wipe to this host
```

`RNTECH_WINDOWS_VERSION_SLUG` derivation when omitted: lowercase
`RNTECH_WINDOWS_VERSION` and take the family token — Server 2016/2019/2022/2025
→ `2016/2019/2022/2025`, "Windows 10 Pro" → `10`, "Windows 11 Pro" → `11`. The
slug names the pinned password file `/configs/password-windows-<slug>-base64`.

## Callback received at `POST /api/events`

Body (form/url-encoded), identical from both scripts:

```
job_id, token, attempt_id, status, node, message
```

Statuses from the engine/VPS: `installing` (optional refinement from
`rntech-install.sh`), then `finishing`, then `done` (RDP listener up) or
`failed`. The panel validates `job_id`+`token` (constant-time), calls the single
status writer (`applyCallback`), appends a log line, and streams to the live
terminal. Progress is derived from status by the panel.

## Status → progress mapping

| Moment | Status (driver) | Percent |
|---|---|---|
| Job created, before create | `queued` (insert) | 0 |
| DO create started → polling | `deploying` (panel) | 15 |
| Droplet active + IP, before SSH | `deploying` (node set) | 15 |
| SSH trigger succeeded | `installing` (panel) | 50 |
| Engine refinement | `installing` (engine) | 50 |
| Windows finalizing | `finishing` (engine) | 85 |
| RDP ready | `done` (engine) | 100 |
| Any error | `failed` (engine or panel) | preserves last percent |

## Field mapping to panel Job fields

| rntech-job.env | Job field | Callback key |
|---|---|---|
| RNTECH_INSTALL_JOB_ID | id | job_id |
| RNTECH_INSTALL_JOB_TOKEN | token | token |
| RNTECH_INSTALL_ATTEMPT_ID | attempt_id | attempt_id |
| RNTECH_INSTALL_NODE | node (ip:port) | node |
| RNTECH_RDP_PORT | rdp_port | — |
| RNTECH_RDP_USERNAME | rdp_username | — |
| RNTECH_RDP_PASSWORD_B64 | rdp_password_cipher (masked) | — |
| RNTECH_WINDOWS_VERSION | windows_version | — |
| RNTECH_SETUP_MODE | setup_mode | — |
| RNTECH_INSTALL_SOURCE_MODE | source_mode | — |
| RNTECH_EXPECTED_PROVIDER_ID | providerServerId (from create) | — |

## Operational security

- The droplet root password (`RNTECH_DROPLET_ROOT_PASSWORD`) is the TEMPORARY
  Linux password the panel injects via cloud-init and uses only in-memory for
  the SSH handshake — it is never logged, never put on a command line, and is
  NOT the Windows RDP password the user sets in the wizard. No SSH key is
  registered in the DigitalOcean console; the token alone drives the deploy.
- `rntech-job.env` carries the DO token proxy + base64 RDP password: the engine
  `shred`s it after use (best-effort) and never logs its contents.
- The DO API token is used only to create/poll/destroy droplets and is stored
  encrypted at rest. Scope it to the minimum DigitalOcean permissions needed.
