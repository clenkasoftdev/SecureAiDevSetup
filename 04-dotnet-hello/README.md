# Phase 4: .NET 10 minimal API in the dev container

**Goal:** prove the whole setup end to end with a real project: a .NET 10 minimal API with tests, built and run inside the phase 3 dev container, reached from your Windows browser, and changed by Claude Code, all behind the firewall.

**Time:** 30–45 minutes.
**Run where:** the `dev` distro (`$`), VS Code, and the dev container terminal (`node $`).
**Requires:** phase 3 complete, and `~/src/SecureAiDevSetup` on an up-to-date `main`.

## Design

A repo adds a toolchain to the phase 3 template in two places:

| Where | What | Why there |
|---|---|---|
| `Dockerfile` | Install the .NET SDK | Image builds run before the firewall exists, so build-time downloads aren't blocked |
| `allowed-domains.txt` | Allow NuGet | `dotnet restore` runs while you work, behind the firewall |

**How the SDK gets in.** The Dockerfile copies the SDK out of Microsoft's official image `mcr.microsoft.com/dotnet/sdk:10.0`, pinned by digest, in a separate build stage. There's no install script and no extra apt repository, and the digest pins exactly which SDK build you get. The SDK is a self-contained folder; it only needs the ICU library from Debian for globalization.

## Steps

1. [Create the repo](#step-1-create-the-repo)
2. [Add the .NET SDK to the image](#step-2-add-the-net-sdk-to-the-image)
3. [Allow NuGet and configure VS Code](#step-3-allow-nuget-and-configure-vs-code)
4. [Open the repo in the container](#step-4-open-the-repo-in-the-container)
5. [Create the minimal API and tests](#step-5-create-the-minimal-api-and-tests)
6. [Run it and open it from Windows](#step-6-run-it-and-open-it-from-windows)
7. [Let Claude Code make a change](#step-7-let-claude-code-make-a-change)
8. [Commit and push](#step-8-commit-and-push)

Problems along the way are covered in [Troubleshooting](#troubleshooting).

---

## Step 1: Create the repo

```bash
$ mkdir -p ~/src/dotnet-hello && cd ~/src/dotnet-hello
$ git init
$ cp -r ~/src/SecureAiDevSetup/03-devcontainer/template/.devcontainer .
$ SUB=$(( $(grep "^$USER:" /etc/subuid | cut -d: -f2) + 999 ))
$ setfacl -R -m u:$SUB:rwX,d:u:$SUB:rwX,u:$USER:rwX,d:u:$USER:rwX .
```

The template already has the base image digest and Claude Code version pinned in phase 3.

## Step 2: Add the .NET SDK to the image

**2a. Get the SDK image digest:**

```bash
$ docker pull mcr.microsoft.com/dotnet/sdk:10.0
$ docker image inspect mcr.microsoft.com/dotnet/sdk:10.0 --format '{{index .RepoDigests 0}}'
$ docker run --rm mcr.microsoft.com/dotnet/sdk:10.0 dotnet --version
```

Note the digest and the SDK version (for example `10.0.1xx`).

**2b. Edit `.devcontainer/Dockerfile`.** Make three changes.

At the very top, **before** the existing `FROM node:24-trixie@sha256:…` line, add the SDK stage:

```dockerfile
# .NET SDK, copied from Microsoft's official image (pinned)
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:<digest from 2a> AS dotnet-sdk
```

In the `apt-get install` list, add the ICU library .NET needs:

```dockerfile
      openssh-client iptables ipset iproute2 dnsutils aggregate libicu76 \
```

Just **before** the line `COPY init-firewall.sh /usr/local/bin/init-firewall.sh` (where `USER root` is active), add:

```dockerfile
# .NET SDK
COPY --from=dotnet-sdk /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false
```

| Setting | Effect |
|---|---|
| `DOTNET_CLI_TELEMETRY_OPTOUT` | No usage data sent to Microsoft (it would be blocked anyway) |
| `DOTNET_NOLOGO` | No first-run banner |
| `DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE` | No background checks for workload updates |
| `DOTNET_GENERATE_ASPNET_CERTIFICATE=false` | No HTTPS development certificate. The app runs on plain HTTP inside the container; VS Code's port forwarding carries it to Windows. |

## Step 3: Allow NuGet and configure VS Code

**3a.** Add NuGet to the end of `.devcontainer/allowed-domains.txt`:

```text
# NuGet: package restore
api.nuget.org
```

**3b.** In `.devcontainer/devcontainer.json`, add the C# extension, and point it at the SDK in the image so it doesn't try to download its own .NET runtime:

```jsonc
"customizations": {
  "vscode": {
    "extensions": ["anthropic.claude-code", "ms-dotnettools.csharp"],
    "settings": {
      "terminal.integrated.defaultProfile.linux": "bash",
      "dotnetAcquisitionExtension.existingDotnetPath": [
        { "extensionId": "ms-dotnettools.csharp", "path": "/usr/share/dotnet/dotnet" }
      ]
    }
  }
},
```

## Step 4: Open the repo in the container

1. VS Code (**WSL: dev**) → **File → Open Folder** → `/home/<user>/src/dotnet-hello`.
2. Command Palette → **Dev Containers: Reopen in Container**.
3. Wait for **Firewall verification passed** in the log.

```bash
node $ dotnet --version                    # the SDK version from Step 2a
node $ dotnet --list-runtimes              # Microsoft.AspNetCore.App 10.x and Microsoft.NETCore.App 10.x
```

> **Checkpoint:** both commands show .NET 10.

## Step 5: Create the minimal API and tests

**5a. Scaffold** a solution with an API project and a test project:

```bash
node $ cd /workspace
node $ dotnet new gitignore
node $ dotnet new sln -n DotnetHello
node $ dotnet new web   -n Hello.Api       -o src/Hello.Api
node $ dotnet new xunit -n Hello.Api.Tests -o tests/Hello.Api.Tests
node $ dotnet sln add src/Hello.Api tests/Hello.Api.Tests
node $ dotnet add tests/Hello.Api.Tests reference src/Hello.Api
node $ dotnet add tests/Hello.Api.Tests package Microsoft.AspNetCore.Mvc.Testing
```

The last command, and the test project itself, pull packages from NuGet **through the firewall**. This is the real test of the allowlist.

**5b. The API.** Replace `src/Hello.Api/Program.cs` with:

```csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/hello", (string? name) =>
    Results.Ok(new { message = $"Hello, {name ?? "world"}!" }));

app.Run();

public partial class Program { }
```

`public partial class Program` makes the app's entry point visible to the test project.

**5c. A test.** Delete `tests/Hello.Api.Tests/UnitTest1.cs`, and create `tests/Hello.Api.Tests/HelloEndpointTests.cs`:

```csharp
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Hello.Api.Tests;

public class HelloEndpointTests(WebApplicationFactory<Program> factory)
    : IClassFixture<WebApplicationFactory<Program>>
{
    [Fact]
    public async Task Hello_without_name_greets_the_world()
    {
        var greeting = await factory.CreateClient().GetFromJsonAsync<Greeting>("/hello");
        Assert.Equal("Hello, world!", greeting!.Message);
    }

    [Fact]
    public async Task Hello_greets_by_name()
    {
        var greeting = await factory.CreateClient().GetFromJsonAsync<Greeting>("/hello?name=Clement");
        Assert.Equal("Hello, Clement!", greeting!.Message);
    }

    private sealed record Greeting(string Message);
}
```

**5d. Build and test:**

```bash
node $ dotnet test
```

> **Checkpoint:** `Passed! - Failed: 0, Passed: 2`.

## Step 6: Run it and open it from Windows

```bash
node $ dotnet run --project src/Hello.Api --urls http://127.0.0.1:5080
```

VS Code detects the port and forwards it. A notification offers **Open in Browser**, and the **Ports** panel lists `5080`. In your **Windows** browser, open:

```
http://localhost:5080/hello?name=Clement
```

> **Checkpoint:** the browser shows `{"message":"Hello, Clement!"}`.

The request travels Windows browser → VS Code → WSL → container loopback. The app listens only on the container's own `127.0.0.1`, and no Docker port is published.

Stop the app with `Ctrl+C`.

## Step 7: Let Claude Code make a change

```bash
node $ claude
```

Ask it, for example:

> Add a `GET /time` endpoint to Hello.Api that returns the current UTC time as ISO 8601 in a JSON object `{ "utc": "..." }`, with a test in Hello.Api.Tests. Run `dotnet test` and make sure everything passes.

Approve its steps as it asks. When it's done:

```bash
node $ git diff --stat
node $ dotnet test
```

> **Checkpoint:** the diff shows the new endpoint and test, and `dotnet test` passes with 3 tests.

This shows the agent working end to end inside the sandbox: editing files, restoring packages through the firewall, and running the tests.

## Step 8: Commit and push

```bash
node $ git add -A
node $ git commit -m "feat: hello minimal API with tests"
```

To keep it on GitHub, create an empty repo `dotnet-hello` there, then:

```bash
node $ git remote add origin git@github.com:<you>/dotnet-hello.git
node $ git push -u origin main
```

Pushing from inside the container uses your WSL key through the forwarded agent. The container never holds the key.

## Phase 4 done: checklist

| Check | Expected |
|---|---|
| SDK pinned | `FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:…` in the Dockerfile |
| .NET in container | `dotnet --version` shows 10.0.x |
| NuGet through firewall | Package added; `dotnet test` passes |
| App reachable from Windows | `http://localhost:5080/hello?name=…` returns JSON |
| Claude Code | Added `/time` with a test; 3 tests pass |
| Git | Committed (and pushed) from inside the container |

**Next:** Phase 5, `05-toolchains`: recipes for .NET, Python + uv, PowerShell and Azure CLI.

---

## Troubleshooting

### Build

**`libicu76` not found.** The base image isn't Debian 13. On Debian 12 (`node:24-bookworm`), use `libicu72`. To check which Debian the base uses: `docker run --rm node:24-trixie cat /etc/debian_version`.

**`COPY --from=dotnet-sdk` fails with "not found".** The `FROM … AS dotnet-sdk` line is missing, misspelled, or placed **after** the main `FROM` line. It must be the first line of the Dockerfile.

**`dotnet` fails with "Couldn't find a valid ICU package".** `libicu76` wasn't installed. Check the `apt-get install` list and rebuild.

### NuGet and the firewall

**`dotnet add package` or `dotnet restore` fails with "Unable to load the service index" or "Connection refused".**
- Check that `api.nuget.org` is in `allowed-domains.txt` and that you **rebuilt** after adding it.
- If it was there and worked earlier, NuGet's CDN addresses changed since the container started. Run `sudo /usr/local/bin/init-firewall.sh`.

**Restore needs other hosts** (private feeds, Azure Artifacts). Add each feed's host, for example `pkgs.dev.azure.com`, to `allowed-domains.txt` and rebuild.

**`dotnet new` prints a warning about checking for template updates.** It tried to reach a host that isn't allowed. The warning is harmless: templates still work.

### VS Code

**The C# extension says it can't acquire or find .NET.** The `existingDotnetPath` setting from Step 3b is missing or misspelled. Check `devcontainer.json`, then **Rebuild Container**. If it names a different download host, that's the extension trying to fetch extra components: add the host to `allowed-domains.txt` and rebuild.

**Port 5080 isn't forwarded automatically.** Open the **Ports** panel → **Forward a Port** → `5080`.

**The browser can't connect, although the app runs.** The app must listen on `127.0.0.1` or `localhost` inside the container, as in Step 6. Also check that phase 2's `.wslconfig` still has `localhostForwarding=true`.

### Tests

**Tests fail with "Can't find 'Program'" or an inaccessible `Program` type.** The `public partial class Program { }` line is missing from `Program.cs`.

**Tests fail to deserialize: `Message` is null.** The JSON property is `message` (camelCase), and `GetFromJsonAsync` matches names case-insensitively. Check that the record's property is named `Message` and that the endpoint returns `message`.
