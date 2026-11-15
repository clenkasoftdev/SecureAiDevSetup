# SecureAiDevSetup: runbook

A repeatable, manual procedure for setting up a Windows machine for AI-assisted development:
**a hardened WSL distro with rootless Docker, plus a sandboxed dev container per repo with Claude Code inside.**

Nothing here is automated on purpose. Each step says what to run, what to expect, and why, so you can follow it on any machine and understand every change you make.

Every step in `main` has been run on a real machine before it was merged (see **Tested on**).

## Phases

| # | Folder / branch | Goal | Run where | Status |
|---|---|---|---|---|
| 0 | `00-host-prep` | Firmware update, TPM, BitLocker, supported Windows version, Secure Boot certificates | Windows + BIOS/UEFI | Done |
| 1 | `01-reset` | Back up, remove all existing WSL distros and Docker Desktop, reclaim disk, verify prerequisites | Windows (PowerShell) | Done |
| 2 | `02-wsl` | Install a dedicated, hardened Ubuntu distro with rootless Docker Engine | Windows, then inside WSL | Done |
| 3 | `03-devcontainer` | Hardened dev container template based on Anthropic's reference (egress firewall, non-root, pinned) | Inside WSL + VS Code | Done |
| 4 | `04-dotnet-hello` | .NET 10 minimal API in the template: end-to-end proof | Inside the dev container | Done |
| 5 | `05-toolchains` | A ready-made .NET + Python (uv) container, and recipes for .NET, Python + uv, PowerShell, Azure CLI and Azure DevOps (Git and Artifacts with short-lived Entra tokens) | Inside WSL + the dev container | Done |

Do the phases **in order**. Each one assumes the previous one is complete. Each phase's guide is in its folder's `README.md` once that phase has merged.

## Target architecture

```
Windows host            TPM, BitLocker, Secure Boot, Defender, supported Windows; no Docker Desktop
 └─ WSL2 distro "dev"   no C:\ mount (only VS Code's two folders, read-only), no Windows interop, systemd on
     └─ Docker Engine   rootless: a container escape lands as your user, not root
         └─ per repo:   dev container, non-root user, repo-only bind mount, Claude Code pinned,
                        outbound HTTPS filtered by server name (SNI proxy), everything else blocked
```

## How this repo is maintained

Work from the clone inside WSL (`~/src/SecureAiDevSetup`): it's the copy you run the steps from.

Each phase is written in its own branch and merged into `main` through a pull request. Each branch starts from `main` **after** the previous phase has merged, so fixes carry forward:

```bash
git switch main && git pull
git switch -c 04-dotnet-hello      # next phase starts from the updated main
# ...write / correct the phase...
git push -u origin 04-dotnet-hello # open PR, review, merge
git switch main && git pull
git tag -a v1.0 -m "Phase 4: .NET hello world" && git push --tags
```

Corrections to a finished phase go in a small `docs/<phase>-<topic>` branch off `main`, for example `docs/01-reset-windows-git-auth`, with a patch tag such as `v0.1.1`. Existing tags never move.

`main` always holds the complete, current procedure. Tags mark each finished phase or change: `v0.0`–`v0.4` (host to firewall), `v1.0` (end-to-end proof), `v1.1`–`v1.2` (toolchains, Azure DevOps).

## Conventions used in the guides

- `PS>` means **Windows PowerShell**. `PS (Admin)>` means PowerShell **run as Administrator**.
- `$` means a shell **inside WSL**.
- `node $` means a terminal **inside the dev container**.
- **Checkpoint** blocks say what you should see before moving on. If you don't see it, stop and fix it first.
- **⚠ Irreversible** marks steps that delete data. Read those twice.

## Tested on

| Component | Version |
|---|---|
| Hardware | Lenovo ThinkPad (8th-gen Intel Core i5, 16 GB RAM, TPM 2.0) |
| Windows | Windows 11 Pro 26H2 |
| WSL | 3.0.x, kernel 6.18 |
| Distro | Ubuntu 24.04 LTS |
| Docker | Docker Engine 29.x, rootless |
| Dev container base | `node:24-trixie` (Debian 13) |
| Claude Code | 2.1.x, pinned per repo |

## Disclaimer

This runbook is provided **as is, without warranty of any kind**. It changes firmware settings, encrypts disks and deletes WSL distros: read each step, especially those marked **⚠ Irreversible**, and keep backups. Security controls reduce risk; they don't remove it. See "What this does and doesn't protect against" in [`03-devcontainer/README.md`](03-devcontainer/README.md).

This is an independent project, **not affiliated with or endorsed by** Anthropic, Microsoft or Docker. See [NOTICE.md](NOTICE.md).

## License

- Guides (Markdown): [CC BY 4.0](LICENSE-docs.md)
- Scripts and configuration written for this repository: [MIT](LICENSE)
- Files based on Anthropic's reference dev container: **not** covered by either license; see [NOTICE.md](NOTICE.md)

## Security and contributing

- Found a security problem? Report it privately: [SECURITY.md](SECURITY.md).
- Issues and corrections are welcome: [CONTRIBUTING.md](CONTRIBUTING.md).
