# Recipe: .NET 10 SDK

Proven in phase 4.

## Pin

```bash
$ docker pull mcr.microsoft.com/dotnet/sdk:10.0
$ docker image inspect mcr.microsoft.com/dotnet/sdk:10.0 --format '{{index .RepoDigests 0}}'
```

## [A] Build stage

```dockerfile
# .NET SDK, copied from Microsoft's official image (pinned)
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:<digest> AS dotnet-sdk
```

## [B] Debian packages

```dockerfile
libicu76
```

## [C] Root install

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

## [E] Allowlist

```text
# NuGet
api.nuget.org
```

Add private feeds too, for example `pkgs.dev.azure.com`.

## [F] Editor

```jsonc
"extensions": ["ms-dotnettools.csharp"],
"settings": {
  "dotnetAcquisitionExtension.existingDotnetPath": [
    { "extensionId": "ms-dotnettools.csharp", "path": "/usr/share/dotnet/dotnet" }
  ]
}
```

## Verify

```bash
node $ dotnet --version
node $ dotnet --list-runtimes
node $ curl -sS -o /dev/null -w '%{http_code}\n' https://api.nuget.org/v3/index.json    # 200
```

## Troubleshooting

See phase 4's Troubleshooting: ICU, stage order, NuGet through the firewall, and the C# extension.
