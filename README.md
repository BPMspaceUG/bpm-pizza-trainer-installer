# Pizza Trainer Installer

Bootstrap scripts and Go orchestrator (`pizza-trainer`) for the Pizza Trainer environment.

> [!WARNING]
> **Run this only on a disposable training machine — never on a personal or corporate device.**
>
> To keep classroom setup frictionless, this installer deliberately weakens the security
> of the machine it runs on. On Windows, `01-setup-wsl-ssh.ps1` will:
>
> - **remove the WSL user's password** (`passwd -d`) and grant **passwordless sudo**
>   (`NOPASSWD:ALL`)
> - **install and start Windows OpenSSH Server**, and **open inbound port 22** on all
>   firewall profiles, with no address restriction
>
> Anyone who can reach the machine on port 22 — on any network it joins — is a step away
> from a root shell in the WSL environment. That trade is acceptable for a throwaway lab
> VM used during a course. It is not acceptable on a laptop you use for anything else.
>
> Setup also pipes remote installer scripts into a shell (Docker, Tailscale, and the CAC
> CLI) and prompts before doing so. Review [Security notes](#security-notes) before
> running any of it.

---

## Download

Pre-built packages (binary + scripts bundled) are available on the [Releases page](https://github.com/BPMspaceUG/bpm-pizza-trainer-installer/releases).

| Package | Platform |
|---------|----------|
| `windows.zip` | Windows 10/11 — `pizza-trainer.exe`, all `.ps1` scripts, `launch.bat`, `packages.winget.json` |
| `linux-amd64.zip` | Linux x86-64 — `pizza-trainer`, all `.sh` scripts |
| `linux-arm64.zip` | Linux ARM64 |
| `macos-intel.zip` | macOS Intel |
| `macos-arm64.zip` | macOS Apple Silicon |

Unzip the package for your platform and run `pizza-trainer` (or `pizza-trainer.exe` on Windows) from the extracted folder.

> The `go-orchestrator/dist/` directory is gitignored — download packages from the Releases page, not from a clone of this repo.

---

## Quick start

**Windows — `pizza-trainer` (browser UI + system tray):**

```powershell
.\pizza-trainer.exe
```

**Windows — scripts (GUI or terminal):**

```powershell
launch.bat                          # double-click launcher
.\00-setup.ps1                      # WinForms GUI
.\00-setup.ps1 -NoGui               # terminal menu
```

**Linux / WSL / macOS — `pizza-trainer`:**

```bash
./pizza-trainer
```

**Linux / WSL / macOS — scripts:**

```bash
bash 00-setup.sh
```

---

## Go orchestrator (`pizza-trainer`)

`pizza-trainer` is a cross-platform CLI that wraps the stabilized setup scripts with a browser control panel and (on Windows) a system tray icon.

Running with no arguments auto-detects the workspace root, opens the browser control panel, and on Windows adds a system tray icon with **Open Control Panel**, **Reopen Browser**, and **Exit**.

### All commands

```
pizza-trainer [command] [flags]
```

| Command | Description |
|---------|-------------|
| *(no command)* | Browser UI + Windows system tray |
| `ui` | Browser control panel (explicit, configurable) |
| `preflight` | Run the platform-specific preflight script |
| `setup` / `full-setup` | Non-interactive full setup (packages + repos) |
| `packages-status` | Show installed/missing package status |
| `packages-install` | Install all missing packages |
| `packages-update` | Update installed packages (manifest only, never system-wide) |
| `coding-agents-config` | Configure Claude Code + Codex against a single OpenRouter key |
| `repos-status` | Show repository clone status |
| `repos-sync` | Clone or pull repositories |
| `repos-cleanup` | Selectively clean or remove repositories |
| `wsl-ssh` | Run the Windows WSL2 / OpenSSH setup script |
| `coding-agents` | Run the Windows VS Code and/or CAC setup scripts (`--only all\|extensions\|cac`) |
| `trainer` | Run the pizza-ml trainer setup |
| `validate` | Alias for `preflight` |
| `checkpoint-path` | Print the default trainer checkpoint path |
| `snapshot-save` | Save a dated fallback snapshot |
| `snapshot-restore` | Restore scripts from fallback or a named snapshot |
| `snapshot-list` | List dated fallback snapshots |

### Common flags

Most commands accept `--root <path>` (workspace root, defaults to `.`) and:

- `--fallback` — run against `fallback-scripts/` instead of the active top-level scripts
- `--snapshot <timestamp>` — run against `fallback-scripts/snapshots/<timestamp>`
- `--skip-preflight` — skip preflight checks (setup, full-setup)
- `--dry-run` — preview what would happen without making changes (setup, repos-sync, repos-cleanup)

### `repos-cleanup` flags

```
pizza-trainer repos-cleanup --root .. --remove-modules
pizza-trainer repos-cleanup --root .. --remove-modules --git-clean --reinstall
pizza-trainer repos-cleanup --root .. --remove-python-env    # pizza-ml venv + data teardown
pizza-trainer repos-cleanup --root .. --remove-repos          # full teardown (deletes clones)
pizza-trainer repos-cleanup --root .. --remove-modules --dry-run
```

### `ui` flags

```
pizza-trainer ui --root .. --addr 127.0.0.1:8080 --open=false
```

### Examples

```
pizza-trainer
pizza-trainer ui --root ..
pizza-trainer preflight --root ..
pizza-trainer preflight --root .. --fallback
pizza-trainer setup --root ..
pizza-trainer setup --root .. --snapshot 20260403-214500
pizza-trainer trainer --root .. --resume
pizza-trainer packages-status --root ..
pizza-trainer repos-status --root ..
pizza-trainer repos-cleanup --root .. --remove-modules --dry-run
pizza-trainer repos-cleanup --root .. --remove-repos
pizza-trainer snapshot-save --root ..
pizza-trainer snapshot-list --root ..
pizza-trainer snapshot-restore --root .. --snapshot 20260403-214500
```

Build from source:

```
go run ./cmd/pizza-trainer
go run ./cmd/pizza-trainer ui --root ..
```

---

## Script order

| Script | Platform | Notes |
|--------|----------|-------|
| `00-preflight.ps1` / `00-preflight.sh` | All | Run automatically by `00-setup.*`; can be run standalone |
| `00-setup.ps1` / `00-setup.sh` | All | Primary entry point — installs packages, syncs repos, runs later steps |
| `01-setup-wsl-ssh.ps1` | Windows (Admin) | Enables WSL2, installs Ubuntu, configures OpenSSH Server, opens port 22 |
| `02-setup-coding-agents.ps1` | Windows | VS Code AI extension set |
| `02b-setup-cac.ps1` | Windows | CAC (CodingAgentConfigCopy) CLI installation |
| `03-setup-pizza-ml-trainer.ps1` / `.sh` | All | Python venv, Food-101 dataset, PyTorch, smoke test |

## Script entry points

### Windows

```powershell
.\00-setup.ps1                                  # GUI (default)
.\00-setup.ps1 -NoGui                           # terminal menu
.\00-setup.ps1 -NoGui -SkipPreflight            # skip preflight
.\00-setup.ps1 -Action full-setup               # non-interactive full setup
.\00-setup.ps1 -Action repos-cleanup -RemoveModules -GitClean
```

Available `-Action` values: `packages-status`, `packages-install`, `repos-status`, `repos-sync`, `repos-cleanup`, `full-setup`

### Linux / WSL / macOS

```bash
bash 00-setup.sh
bash 00-setup.sh --skip-preflight
bash 00-setup.sh --action full-setup
```

### Preflight only

```powershell
.\00-preflight.ps1
```

```bash
bash 00-preflight.sh
```

Preflight reports OS context, disk space, key tools, network reachability, and WSL state. It does not change the machine.

---

## Trainer checkpoint resume

Script 03 supports checkpoint-based resume for long runs:

```powershell
.\03-setup-pizza-ml-trainer.ps1 -Resume
.\03-setup-pizza-ml-trainer.ps1 -ResetCheckpoint
```

```bash
bash 03-setup-pizza-ml-trainer.sh --resume
bash 03-setup-pizza-ml-trainer.sh --reset-checkpoint
```

Default checkpoint location:

- Windows: `$HOME\.pizza-trainer\03-setup-pizza-ml-trainer.json`
- Linux / WSL / macOS: `$HOME/.pizza-trainer/03-setup-pizza-ml-trainer.state`

---

## Fallback snapshot system

A fallback copy of the current script set is stored under `fallback-scripts/`. Dated snapshots are saved to `fallback-scripts/snapshots/<timestamp>/`.

### Save a snapshot

```powershell
.\98-save-fallback-snapshot.ps1
```

```bash
bash 98-save-fallback-snapshot.sh
```

Refreshes the root `fallback-scripts/` copy and writes a new dated snapshot.

### Restore from a snapshot

```powershell
.\99-restore-fallback-snapshot.ps1
.\99-restore-fallback-snapshot.ps1 -Snapshot 20260403-214500
```

```bash
bash 99-restore-fallback-snapshot.sh
bash 99-restore-fallback-snapshot.sh 20260403-214500
```

### Run against fallback scripts via pizza-trainer

```
pizza-trainer preflight --root .. --fallback
pizza-trainer setup --root .. --fallback
pizza-trainer trainer --root .. --fallback
pizza-trainer preflight --root .. --snapshot 20260403-214500
pizza-trainer setup --root .. --snapshot 20260403-214500
pizza-trainer trainer --root .. --snapshot 20260403-214500
```

---

## Minimum requirements

- **Disk space:** at least 30 GB free (Food-101 dataset + Python dependencies)
- **Internet:** required for package installation, repo cloning, and Python package downloads
- `git` must be on PATH for repo cloning
- `winget` required for Windows package installation
- VS Code CLI (`code`) required only for script 02 to install extensions automatically

## Supported platforms

- Windows 10/11 — PowerShell flow + WinForms GUI
- Linux, WSL2, macOS — shell flow
- `01-setup-wsl-ssh.ps1` is Windows-only and requires Administrator rights

## Administrator rights

The `pizza-trainer` executable does **not** need to be run as Administrator. It does not
elevate itself, and every command works as a normal user except one:

| Command / script | Elevation |
| --- | --- |
| `pizza-trainer` (all other commands) | Normal user |
| `pizza-trainer wsl-ssh` → `01-setup-wsl-ssh.ps1` | **Administrator required** |
| `00-setup.ps1` / `02-setup-coding-agents.ps1` / `02b-setup-cac.ps1` | Normal user |
| `03-setup-pizza-ml-trainer.ps1` | Normal user |

`01-setup-wsl-ssh.ps1` declares `#Requires -RunAsAdministrator`, so it fails immediately
without elevation — it enables WSL features, installs OpenSSH Server, and opens a
firewall port. Launch an elevated PowerShell for that step only. `00-preflight.ps1`
reports whether the current session is elevated, and the GUI skips script 01 when it is
not.

## Security notes

This installer trades security for classroom convenience. Everything below is
intentional, and acceptable **only** on a disposable training machine.

### What gets weakened

All of it lives in `01-setup-wsl-ssh.ps1`, which requires Administrator rights.
No other script changes the machine's security posture.

| Behaviour | Prompted? | Why it matters |
| --- | --- | --- |
| WSL user password removed (`passwd -d`) | yes — or `-EnableLabWslDefaults` | The account has no password at all |
| Passwordless sudo (`NOPASSWD:ALL`) | yes — same prompt | Any local shell can become root without asking |
| Inbound port 22 opened on all firewall profiles | yes — or `-OpenFirewall` | Reachable on public/untrusted networks, not just the lab LAN |
| OpenSSH Server installed, started, set to Automatic | **no — unconditional** | Running script 01 at all means the machine accepts SSH from boot onward |
| No `sshd_config` written | n/a | No `ListenAddress` set, so sshd binds every interface by default |

Note the asymmetry: the two most damaging changes are each behind their own
confirmation, but **installing and starting sshd is not** — it happens whenever
script 01 runs. Declining both prompts still leaves you with a listening SSH
server; it is just not reachable through the Windows firewall, and the WSL
account keeps its password.

Skipping script 01 entirely leaves authentication untouched. Packages, repos and
the trainer setup (`00-setup.*`, `03-setup-pizza-ml-trainer.*`) all work without it.

### Remote code execution

Several install paths pipe a remote script straight into a shell:

- `https://get.docker.com | sh`
- `https://tailscale.com/install.sh | sh`
- the CAC installer from `raw.githubusercontent.com/BPMspaceUG/bpm-CodingAgentConfigCopy`

These run whatever those URLs serve at the time you run them. `02b-setup-cac.ps1`
asks for confirmation first and accepts `-AllowRemoteScriptInstall` to skip the
prompt in automated runs.

### API keys

`coding-agents-config` writes an OpenRouter API key to `~/.claude/settings.json`
and to your shell profile (`OPENROUTER_API_KEY`, which Codex reads via `env_key`).
Both are plaintext, on disk, in your home directory. Use a key scoped and funded
for training use — not a personal key with a large balance.

### Before running outside a lab

Don't. If you need parts of this on a machine you care about, run `00-setup.*`
(packages and repos) and skip `01-setup-wsl-ssh.ps1` entirely.
