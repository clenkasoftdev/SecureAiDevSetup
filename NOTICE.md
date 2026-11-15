# Notices

## Third-party material

The dev container files below are **based on Anthropic's reference dev container** in the [anthropics/claude-code](https://github.com/anthropics/claude-code/tree/main/.devcontainer) repository (commit `0ed9469`), and have been modified substantially. Anthropic's repository is not open source: it states *"© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service."*

| File | Relationship to the reference |
|---|---|
| `03-devcontainer/template/.devcontainer/Dockerfile` | Based on the reference `Dockerfile`; base image, toolchain, pinning and proxy changes |
| `03-devcontainer/template/.devcontainer/devcontainer.json` | Based on the reference `devcontainer.json`; limits, settings and environment changes |
| `03-devcontainer/template/.devcontainer/init-firewall.sh` | Started from the reference `init-firewall.sh`; redesigned (name-based SNI filtering, fail-closed, refresh), with some of the reference's structure retained |
| `03-devcontainer/variants/*/.devcontainer/Dockerfile`, `devcontainer.json`, `init-firewall.sh` | Derived from the template files above |

**These files are not covered by this repository's MIT license.** The author's modifications are provided for reference; your use of the material derived from Anthropic's reference is subject to Anthropic's terms. Anthropic's documentation describes copying the reference `.devcontainer` into your own repository as a way to use it: see [Development containers](https://code.claude.com/docs/en/devcontainer).

## Trademarks

Claude and Anthropic are trademarks of Anthropic PBC. Microsoft, Windows, Azure, Azure DevOps, Visual Studio Code and PowerShell are trademarks of the Microsoft group of companies. Docker is a trademark of Docker, Inc. Lenovo and ThinkPad are trademarks of Lenovo. Other names may be trademarks of their respective owners.

This project is independent and is **not affiliated with, endorsed by or sponsored by** Anthropic, Microsoft, Docker or any other company named here.
