# Phase 2: Install the hardened WSL distro with rootless Docker

**Goal:** one dedicated Ubuntu distro, `dev`, that can't reach your Windows files or launch Windows programs, with Docker Engine running **rootless** inside it, ready for the dev containers in phase 3.

**Time:** 45–60 minutes.
**Run where:** Windows PowerShell for Steps 1–2, then the `dev` distro (`$`).
**Requires:** phases 0 and 1 complete: no other distros, no Docker Desktop.

## Design

```
Windows ── .wslconfig ──► WSL VM (8 GB, 6 CPUs, NAT, no GUI, no nested virtualization)
                            └─ distro "dev"   wsl.conf: no C:\ mount, no Windows interop, systemd
                                 └─ Docker Engine, rootless: dockerd runs as your user, not root
                                      └─ dev containers (phase 3)
```

| Decision | Why |
|---|---|
| **Dedicated distro** | Nothing else lives in it. You know exactly what's installed, and you can delete and rebuild it from this guide. |
| **No automount of `C:\`** | A process that escapes a container, or a malicious package in WSL, can't read or encrypt your Windows files. |
| **No interop** | Linux processes can't start `cmd.exe`, `powershell.exe` or other Windows programs. VS Code still connects, because it reaches into WSL from the Windows side. |
| **Rootless Docker** | The Docker daemon runs as your user. A container escape lands as an unprivileged user, and there's no `docker` group that is secretly equivalent to root. |
| **Docker Engine, not Docker Desktop or `wslc`** | Free, open source and lives only in this distro. The VS Code Dev Containers extension needs the Docker CLI, which `wslc` doesn't provide. |
| **No GUI, no nested virtualization** | Features this setup doesn't use, so less attack surface. |

**One exception to "no Windows files":** the VS Code WSL extension starts by running a script from its extension folder on C:, and reads the VS Code server archive it downloads on Windows. Step 3 mounts exactly those two folders, **read-only**. They contain no credentials, and read-only means nothing in WSL can plant code in them for Windows-side VS Code to run.

The Windows-side setting `hostFileSystemAccess` would switch off drive mounting for *all* distros, and with it these two mounts, so it stays on. Disabling automount in `wsl.conf` is enough: with rootless Docker, nothing that escapes a container has the root rights needed to mount a Windows drive.

## Steps

1. [Configure the WSL VM](#step-1-configure-the-wsl-vm)
2. [Install the `dev` distro](#step-2-install-the-dev-distro)
3. [Harden the distro](#step-3-harden-the-distro)
4. [Update and enable automatic security updates](#step-4-update-and-enable-automatic-security-updates)
5. [Install Docker Engine](#step-5-install-docker-engine)
6. [Switch Docker to rootless](#step-6-switch-docker-to-rootless)
7. [Verify container firewall support](#step-7-verify-container-firewall-support)
8. [Set up Git and an SSH key](#step-8-set-up-git-and-an-ssh-key)
9. [Connect VS Code](#step-9-connect-vs-code)

Problems along the way are covered in [Troubleshooting](#troubleshooting).

---

## Step 1: Configure the WSL VM

`.wslconfig` applies to the WSL VM shared by all distros. Size it from phase 1 Step 7d: about half the RAM, and all CPUs but two.

```powershell
PS> notepad "$env:USERPROFILE\.wslconfig"
```

Contents, for 8 logical processors and 16 GB RAM:

```ini
[wsl2]
memory=8GB
processors=6
swap=4GB
networkingMode=nat
localhostForwarding=true
guiApplications=false
nestedVirtualization=false
```

| Setting | Effect |
|---|---|
| `memory`, `processors`, `swap` | Caps what WSL can take, so a runaway build or agent can't freeze Windows |
| `networkingMode=nat` | WSL sits behind a private network on your PC, not on your LAN |
| `localhostForwarding=true` | Dev servers in WSL are reachable from your Windows browser at `localhost` (loopback only, not the LAN) |
| `guiApplications=false` | No Linux GUI apps (WSLg) |
| `nestedVirtualization=false` | No VMs inside WSL |

Apply it:

```powershell
PS> wsl --shutdown
```

## Step 2: Install the `dev` distro

Run WSL from a **normal** (not Administrator) PowerShell window, now and from here on. WSL starts in the launching shell's folder, and while `C:` is still mounted, it accesses Windows files with that window's rights.

```powershell
PS> wsl --install Ubuntu-24.04 --name dev
```

When it asks, create your Linux username and password. The password is what `sudo` asks for; use a real one.

Ubuntu 24.04 LTS is supported until 2029, and Docker supports it fully.

Leave the new shell open. If it doesn't open by itself:

```powershell
PS> wsl -d dev --cd ~
```

`--cd ~` starts in your Linux home instead of the Windows folder PowerShell happens to be in.

> **Checkpoint:** `wsl --list --verbose` shows `dev`, `VERSION 2`.

## Step 3: Harden the distro

**3a. Find your Windows username** exactly as Windows spells it, including upper and lower case. VS Code uses it in its paths.

```powershell
PS> $env:USERNAME
```

In the commands below, replace `<WinUser>` with it.

**3b. Create the mount points for VS Code's two folders:**

```bash
$ sudo mkdir -p /mnt/c/Users/<WinUser>/.vscode/extensions /mnt/c/Users/<WinUser>/vscode-remote-wsl
```

**3c. Write `/etc/wsl.conf`:**

```bash
$ sudo nano /etc/wsl.conf
```

Contents:

```ini
[boot]
systemd=true
command="mount -t drvfs 'C:\\Users\\<WinUser>\\.vscode\\extensions' /mnt/c/Users/<WinUser>/.vscode/extensions -o ro,noatime; mount -t drvfs 'C:\\Users\\<WinUser>\\vscode-remote-wsl' /mnt/c/Users/<WinUser>/vscode-remote-wsl -o ro,noatime"

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=<your Linux username>
```

Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`.

In `wsl.conf`, a backslash inside quotes starts an escape sequence, so Windows paths need **doubled** backslashes (`C:\\Users\\…`). WSL turns each `\\` back into one `\` before running the command.

| Section | Effect |
|---|---|
| `[boot] systemd=true` | Runs systemd, which rootless Docker needs |
| `[boot] command` | At start, mounts only VS Code's two folders, read-only |
| `[automount] enabled=false` | No `/mnt/c` drive: the rest of C: isn't mounted |
| `[automount] mountFsTab=false` | `/etc/fstab` isn't processed: nothing else gets mounted at start |
| `[interop] enabled=false` | Linux can't launch Windows `.exe` files |
| `[interop] appendWindowsPath=false` | Windows folders aren't added to the Linux `PATH` |
| `[user] default` | Opens as your user, not root |

**3d. Restart the distro** so the settings apply:

```powershell
PS> wsl --terminate dev
PS> wsl -d dev --cd ~
```

No message about `/etc/wsl.conf` should appear at start.

**3e. Verify:**

```bash
$ mount | grep ' /mnt/'                         # /mnt/wsl, plus two drvfs mounts marked ro
$ ls -A /mnt/c/Users/<WinUser>                  # only .vscode and vscode-remote-wsl
$ touch /mnt/c/Users/<WinUser>/vscode-remote-wsl/x   # "Read-only file system"
$ cmd.exe /c ver                                # cmd.exe: command not found
$ ps -p 1 -o comm=                              # systemd
$ stat -fc %T /sys/fs/cgroup                    # cgroup2fs
```

> **Checkpoint:** the only drvfs mounts are VS Code's two folders, both `ro`, and nothing else from C: is visible. `cmd.exe` doesn't run, PID 1 is `systemd`, and the cgroup filesystem is `cgroup2fs`.

`/mnt/wsl` and `/mnt/wslg` belong to WSL itself and hold no Windows files: leave them.

From now on, move files between Windows and `dev` from the Windows side: `\\wsl.localhost\dev\home\<user>` in Explorer.

Optionally, silence Ubuntu's daily login banner with `touch ~/.hushlogin`.

## Step 4: Update and enable automatic security updates

```bash
$ sudo apt-get update && sudo apt-get -y full-upgrade
$ sudo apt-get install -y unattended-upgrades ca-certificates curl gnupg git jq
$ sudo dpkg-reconfigure -plow unattended-upgrades     # answer "Yes"
```

> **Checkpoint:** `cat /etc/apt/apt.conf.d/20auto-upgrades` shows both lines set to `"1"`.

## Step 5: Install Docker Engine

Install from Docker's own repository, and check the signing key's fingerprint before trusting it.

```bash
$ sudo install -m 0755 -d /etc/apt/keyrings
$ curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
$ gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc
```

The fingerprint must be **`9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88`**. That's Docker's published release key. If it differs, stop and delete the file.

```bash
$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
$ sudo apt-get update
$ sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras uidmap dbus-user-session slirp4netns
```

## Step 6: Switch Docker to rootless

**6a. Turn off the root daemon.** The package starts Docker as root. Stop it for good, so the only daemon is the one you run as yourself.

```bash
$ sudo systemctl disable --now docker.service docker.socket containerd.service
$ sudo rm -f /var/run/docker.sock
```

Don't add yourself to the `docker` group. That group gives full root access through the root daemon's socket.

**6b. Let your user's services use resource limits.** This lets `--memory` and `--cpus` work for rootless containers:

```bash
$ sudo mkdir -p /etc/systemd/system/user@.service.d
$ printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
$ sudo systemctl daemon-reload
$ sudo loginctl enable-linger "$USER"
```

`enable-linger` keeps your user's services, including the rootless Docker daemon, running without an open terminal.

**6c. Install rootless Docker:**

```bash
$ dockerd-rootless-setuptool.sh install
$ systemctl --user enable --now docker
$ docker context use rootless
```

**6d. Verify:**

```bash
$ docker info --format '{{.SecurityOptions}}'      # contains name=rootless
$ docker info --format '{{.CgroupVersion}} {{.CgroupDriver}}'   # 2 systemd
$ docker run --rm hello-world
$ ls -l /var/run/docker.sock                       # No such file or directory
```

> **Checkpoint:** `rootless` appears in the security options, the cgroup version is `2`, `hello-world` prints its message, and there's no root Docker socket.

## Step 7: Verify container firewall support

Phase 3's dev containers enforce an outbound allowlist with `iptables` and `ipset` *inside* the container. Check now that the WSL kernel and rootless Docker support that:

```bash
$ docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW ubuntu:24.04 bash -c '
    apt-get update -qq && apt-get install -y -qq iptables ipset >/dev/null &&
    ipset create t hash:net && ipset add t 140.82.112.0/20 &&
    iptables -A OUTPUT -m set --match-set t dst -j ACCEPT &&
    echo FIREWALL-OK'
```

> **Checkpoint:** the last line is `FIREWALL-OK`.

## Step 8: Set up Git and an SSH key

This key is for WSL and the dev containers. It's separate from the Windows key you set up in phase 1. Dev containers never hold it: VS Code forwards the agent, so a container can use the key while you're connected but can't copy it.

```bash
$ git config --global user.name  "<Your Name>"
$ git config --global user.email "<you@example.com>"
$ git config --global init.defaultBranch main

$ ssh-keygen -t ed25519 -C "$(hostname)-wsl-dev" -f ~/.ssh/id_ed25519      # set a passphrase
$ sudo apt-get install -y keychain
$ echo 'eval "$(keychain --eval --quiet --agents ssh id_ed25519)"' >> ~/.bashrc
$ source ~/.bashrc                                                          # asks for the passphrase once
$ cat ~/.ssh/id_ed25519.pub
```

Add the public key on GitHub → Settings → **SSH and GPG keys** → **New SSH key**, titled for example "afric-imp WSL dev".

Optionally, use the same key to sign commits, so GitHub shows them as **Verified**:

```bash
$ git config --global gpg.format ssh
$ git config --global user.signingkey "key::$(cat ~/.ssh/id_ed25519.pub)"
$ git config --global commit.gpgsign true
```

`key::` stores the public key itself rather than a file path. VS Code copies your Git config into dev containers (phase 3) but not the key file, so a path would break signing there. With `key::`, the forwarded agent signs, in WSL and in the container alike.

For signing, add the key on GitHub a second time, choosing **Key type: Signing Key**.

```bash
$ ssh -T git@github.com
```

> **Checkpoint:** *"Hi <you>! You've successfully authenticated…"*

## Step 9: Connect VS Code

1. On Windows, install VS Code's **WSL** and **Dev Containers** extensions (publisher: Microsoft).
2. Create a working folder inside `dev`. Repos live on the Linux filesystem, never on `C:`:
   ```bash
   $ mkdir -p ~/src
   ```
3. In VS Code: Command Palette (`Ctrl+Shift+P`) → **WSL: Connect to WSL using Distro…** → **dev**.
4. **File → Open Folder** → `/home/<user>/src`.
5. Open a terminal (`` Ctrl+` ``) and check:
   ```bash
   $ docker context show       # rootless
   $ docker ps                 # empty list, no error
   ```

> **Checkpoint:** the bottom-left corner of VS Code shows **WSL: dev**, and `docker ps` works in its terminal.

`code .` typed inside WSL doesn't work, because it needs interop. Open folders from VS Code instead, as above.

## Phase 2 done: checklist

| Check | Command | Expected |
|---|---|---|
| Only one distro | `wsl --list --verbose` (Windows) | `dev`, version 2 |
| VM limits | `.wslconfig` | memory, processors, swap set; GUI and nested virtualization off |
| No Windows drive | `mount \| grep ' /mnt/'` | only `/mnt/wsl` and VS Code's two `ro` mounts |
| No interop | `cmd.exe /c ver` | fails |
| systemd, cgroup v2 | `ps -p 1 -o comm=`, `stat -fc %T /sys/fs/cgroup` | `systemd`, `cgroup2fs` |
| Auto security updates | `/etc/apt/apt.conf.d/20auto-upgrades` | both `"1"` |
| Rootless Docker | `docker info --format '{{.SecurityOptions}}'` | contains `rootless` |
| No root daemon | `ls /var/run/docker.sock` | not found |
| Firewall support | Step 7 | `FIREWALL-OK` |
| SSH to GitHub | `ssh -T git@github.com` | authenticated |
| VS Code | status bar | **WSL: dev**, `docker ps` works |

**Next:** Phase 3, `03-devcontainer`: the hardened dev container template.

---

## Troubleshooting

### Installing the distro

**`wsl --install` rejects `--name`.** Older WSL versions don't support it. Run `wsl --update` and retry.

**`wsl --list --online` doesn't list `Ubuntu-24.04`.** Use the exact name it does list for 24.04, or a newer LTS once Docker's install page lists it as supported.

### VS Code

**VS Code hangs at "Starting VS Code in WSL (dev): Downloading server"**, or shows *"WSL Daemon exited with code 0"*. Its log (Output panel → **WSL**) runs `"$VSCODE_WSL_EXT_LOCATION/scripts/wslServer.sh"` and stops. One of the two mounts from Step 3 is missing or at the wrong path. Check:
- `mount | grep drvfs` shows both mounts.
- `<WinUser>` matches `$env:USERNAME` exactly, including case.
- The mount points exist (Step 3b).

Then run `wsl --terminate dev` and reconnect.

**At start, WSL prints `Invalid escaped character: 'U' in /etc/wsl.conf`.** The Windows paths in `command=` have single backslashes. Double them (`C:\\Users\\…`), as in Step 3c. Until it's fixed, the boot command doesn't run, so VS Code can't connect.

**WSL starts in `/mnt/c/Windows/System32`.** It was launched from an Administrator PowerShell, whose default folder that is, before Step 3 removed the C: mount. Close it and use `wsl -d dev --cd ~` from a normal PowerShell window.

**`docker ps` fails in VS Code's terminal** but works in a normal WSL shell. VS Code's server started before Docker was set up. Command Palette → **WSL: Close Remote Connection**, then reconnect.

### Docker

**`dockerd-rootless-setuptool.sh` reports missing `newuidmap`, or `/etc/subuid` has no entry.** Install `uidmap`, then add the ID ranges:

```bash
$ sudo apt-get install -y uidmap
$ grep "^$USER:" /etc/subuid || sudo usermod --add-subuids 100000-165535 "$USER"
$ grep "^$USER:" /etc/subgid || sudo usermod --add-subgids 100000-165535 "$USER"
```

Then run the setup tool again.

**The setup tool fails with "user namespaces are restricted" (AppArmor).** Ubuntu 24.04 can restrict unprivileged user namespaces when AppArmor is active. Allow it for rootlesskit only:

```bash
$ sudo tee /etc/apparmor.d/usr.bin.rootlesskit >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>
"/usr/bin/rootlesskit" flags=(unconfined) {
  userns,
  include if exists <local/usr.bin.rootlesskit>
}
EOF
$ sudo systemctl restart apparmor.service
```

**`systemctl --user` fails with "Failed to connect to bus".** The user session isn't running yet. Run `wsl --terminate dev` in PowerShell, reopen the distro, and retry.

**`docker info` doesn't show `rootless`, or `docker` says "permission denied … /var/run/docker.sock".** The CLI is still pointed at the root daemon. Run `docker context use rootless`, and check that `DOCKER_HOST` isn't set anywhere (`echo $DOCKER_HOST` should print nothing).

**The cgroup check shows `tmpfs` instead of `cgroup2fs`,** or `docker info` reports cgroup version 1. Force cgroup v2 in `.wslconfig` under `[wsl2]`:

```ini
kernelCommandLine=cgroup_no_v1=all
```

Then run `wsl --shutdown` and reopen.

**`--memory` or `--cpus` are ignored**, with a warning about cgroup controllers. Step 6b didn't take effect. Check `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers` shows `memory` and `pids`. If it doesn't, redo 6b and run `wsl --terminate dev`.

### Container firewall

**Step 7 fails with "Kernel error received: Operation not supported" or `ipset` errors.** The WSL kernel lacks the `ip_set` module, or it isn't loaded. Run `wsl --update` (Windows) for the current kernel, then retry. If it still fails, phase 3 uses its fallback design, an egress proxy, instead of the in-container firewall.

**Step 7 can't download packages** ("Temporary failure resolving"). This is container DNS under rootless networking. Run `docker run --rm busybox nslookup archive.ubuntu.com`. If that fails too, restart the daemon with `systemctl --user restart docker` and retry.

### SSH and Git

**`ssh -T git@github.com` says "Permission denied (publickey)".** The key isn't in the agent, or isn't on GitHub. Check `ssh-add -l` lists it, and that the public key was added as an **Authentication** key.

**Keychain asks for the passphrase in every new terminal.** That's expected after a restart of the distro: once per WSL session, not per terminal.
