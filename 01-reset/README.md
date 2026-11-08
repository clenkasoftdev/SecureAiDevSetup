# Phase 1: Make the computer ready for a fresh WSL install

**Goal:** remove every existing WSL distro and Docker Desktop **without losing anything you need**, reclaim the disk space, and confirm the machine is ready for phase 2.

**Time:** 30–60 minutes, most of it backups.
**Run where:** Windows PowerShell. Steps that need an Administrator window are marked `PS (Admin)>`.
**Requires:** phase 0 complete (disk encrypted), so everything rescued here lands on an encrypted disk.

## Why this phase exists

Old distros and Docker Desktop leave behind:
- Docker credentials and contexts on Windows
- the `docker-desktop` distros, which are wired into every other distro
- tens of GB of virtual disks, which never shrink on their own

Starting clean means phase 2 is the *only* Linux environment on the machine, and you know exactly what is in it.

## Steps

1. [Inventory what exists](#step-1-inventory-what-exists)
2. [Rescue what you need from each distro](#step-2-rescue-what-you-need-from-each-distro)
3. [Optional: full backup export](#step-3-optional-full-backup-export)
4. [Remove Docker Desktop](#step-4-remove-docker-desktop)
5. [Unregister the remaining distros](#step-5-unregister-the-remaining-distros)
6. [Remove leftover files and launchers](#step-6-remove-leftover-files-and-launchers)
7. [Update WSL and verify prerequisites](#step-7-update-wsl-and-verify-prerequisites)
8. [Security housekeeping](#step-8-security-housekeeping)
9. [Confirm disk space](#step-9-confirm-disk-space)

Problems along the way are covered in [Troubleshooting](#troubleshooting).

---

## Step 1: Inventory what exists

```powershell
PS> wsl --version
PS> wsl --list --verbose
```

Record the inventory in a text file **outside this repo**: it contains your Windows username and disk paths. The first command creates the file; the others append to it.

```powershell
PS> $inv = "$env:USERPROFILE\wsl-rescue\inventory.txt"
PS> New-Item -ItemType Directory -Force (Split-Path $inv) | Out-Null

# 1. Distro list: creates the file
PS> wsl --list --verbose | Out-File $inv

# 2. Each distro's virtual disk and size: appended
PS> Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
      ForEach-Object {
        $p    = Get-ItemProperty $_.PSPath
        $base = $p.BasePath -replace '^\\\\\?\\', ''
        $vhd  = Get-ChildItem $base -Filter *.vhdx -ErrorAction SilentlyContinue | Select-Object -First 1
        [pscustomobject]@{
          Name   = $p.DistributionName
          SizeGB = if ($vhd) { [math]::Round($vhd.Length / 1GB, 1) } else { $null }
          Disk   = if ($vhd) { $vhd.FullName } else { $base }
        }
      } | Format-Table -AutoSize | Out-File $inv -Append -Width 300

# 3. Docker Desktop disks (not always listed above): appended
PS> Get-ChildItem "$env:LOCALAPPDATA\Docker\wsl" -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue | Select-Object FullName, @{n='SizeGB';e={[math]::Round($_.Length/1GB,1)}} | Format-Table -AutoSize | Out-File $inv -Append -Width 300

# 4. Review it
PS> Get-Content $inv
```

`-Width 300` keeps long disk paths from being cut off.

> **Checkpoint:** `inventory.txt` lists every distro name, its size, and where its disk lives.

## Step 2: Rescue what you need from each distro

A distro is deleted **with everything inside it**. Go through each distro from Step 1 (except `docker-desktop*`), open it with `wsl -d <Name>`, and check the following.

**2a. Uncommitted or unpushed Git work**, the most common loss:

```bash
$ find ~ -name .git -type d -prune 2>/dev/null | while read -r g; do
    d="${g%/.git}"
    dirty=$(git -C "$d" status --porcelain 2>/dev/null)
    ahead=$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null)
    stash=$(git -C "$d" stash list 2>/dev/null)
    [ -n "$dirty$ahead$stash" ] && echo "UNSAVED: $d"
  done
```

For every `UNSAVED` repo: commit and push it, or copy it out (2c).

**2b. Keys, credentials and config:**

```bash
$ ls -la ~/.ssh ~/.gnupg ~/.gitconfig ~/.config/gh 2>/dev/null
$ ls -a ~ | grep -E '^\.(bashrc|zshrc|profile|aliases|npmrc|nuget|azure|kube|aws)'
```

- **SSH and GPG keys:** don't carry them forward. Phase 2 creates new hardware-backed keys, and Step 8 retires the old ones. Copy a key out only if it's the sole copy of something you must still decrypt or sign.
- **Tokens and cloud credentials** (`~/.config/gh`, `~/.azure`, `~/.kube`, `~/.aws`, `~/.npmrc`): don't copy them. Re-authenticate after phase 2.
- **Dotfiles** (`.bashrc`, aliases, `.gitconfig`): copy them if you've customised them.

**2c. Copy files out to Windows** through the `\\wsl.localhost` share:

```powershell
PS> $d = "<Name>"   # distro name from Step 1
PS> robocopy "\\wsl.localhost\$d\home\<linux-user>\src" "$env:USERPROFILE\wsl-rescue\$d\src" /E /XD node_modules bin obj .venv
PS> robocopy "\\wsl.localhost\$d\home\<linux-user>" "$env:USERPROFILE\wsl-rescue\$d\dotfiles" .bashrc .gitconfig .profile
```

**2d. Databases and Docker volumes:** dump them with the tool's own export (`pg_dump`, `mysqldump`, …) into `wsl-rescue`.

> **Checkpoint:** for every distro, you can say "nothing in here I still need" or "rescued to `wsl-rescue\<Name>`".

## Step 3: Optional: full backup export

A safety net in case Step 2 missed something. An export contains *everything* in the distro, keys and tokens included, so keep it on an encrypted disk: C: (BitLocker since phase 0), or an external drive protected with BitLocker To Go.

```powershell
PS> wsl --shutdown
PS> New-Item -ItemType Directory -Force "$env:USERPROFILE\wsl-rescue\exports" | Out-Null
PS> wsl --export <Name> "$env:USERPROFILE\wsl-rescue\exports\<Name>-$(Get-Date -Format yyyyMMdd).tar"
```

Repeat for each distro you're unsure about. `docker-desktop*` doesn't need exporting.

Restore, if ever needed:

```powershell
PS> wsl --import <Name> "$env:USERPROFILE\WSL\<Name>" "$env:USERPROFILE\wsl-rescue\exports\<Name>-<date>.tar"
```

Delete the exports after a few weeks.

## Step 4: Remove Docker Desktop

Skip this step if Step 1 showed no Docker Desktop.

**4a.** Quit Docker Desktop (system tray whale → **Quit Docker Desktop**), then:

```powershell
PS> wsl --shutdown
PS> winget uninstall --id Docker.DockerDesktop
```

**4b.** Unregister its distros, if still listed:

```powershell
PS> wsl --list --verbose
PS> wsl --unregister docker-desktop        # ⚠ Irreversible
PS> wsl --unregister docker-desktop-data   # older installs only
```

**4c.** Remove leftover data. `config.json` in `.docker` can hold registry credentials.

```powershell
PS> "$env:LOCALAPPDATA\Docker", "$env:APPDATA\Docker", "$env:APPDATA\Docker Desktop", "$env:USERPROFILE\.docker" | Where-Object { Test-Path $_ } | ForEach-Object { Write-Host "Removing $_"; Remove-Item $_ -Recurse -Force }
PS (Admin)> if (Test-Path "$env:ProgramData\DockerDesktop") { Remove-Item "$env:ProgramData\DockerDesktop" -Recurse -Force }
```

**4d.** Remove stored Docker credentials:

```powershell
PS> cmdkey /list | Select-String docker
PS> cmdkey /delete:<target-name-from-the-list>
```

**4e.** Make sure no other Docker CLI is left on Windows. Phase 2 installs it inside WSL.

```powershell
PS> Get-Command docker, docker-compose -All -ErrorAction SilentlyContinue | Select-Object Name, Source
```

> **Checkpoint:** `wsl --list --verbose` shows no `docker-desktop*`, and the `Get-Command` returns nothing.

## Step 5: Unregister the remaining distros

> **⚠ Irreversible.** `wsl --unregister` deletes the distro and its virtual disk immediately. Proceed only once Step 2 is done for **every** distro.

```powershell
PS> wsl --shutdown
PS> wsl --list --quiet
PS> wsl --unregister <Name>     # one at a time, reading each name as you type it
```

Do it by hand, not in a loop. `wsl --list` prints UTF-16, which garbles names in scripts, and typing each name forces a final check.

> **Checkpoint:** `wsl --list --verbose` prints *"Windows Subsystem for Linux has no installed distributions."*

## Step 6: Remove leftover files and launchers

**6a. Store launcher apps**, so nothing can recreate an old distro:

```powershell
PS> Get-AppxPackage | Where-Object { $_.Name -match 'Ubuntu|Debian|kali|SUSE|Fedora|AlmaLinux|OracleLinux' } | Select-Object Name, PackageFullName
PS> Get-AppxPackage *CanonicalGroupLimited.Ubuntu* | Remove-AppxPackage     # repeat per package found
```

**6b. Orphaned virtual disks:**

```powershell
PS> Get-ChildItem "$env:LOCALAPPDATA\Packages", "$env:LOCALAPPDATA\Docker", "$env:USERPROFILE\WSL" -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue | Select-Object FullName, @{n='SizeGB';e={[math]::Round($_.Length/1GB,1)}}
```

Step 5 confirmed no distros are registered, so anything listed here is orphaned. Delete it once you're sure it isn't a backup you want.

**6c. Old WSL settings:** phase 2 installs a new `.wslconfig`.

```powershell
PS> if (Test-Path "$env:USERPROFILE\.wslconfig") { Rename-Item "$env:USERPROFILE\.wslconfig" ".wslconfig.old-$(Get-Date -Format yyyyMMdd)" }
```

**6d. VS Code:** uninstall the **Docker** / **Container Tools** extension if it was only there for Docker Desktop. Keep **WSL** and **Dev Containers**.

## Step 7: Update WSL and verify prerequisites

**7a. Update WSL:**

```powershell
PS> wsl --update
PS> wsl --version
PS> wsl --set-default-version 2
```

> **Checkpoint:** WSL version **2.x or later** (3.x as of late 2026), with a kernel version listed.

WSL 3.x includes **WSL Containers** (`wslc.exe`), Microsoft's own container runtime. This runbook doesn't use it: the VS Code Dev Containers extension expects the Docker CLI, and `wslc` has no Compose support yet. Phase 2 installs rootless Docker Engine instead.

**7b. Virtualization:** Task Manager → Performance → CPU shows **Virtualization: Enabled**.

**7c. Virtual Machine Platform feature:**

```powershell
PS (Admin)> dism /online /get-featureinfo /featurename:VirtualMachinePlatform
```

> **Checkpoint:** `State : Enabled` (German Windows: `Status : Aktiviert`).

**7d. Resources for phase 2:**

```powershell
PS> Get-CimInstance Win32_ComputerSystem | Select-Object NumberOfLogicalProcessors, @{n='RAM_GB';e={[math]::Round($_.TotalPhysicalMemory/1GB)}}
```

Note the numbers. Phase 2 sizes `.wslconfig` from them.

## Step 8: Security housekeeping

Phase 0 covered encryption and updates. This step covers what's left.

- **Defender:** Windows Security → Virus & threat protection → real-time protection **on**.
- **Memory integrity:** Windows Security → Device security → Core isolation → **on**, if supported.
- **No broad exclusions:** don't exclude WSL, `%LOCALAPPDATA%` or development folders from Defender "for speed". Those are exactly where a malicious package drops files.
- **Retire old credentials** from the deleted distros:
  - GitHub → Settings → **SSH and GPG keys**: remove the old keys.
  - GitHub → Developer settings → **Tokens**: revoke the old tokens.
  - The same for Azure DevOps and any other service the old distros were signed in to.

- **Windows Git access after retiring keys.** Pushing from Windows needs its own credential. 
  Either:
  - **HTTPS:** push once and sign in through the browser. Git Credential Manager stores the login (`git config --get credential.helper` → `manager`).
  - **SSH:** a new Windows-only key with a passphrase:
    ```powershell
    PS> ssh-keygen -t ed25519 -C "<machine>-windows" -f "$env:USERPROFILE\.ssh\id_ed25519_github"
    PS (Admin)> Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent
    PS> ssh-add "$env:USERPROFILE\.ssh\id_ed25519_github"
    PS> git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
    PS> Get-Content "$env:USERPROFILE\.ssh\id_ed25519_github.pub" | Set-Clipboard   # add on GitHub → SSH and GPG keys
    PS> ssh -T git@github.com
    ```
  Keep this key for Windows only. Phase 2 creates a separate key for WSL.

## Step 9: Confirm disk space

```powershell
PS> Get-PSDrive C | Select-Object @{n='UsedGB';e={[math]::Round($_.Used/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}}
```

## Phase 1 done: checklist

| Check | Command / place | Expected |
|---|---|---|
| No distros | `wsl --list --verbose` | "no installed distributions" |
| No Docker on Windows | `Get-Command docker` | not found |
| No leftover Docker data | `Test-Path $env:USERPROFILE\.docker` | `False` |
| WSL current | `wsl --version` | 2.x or later |
| Virtualization | Task Manager → CPU | Enabled |
| VM Platform | `dism … VirtualMachinePlatform` | Enabled |
| Rescued data | `%USERPROFILE%\wsl-rescue` | contains what you need |
| Old keys/tokens | GitHub / Azure DevOps | removed |
| Resources | Step 7d | CPU and RAM noted |

**Next:** Phase 2, `02-wsl`: install the hardened `dev` distro.

---

## Troubleshooting

### Inventory and rescue

**A distro won't start for the rescue** (`wsl -d <Name>` errors or hangs). Run `wsl --shutdown` and try again. If it still fails, its files are still reachable from Windows at `\\wsl.localhost\<Name>\` in Explorer, provided WSL can mount the disk. Otherwise, export it as a whole (Step 3) and inspect the export later.

**`\\wsl.localhost\<Name>` isn't reachable.** Start the distro once (`wsl -d <Name> -e true`), then retry. The share only exists while WSL is running.

**Not enough space for a full export.** Skip Step 3 for that distro, and make sure Step 2 was thorough. Or export to an external drive protected with BitLocker To Go: right-click the drive in Explorer → **Turn on BitLocker**. Don't export to an unencrypted SD card or USB stick.

### Removing Docker and other tools

**Rancher Desktop or Podman Desktop is installed.** Treat them like Docker Desktop: uninstall from Settings → Apps, then unregister their distros (`rancher-desktop`, `rancher-desktop-data`, `podman-machine-default`).

**`Get-Command docker` still finds something after Step 4.** Check where it comes from with `(Get-Command docker).Source`, and remove it with the tool that installed it:
- Chocolatey (in an Administrator window): `choco uninstall docker-cli docker-compose`
- winget: `winget uninstall <id>`, found with `winget list docker`
- A manual install: delete the folder and remove it from `PATH`.

**`Remove-Item` fails with "access denied" or "in use".** Docker's background service may still be running. Restart Windows, then repeat Step 4c.

**`wsl --unregister` fails with "in use".** Run `wsl --shutdown`, wait a few seconds, and retry.

### WSL and Windows features

**`wsl --version` isn't recognised.** You have the old built-in WSL. Install the current one with `wsl --install --no-distribution`, then reboot.

**Virtualization shows Disabled.** Enable Intel VT-x (or AMD-V / SVM) in the BIOS/UEFI. On a Lenovo ThinkPad: **Security → Virtualization**. Phase 0, Step 3 explains how to get into the firmware setup.

**VirtualMachinePlatform is Disabled.**

```powershell
PS (Admin)> dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

Then reboot.

**`Get-WindowsOptionalFeature` fails** with *"Class not registered"* ("Klasse nicht registriert") or *"Cannot convert System.Object[]"*. The DISM cmdlets don't work in PowerShell 7, and take only one feature name per call. Use `dism.exe` as in Step 7c.

**The legacy `Microsoft-Windows-Subsystem-Linux` feature shows Disabled.** Not needed. If `wsl --version` works, you're on the current packaged WSL.

### PowerShell

**"A positional parameter cannot be found that accepts argument…".** A pipe `|` at the end of a line was lost when copying. Copy multi-line commands whole, or join them into one line.

**Push fails with 401/403 after revoking tokens.** Git is using the cached, revoked token. Remove it with `cmdkey /delete:git:https://github.com` and push again to sign in.
