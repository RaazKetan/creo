# Creo

Find and resume your AI coding sessions from the menu bar.

Creo is a compact macOS menu-bar app for switching between AI tools, tracking
usage, and continuing Claude Code and Codex sessions.

## Install

Until the Creo Homebrew package is published, install from source with the
included script. This needs the Xcode Command Line Tools.

```sh
curl -fsSL https://raw.githubusercontent.com/RaazKetan/creo/main/install.sh | zsh
```

Requires macOS 13 or newer. Supports Apple Silicon and Intel Macs.

## Update

```sh
curl -fsSL https://raw.githubusercontent.com/RaazKetan/creo/main/install.sh | zsh
```

Creo checks for new releases, shows an update notice, and reopens itself after
the new version is installed.

## Features

- Open ChatGPT, Claude, and Perplexity panels from one menu-bar notch.
- Track Codex five-hour and weekly usage at a glance.
- Search, filter, rename, and resume local Claude Code and Codex sessions.
- Open Claude and Perplexity usage in their account dashboards; Perplexity does not
  expose local sessions here yet.
- Jump back to an active session instead of opening a duplicate.
- Start automatically when you log in.
- Keep session data private on your Mac.

## Build locally

```sh
git clone https://github.com/RaazKetan/creo.git
cd creo
./build.sh
open Creo.app
```

## Uninstall

Quit Creo, remove `/Applications/Creo.app`, and delete
`~/Library/LaunchAgents/io.github.raazketan.creo.plist` to stop it starting at
login. The app's settings and custom session names remain in
`~/Library/Application Support/ClaudeSessions` unless you remove them too.

## License

[MIT](LICENSE)
