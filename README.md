# SecureAiDevSetup: runbook

A repeatable, manual procedure for setting up a Windows machine for AI-assisted development:
**a hardened WSL distro with rootless Docker, plus a sandboxed dev container per repo with Claude Code inside.**

Nothing here is automated on purpose. Each step says what to run, what to expect, and why, so you can follow it on any machine and understand every change you make.

## Phases

| # | Folder / branch | Goal | Run where | Status |
|---|---|---|---|---|
| 0 | `00-host-prep` | Firmware update, TPM, BitLocker, supported Windows version | Windows + BIOS/UEFI | Done |
| 1 | `01-reset` | Back up, remove all existing WSL distros and Docker Desktop, reclaim disk, verify prerequisites | Windows (PowerShell) | Done |
| 2 | `02-wsl` | Install a dedicated, hardened Ubuntu distro with rootless Docker Engine | Windows, then inside WSL | Done |
| 3 | `03-devcontainer` | Hardened dev container template based on Anthropic's reference (egress firewall, non-root, pinned) | Inside WSL + VS Code | Planned |
| 4 | `04-dotnet-hello` | .NET 10 minimal API in the template: end-to-end proof | Inside the dev container | Planned |

Do the phases **in order**. Each one assumes the previous one is complete. Each phase's guide is in its folder's `README.md` once that phase has merged.

## Target architecture

```
Windows host            BitLocker, Defender, updates; no Docker Desktop
 └─ WSL2 distro "dev"   no C:\ mount, no Windows interop, systemd on
     └─ Docker Engine   rootless: a container escape lands as your user, not root
         └─ per repo:   dev container, non-root user, egress firewall allowlist,
                        repo-only bind mount, Claude Code pinned
```

## How this repo is maintained

Each phase is written in its own branch and merged into `main` through a pull request. Each branch starts from `main` **after** the previous phase has merged, so fixes carry forward:

```bash
git switch main && git pull
git switch -c 02-wsl            # next phase starts from the updated main
# ...write / correct the phase...
git push -u origin 02-wsl       # open PR, review, merge
git switch main && git pull
git tag -a v0.2 -m "Phase 2: hardened WSL" && git push --tags
```

`main` always holds the complete, current procedure. Tags (`v0.1` … `v1.0`) mark each finished phase.

## Conventions used in the guides

- `PS>` means **Windows PowerShell**. `PS (Admin)>` means PowerShell **run as Administrator**.
- `$` means a shell **inside WSL**.
- **Checkpoint** blocks say what you should see before moving on. If you don't see it, stop and fix it first.
- **⚠ Irreversible** marks steps that delete data. Read those twice.