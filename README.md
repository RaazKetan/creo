# Claude Sessions

All your Claude Code and Codex sessions in the menu bar. Click one to pick up where you left off.

```sh
brew install --cask RaazKetan/tap/claude-sessions && open /Applications/ClaudeSessions.app
```

Works on Intel and Apple Silicon. Needs macOS 13 or newer.

<details>
<summary>Other ways to install</summary>

Build from source instead of downloading (needs `xcode-select --install`):

```sh
brew install RaazKetan/tap/claude-session-manager
open "$(brew --prefix)/opt/claude-session-manager/ClaudeSessions.app"
```

No Homebrew:

```sh
curl -fsSL https://raw.githubusercontent.com/RaazKetan/claude-session-manager/main/install.sh | zsh
```

</details>

## Updating

The app tells you when a release is out and copies the command that matches your install. By hand:

```sh
brew upgrade --cask claude-sessions                  # installed with the cask
brew upgrade RaazKetan/tap/claude-session-manager    # built from source
```

When the upgrade finishes, the running menu-bar app detects the replacement and reopens the new
version automatically.

## What it does

- Lists every Claude Code and Codex session on your Mac, newest first. Filter by agent, or search inside the conversations themselves.
- Click one to resume it. If it's already open, it jumps to that window instead of starting a second one.
- Marks the sessions running right now.
- Starts automatically when you log in.
- Tells you when an update is out, copies the right upgrade command, and reopens itself on the new version when it finishes.
- Optional checkbox to resume Claude sessions with `--dangerously-skip-permissions`, so they never stop to ask before running a tool. Off unless you turn it on.
- Sessions whose folder you deleted are greyed out.
- Right-click a session to rename it, move it to the Trash, copy its id, or reveal its log in Finder.
- Reads the logs these tools already keep on your Mac. Nothing about you is sent anywhere. The only network traffic is an occasional request to GitHub to see whether a newer version exists.

It also installs the [Spotify statusline](https://github.com/RaazKetan/claude-code-spotify) the first time you open it, and backs up your old `statusLine` setting. To skip that, create the file `~/Library/Application Support/ClaudeSessions/statusline-installed` before launching.

## Good to know

- Jumping to an open session works in Terminal and iTerm2. Other terminals open a new window.
- Searching inside conversations runs one `grep` per transcript across your cores, and shows the passage it found. About a second over a gigabyte of logs; no ripgrep needed.
- Session names come from the first thing you typed. To rename one, add its id to `~/Library/Application Support/ClaudeSessions/names.json`:
  ```json
  { "90d19fcb-8ba7-4016-99a1-465cd4a5c7ae": "Conekt deploy" }
  ```

## Uninstall

```sh
brew uninstall --cask claude-sessions   # or: brew uninstall RaazKetan/tap/claude-session-manager
rm -rf ~/Library/"Application Support"/ClaudeSessions ~/Library/LaunchAgents/dev.local.claudesessions.plist
```

It also leaves two lines in `~/.zshrc` marked `# claude-sessions update notice`, and a copy of your
old statusline setting at `~/.claude/settings.json.claude-sessions-backup`.

## How it works

[ARCHITECTURE.md](ARCHITECTURE.md) covers how sessions are found, how resuming and window-switching work, and where the limits are.

## Building it yourself

```sh
./build.sh                        # makes ClaudeSessions.app
swift run ClaudeSessions --list   # prints what it can read, no window
```

`--search "some text"` and `--update` are the other two, for checking the search and the version check.

## License

[MIT](LICENSE)
