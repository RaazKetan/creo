# Creo

Find and resume your AI coding sessions from the menu bar.

Creo is a compact macOS menu-bar app for switching between AI tools, tracking
usage, and continuing Claude Code and Codex sessions.

## Install

```sh
brew install --cask RaazKetan/tap/creo
```

Creo opens automatically after installation. Requires macOS 13 or newer and
supports Apple Silicon and Intel Macs.
If Creo was previously installed manually, quit it and move the existing
`/Applications/Creo.app` to the Trash before running the Homebrew command.

To build from source instead:

```sh
brew install RaazKetan/tap/creo
open "$(brew --prefix)/opt/creo/Creo.app"
```

## Update

```sh
brew upgrade --cask RaazKetan/tap/creo
```

Creo checks for new releases. Click **Update** in the app to install the new
version through Homebrew automatically; Creo then reopens itself.

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

```sh
brew uninstall --cask RaazKetan/tap/creo
```

To also remove Creo's settings, saved names, and login item:

```sh
brew uninstall --cask --zap RaazKetan/tap/creo
```

## License

[MIT](LICENSE)
