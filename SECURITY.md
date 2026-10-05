# Security

Creo runs only on your Mac. It reads Claude Code and Codex session logs, never edits them
(except moving one to the Trash when you ask), and sends nothing about you anywhere. Its only
network requests are an unauthenticated check for the latest GitHub release and reading your
plan usage: Claude's from Anthropic with the sign-in Claude Code already keeps in your Keychain
(used for that request, never stored), and Codex's by asking the Codex CLI.

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/RaazKetan/creo/security/advisories/new)
rather than a public issue. You'll get a reply within a few days.
