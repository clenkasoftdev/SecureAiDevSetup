# Phase 3: Hardened dev container with Claude Code

**Goal:** a reusable `.devcontainer` template that runs Claude Code as a non-root user, behind an outbound firewall, with the repo as the only part of your machine it can see. Copy it into any repo.

**Time:** 30–45 minutes, plus a few minutes for the first image build.
**Run where:** the `dev` distro (`$`), VS Code, and the dev container terminal (`node $`).
**Requires:** phase 2 complete: rootless Docker, the SSH key in `keychain`, VS Code connected to **WSL: dev**.

## Design

The template is Anthropic's reference dev container ([anthropics/claude-code `.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer), commit `0ed9469`), adapted for this setup:

| Kept from the reference | Why |
|---|---|
| Claude Code runs as the non-root user `node` | `--dangerously-skip-permissions` refuses root, and a non-root agent can't change the firewall |
| In-container firewall (`iptables` + `ipset`), started at every container start | Outbound traffic goes only to listed destinations, so a prompt-injected agent has nowhere to send data |
| `node` may run only the firewall script with `sudo` | It can re-apply the firewall, nothing else as root |
| Per-repo volumes for Claude's config and shell history | Sign-in survives rebuilds; repos don't share Claude state |

| Changed | Why |
|---|---|
| Node 24 LTS on Debian 13 (`node:24-trixie`) instead of Node 20 | Node 20 reached end of life in April 2026 |
| Claude Code version **pinned**, auto-updater off | The tool only changes when you change the pin |
| No zsh theme or `git-delta` downloads piped into a shell | Fewer third-party scripts running at build time |
| DNS allowed only to the container's own resolvers | The reference allowed DNS to *any* server |
| No blanket outbound SSH | The reference allowed port 22 to any IP; here SSH reaches only GitHub |
| All IPv6 outbound blocked | The reference didn't filter IPv6 |
| Allowlist in its own file, **baked into the image** | Editing it in the workspace changes nothing until you rebuild, so the agent can't widen it itself |
| MCP connectors from claude.ai off, nonessential traffic off | Fewer outbound channels; no telemetry hosts to allow |
| Memory, CPU and process limits | A runaway agent can't starve WSL |
| `updateRemoteUserUID: false` | Keeps `node` at uid 1000, which the workspace permissions (Step 4) depend on |

**How the repo reaches the container.** Under rootless Docker, container `root` is your WSL user, and container uid 1000 (`node`) is a high, unprivileged ID on the WSL side. Your repo is bind-mounted from `~/src/<repo>`. Access control lists (ACLs) on the repo folder let both your user and that ID read and write everything in it, including files the other one creates.

### Template files

```
03-devcontainer/template/.devcontainer/
├─ devcontainer.json     container settings, limits, volumes, lifecycle commands
├─ Dockerfile            image: Node 24, tools, pinned Claude Code, firewall
├─ init-firewall.sh      the egress firewall (runs at every start)
└─ allowed-domains.txt   outbound allowlist, per repo
```

## Steps

1. [Get the template into WSL](#step-1-get-the-template-into-wsl)
2. [Pin the versions](#step-2-pin-the-versions)
3. [Create a test repo](#step-3-create-a-test-repo)
4. [Give the container access to the repo](#step-4-give-the-container-access-to-the-repo)
5. [Open the repo in the container](#step-5-open-the-repo-in-the-container)
6. [Verify the sandbox](#step-6-verify-the-sandbox)
7. [Sign in to Claude Code](#step-7-sign-in-to-claude-code)
8. [Use it for your repos](#step-8-use-it-for-your-repos)

Problems along the way are covered in [Troubleshooting](#troubleshooting).

---

## Step 1: Get the template into WSL

Clone this runbook repo into `~/src` (created in phase 2), and install the ACL tools used in Step 4:

```bash
$ cd ~/src
$ git clone git@github.com:clenkasoftdev/SecureAiDevSetup.git
$ sudo apt-get install -y acl
```

## Step 2: Pin the versions

Pin the base image and Claude Code in the template itself. Every repo you set up afterwards then starts from the same known versions.

**2a. Base image digest:**

```bash
$ docker pull node:24-trixie
$ docker image inspect node:24-trixie --format '{{index .RepoDigests 0}}'
```

In `template/.devcontainer/Dockerfile`, change the `FROM` line to that value:

```dockerfile
FROM node:24-trixie@sha256:<digest>
```

**2b. Claude Code version:**

```bash
$ docker run --rm node:24-trixie npm view @anthropic-ai/claude-code version
```

In `template/.devcontainer/devcontainer.json`, replace `<version>` with it:

```jsonc
"CLAUDE_CODE_VERSION": "<the version shown>"
```

Commit both changes to the runbook repo, for example on a `docs/03-pin-versions` branch. Repeat this step monthly, or when a Claude Code release you want comes out.

## Step 3: Create a test repo

Use a throwaway repo to prove the template before using it for real work:

```bash
$ mkdir -p ~/src/devcontainer-test && cd ~/src/devcontainer-test
$ git init
$ cp -r ~/src/SecureAiDevSetup/03-devcontainer/template/.devcontainer .
$ echo "# devcontainer test" > README.md
$ git add -A && git commit -m "chore: add dev container"
```

## Step 4: Give the container access to the repo

Work out which WSL user ID the container's `node` becomes, then grant it and yourself full access, including to everything created later:

```bash
$ SUB=$(( $(grep "^$USER:" /etc/subuid | cut -d: -f2) + 999 ))
$ echo "container node = WSL uid $SUB"
$ setfacl -R -m u:$SUB:rwX,d:u:$SUB:rwX,u:$USER:rwX,d:u:$USER:rwX ~/src/devcontainer-test
```

| Part | Meaning |
|---|---|
| `/etc/subuid` start + 999 | Rootless Docker maps container uid 1 to the first ID in your range, so uid 1000 is start + 999 |
| `u:$SUB:rwX` | The container's `node` may read and write existing files (`X`: enter folders, run what's already executable) |
| `d:u:…` | The same rule as a **default**, inherited by every new file and folder |
| `u:$USER:rwX`, `d:u:$USER:rwX` | You keep full access to files `node` creates |

> **Checkpoint:** `getfacl ~/src/devcontainer-test | grep user:` lists your username and the numeric ID, both `rwx`, as plain and `default:` entries.

## Step 5: Open the repo in the container

1. In VS Code (connected to **WSL: dev**): **File → Open Folder** → `/home/<user>/src/devcontainer-test`.
2. Command Palette → **Dev Containers: Reopen in Container**.
3. The first build takes a few minutes. Click **Show Log** in the notification to follow it. Near the end, the firewall prints `Allowed …` for each domain and finishes with **Firewall verification passed**.

> **Checkpoint:** the bottom-left corner shows **Dev Container: devcontainer-test**.

## Step 6: Verify the sandbox

Open a terminal in VS Code. It runs inside the container:

```bash
node $ id                                                 # uid=1000(node)
node $ curl -sS --connect-timeout 5 https://example.com   # fails: blocked
node $ curl -sS https://api.github.com/zen; echo          # a GitHub quote
node $ sudo -l                                            # only /usr/local/bin/init-firewall.sh
node $ sudo id                                            # refused: password prompt / not allowed
node $ ssh -T git@github.com                              # "Hi <you>! …" (key forwarded from WSL)
node $ claude --version                                   # the pinned version
node $ touch /workspace/from-container && git status      # works, shows the new file
```

Then, in a **WSL** terminal outside the container:

```bash
$ cd ~/src/devcontainer-test
$ ls -ln from-container                     # owned by the high uid from Step 4
$ echo "edited in WSL" >> from-container    # works: the ACL lets you edit it
$ rm from-container
```

> **Checkpoint:** every line behaves as commented.

## Step 7: Sign in to Claude Code

```bash
node $ claude
```

Follow the sign-in prompt. If the browser shows a code instead of returning to the terminal, paste it at **Paste code here if prompted**. The login is stored in this repo's `claude-code-config-…` volume and survives rebuilds.

**Autonomous mode:**

```bash
node $ claude --dangerously-skip-permissions
```

Use it only inside this container, and only on repos you trust. The firewall limits *where* data can go, but anything inside the container, including Claude's own login, can still be sent to an allowed destination. Review the diff before you push.

## Step 8: Use it for your repos

For each repo:

```bash
$ cd ~/src && git clone git@github.com:<you>/<repo>.git && cd <repo>
$ cp -r ~/src/SecureAiDevSetup/03-devcontainer/template/.devcontainer .
$ SUB=$(( $(grep "^$USER:" /etc/subuid | cut -d: -f2) + 999 ))
$ setfacl -R -m u:$SUB:rwX,d:u:$SUB:rwX,u:$USER:rwX,d:u:$USER:rwX .
```

1. Add the repo's own destinations (package registries, APIs) to `.devcontainer/allowed-domains.txt`.
2. Add its toolchain to the `Dockerfile` (phase 4 shows .NET).
3. Commit `.devcontainer/`.
4. **Reopen in Container.**

Treat a change to `.devcontainer/` made by the agent like any other code change: review it before rebuilding. The firewall and its allowlist live there.

## Phase 3 done: checklist

| Check | Expected |
|---|---|
| Versions pinned in the template | `FROM …@sha256:…`; `CLAUDE_CODE_VERSION` set |
| Container builds and starts | Log ends with **Firewall verification passed** |
| Non-root | `id` → `uid=1000(node)` |
| Egress | `example.com` blocked; `api.github.com` reachable |
| sudo | Only `init-firewall.sh` |
| SSH | `ssh -T git@github.com` works inside the container |
| Workspace | Both container and WSL can create and edit each other's files |
| Claude Code | Pinned version, signed in |

**Next:** Phase 4, `04-dotnet-hello`: a .NET minimal API built and run in this container.

## What this does and doesn't protect against

| Protected | Not protected |
|---|---|
| Sending data to arbitrary servers | Data sent to an **allowed** destination: anything the agent can read could be pushed to a GitHub repo it can reach, or a gist. Use repo-scoped tokens, and don't put long-lived secrets in the workspace. |
| Reading your other repos, WSL home, Windows files | Destinations sharing an allowed IP. The allowlist works on IP addresses, and CDN-hosted domains share IPs with other sites. |
| Running as root, changing the firewall | Data encoded into DNS lookups through the allowed resolvers. Blocking that needs a filtering DNS proxy. |
| Starving the machine | Mistakes in the repo itself: the agent can edit anything in `/workspace`, including `.git/hooks`. |

## Adding MCP servers

MCP servers work in the container as long as the firewall lets them through. What to do depends on where the server runs:

| Where it runs | Examples | What to do |
|---|---|---|
| **claude.ai connectors** (enabled in your claude.ai account) | Google Drive, Slack, Notion | Off in this template. Set `"ENABLE_CLAUDEAI_MCP_SERVERS": "true"` in `devcontainer.json`, and add `mcp-proxy.anthropic.com` to `allowed-domains.txt`. All connector traffic goes through that one host. |
| **Remote server** (HTTP URL) | A vendor's hosted MCP endpoint | Add the server's host, and any sign-in hosts it redirects to, to `allowed-domains.txt`. |
| **Local server inside the container** (stdio) | An npm or Python MCP package | Install it in the `Dockerfile` at a pinned version. Add the hosts *that server* calls to `allowed-domains.txt`. |
| **On your machine outside the container** | Something running in WSL or on Windows | Not reachable by design: the container can reach neither WSL's `localhost` nor Windows. Run it inside the container, or as a sidecar container on the same network. |

Rebuild the container after any of these changes.

**Install local servers at build time.** Add them to the `Dockerfile` after the Claude Code install, while `USER node` is active:

```dockerfile
RUN npm install -g <mcp-server-package>@<version>
```

Installing at build time pins the version. Running `npx` at start would instead fetch whatever is newest.

**Define the servers per repo** in `.mcp.json` at the repo root (Claude Code's project scope), so they're versioned with the repo. Reference secrets as environment variables, never as literal values:

```json
{
  "mcpServers": {
    "local-example": {
      "command": "<mcp-server-command>",
      "env": { "API_TOKEN": "${EXAMPLE_API_TOKEN}" }
    },
    "remote-example": {
      "type": "http",
      "url": "https://mcp.example.com/mcp"
    }
  }
}
```

**Pass the token into the container** from your WSL environment through `devcontainer.json`, so it never lands in the repo:

```jsonc
"remoteEnv": {
  "EXAMPLE_API_TOKEN": "${localEnv:EXAMPLE_API_TOKEN}"
}
```

Set `EXAMPLE_API_TOKEN` in WSL before opening the container. Use a token scoped to that one repo or service.

**Keep the list short.** Every MCP server is another path out of the sandbox, and its results are untrusted input that can carry prompt injection. Per repo, add only the servers it needs, with read-only or narrowly scoped credentials, at pinned versions.

---

## Troubleshooting

### Build

**`node:24-trixie` not found.** Use `node:24-bookworm` (Debian 12) in the `FROM` line. The packages are the same.

**The build stops with "Set CLAUDE_CODE_VERSION in devcontainer.json".** Step 2b hasn't been done for this repo's copy of the template.

**`--cpus=4`: "range of CPUs is from 0.01 to N".** The WSL VM has fewer CPUs than the container asks for. Lower `--cpus` in `runArgs`, or raise `processors` in `.wslconfig`.

### Firewall

**Start fails with `ERROR: failed to resolve <domain>`.** That domain doesn't exist (any more), or is misspelled in `allowed-domains.txt`. Fix or remove the line, then **Rebuild Container**.

**Start fails at "Fetching GitHub IP ranges".** GitHub's API was briefly unreachable or rate-limited. Run **Dev Containers: Rebuild Container** or restart the container.

**Something the project needs is blocked**: `npm install`, `dotnet restore` or `curl` fails with *"Connection refused"*, *"EHOSTUNREACH"* or *"admin prohibited"*. Find the host from the error message, add it to `.devcontainer/allowed-domains.txt`, then **Rebuild Container**. Edits only take effect on rebuild, because the list is baked into the image.

**Allowed sites start failing after hours or days.** CDN addresses change, and the firewall resolves names only at start. Restart the container (Command Palette → **Dev Containers: Reopen Folder in WSL**, then **Reopen in Container**), or run `sudo /usr/local/bin/init-firewall.sh`.

**VS Code extensions fail to install inside the container.** The error names the download host, often `<publisher>.gallerycdn.vsassets.io`. Add that host to the allowlist and rebuild.

### Workspace permissions

**"Permission denied" writing in `/workspace`.** Step 4 wasn't run on this repo, or used the wrong ID. Check with `getfacl <repo> | grep user:`. Compare the numeric ID with `$(( $(grep "^$USER:" /etc/subuid | cut -d: -f2) + 999 ))`, and re-run the `setfacl` line.

**Some files lost access after copying or extracting into the repo.** Tools that copy permissions (`cp -p`, `tar`, `rsync -a`) can replace the inherited ACL. Re-run the `setfacl` line on the repo.

**Git in the container says "detected dubious ownership".** The `postCreateCommand` didn't run. Run `git config --global --add safe.directory /workspace` in the container terminal.

### Git and SSH

**`ssh -T git@github.com` fails inside the container**, but works in WSL. VS Code forwards the agent from WSL when the container starts. Make sure the key is loaded in WSL (`ssh-add -l` in a WSL terminal), then **Rebuild Container** or reopen it.

**Signed commits fail inside the container** with *"No such file or directory"* for `id_ed25519.pub`. VS Code copies your WSL `.gitconfig` into the container, but not the key file it points to. Point Git at the key itself, which the forwarded agent can sign with. In WSL, run:

```bash
$ git config --global user.signingkey "key::$(cat ~/.ssh/id_ed25519.pub)"
```

Then rebuild the container.

### Claude Code

**An MCP server shows as failed in `/mcp`.**
- **Connection error:** the host it needs isn't in `allowed-domains.txt`.
- **"command not found":** the package isn't installed in the image.
- **Authentication error:** the environment variable isn't set inside the container. Check with `printenv EXAMPLE_API_TOKEN`.

Fix it, then rebuild.

**The browser sign-in never returns to the terminal.** Copy the code shown in the browser and paste it at **Paste code here if prompted**.

**`--dangerously-skip-permissions` is refused because it's running as root.** The terminal isn't running as `node`. Check that `remoteUser` is `node` in `devcontainer.json`, and that `id` shows uid 1000.
