# Contributing

This is a personal, tested runbook: every step in `main` has been run on a real machine before it was merged. That shapes how contributions work.

## Welcome

- **Issues** for steps that fail, are unclear or are out of date (a changed Windows menu, a new WSL or Docker version, a moved download), with the output you saw.
- **Suggestions** for hardening, as issues first, so the design can be discussed before anything is written.
- **Security problems:** please follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Pull requests

Pull requests are welcome for corrections and small improvements. Larger changes, such as a new phase or a firewall change, should start as an issue.

For any pull request:

- Follow the repository's structure: one phase per folder, a straight-line main path with checkpoints, and problems in a **Troubleshooting** section.
- Say **what you tested, and on what** (Windows version, WSL version, Docker version, hardware), as in the existing pull requests.
- Don't include personal details (usernames, machine names, tenant names) or anything secret.
- Changes to `init-firewall.sh` need a description of how they were tested, including what is blocked as well as what is allowed.

By contributing, you agree that your contributions are licensed under the same terms as the files you change (see [LICENSE](LICENSE), [LICENSE-docs.md](LICENSE-docs.md) and [NOTICE.md](NOTICE.md)).
