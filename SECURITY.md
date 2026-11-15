# Security policy

This repository is a runbook for a hardened development environment, so security problems in it matter: a wrong firewall rule or a missing step could leave users less protected than the guide claims.

## Reporting a problem

Please **don't open a public issue** for a security problem. Report it privately instead, through GitHub: on this repository, go to **Security → Report a vulnerability** (private vulnerability reporting).

Please include:

- what you found, and which file and step it affects
- how to reproduce it, or why you believe it's exploitable
- the versions involved (repository tag, Windows/WSL, Docker), if relevant

You'll get an acknowledgement within a few days. Fixes go in through a pull request, with a patch tag (for example `v0.4.1`) and a note in the release.

## Scope

In scope: the guides and the files in this repository, especially the firewall (`init-firewall.sh`), the dev container configuration and the hardening steps.

Out of scope: vulnerabilities in third-party products (Windows, WSL, Docker, VS Code, Claude Code, Azure). Please report those to their vendors.

## Known limits

The guides document what the setup does *not* protect against, for example domain fronting and DNS tunnelling through allowed resolvers. See "What this does and doesn't protect against" in `03-devcontainer/README.md`. Reports that improve on those limits are welcome.
