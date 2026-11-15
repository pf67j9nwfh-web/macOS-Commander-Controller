# macOS Commander Controller

A light weight standalone [MCP](https://modelcontextprotocol.io) server that lets an AI agent work on a modern Mac the way
Desktop Commander does, and also **see the screen and control the mouse and keyboard**: click, type, press shortcuts,
scroll and drag things around.

One Objective-C source file, built with the Xcode Command Line Tools, no dependencies beyond the system frameworks. No Node, no Python, no Homebrew, no sudo. Tested on macOS 27 (arm64).

I created this because I needed to give an agent control over a macOS VM for testing something and for some reason all 
of the existing solutions I tried did not work as intended so I created my own simple light weight solution.

## What the agent gets

| Area | Tools |
|---|---|
| Files | `read_file`, `read_multiple_files`, `write_file`, `edit_block`, `list_directory`, `create_directory`, `move_file`, `get_file_info`, `start_search` (by name or contents) |
| Shell | `start_process`, `interact_with_process`, `read_process_output`, `force_terminate`, `list_sessions`, `list_processes`, `kill_process`. Sessions run on a pty, so REPLs and prompts work. |
| Screen | `take_screenshot`, `view_image`, `screen_info` |
| Mouse and keyboard | `screen_click` (left/right, 1-3 clicks), `screen_move`, `screen_drag`, `screen_scroll`, `screen_type`, `screen_key` (with `cmd`, `shift`, `option`, `control`) |

Coordinates for the `screen_*` tools are pixels of the **last screenshot**, so the agent takes a screenshot first.
Set `MC_ALLOWED=/path/one:/path/two` to restrict the file tools to those folders (shell commands are not restricted).

## Install

On the Mac you want to control (needs the Xcode Command Line Tools for `clang`; `xcode-select --install`):

```bash
sh install.sh
```

This compiles `macos-commander-controller.m` to `~/mac-commander/macos-commander-controller` and installs a
LaunchAgent (`local.mac-commander`) that runs it in your GUI login session and restarts it if it stops. It listens on a
private unix socket, `~/.mac-commander.sock` (mode 0600, no network port). The agent must run in the **GUI session**:
mouse clicks and drags are silently ignored from a plain ssh session.

You can also run the binary by hand for testing: with no arguments it speaks MCP on stdin/stdout.
`--check` prints the permission state, `--request` shows the system permission prompts, `--version` prints the version.

## Permissions (required)

macOS blocks screenshots and synthetic input until you allow them. The program is a single compiled executable, so
you grant these to **that executable only**, not to Python or a shell. On the Mac, open
**System Settings > Privacy & Security** and turn on `macos-commander-controller` in both lists (your password is
needed, and a person has to do this on the Mac itself):

1. **Accessibility** (mouse and keyboard).
2. **Screen & System Audio Recording** (screenshots).

The executable is at:

```
~/mac-commander/macos-commander-controller
```

If it is not in a list, press **+**, then **Cmd+Shift+G**, and paste that full path. The quickest way to get the
system prompts to appear, and to name the right program, is to run `--request` from inside the agent (so macOS
attributes it to the executable, not to your terminal or ssh):

```bash
# from any MCP client, with the agent running:  start_process  ~/mac-commander/macos-commander-controller --request
# or on the Mac, from Terminal:
~/mac-commander/macos-commander-controller --request
```

macOS may also show a prompt saying "macos-commander-controller is requesting to bypass the system private window
picker and directly access your screen and audio". Click **Allow**. macOS shows it again from time to time.

After granting, restart the agent: `launchctl kickstart -k gui/$(id -u)/local.mac-commander`.
`screen_info` reports `accessibility: granted` / `NOT granted` and the same for screen recording, so it is the quickest
check. (Run `--check` through ssh and it reports ssh's permissions, not the agent's; ask the agent with `screen_info`.)

### Rebuilding

The executable is ad-hoc signed by the compiler. macOS ties a permission to the program, so after you rebuild
(re-run `install.sh`) it may ask you to grant the two permissions again; if a toggle is on but `screen_info` says
`NOT granted`, switch the toggle off and on, or remove it with **-** and re-add it.

### Also possibly: `sshd-keygen-wrapper`

Programs started over ssh (not by the LaunchAgent) are attributed to the ssh daemon. If you run the binary or anything
else from an ssh session and want screenshots or key presses from it, macOS may list `sshd-keygen-wrapper` (the name
can differ between versions; look for `sshd`) and you can add it to the same two lists:

```
/usr/libexec/sshd-keygen-wrapper
```

This is not needed for the LaunchAgent setup, and it still will not make clicks or drags work over ssh.

## Shell sessions

`start_process` opens a terminal (pty) session. To keep the app from running out of terminals:

- Finished sessions are forgotten as soon as their output has been read, and their terminal is closed.
- At most 12 sessions stay open. Starting another closes the least recently used one and says so.
- When a client disconnects, every session it started is killed.
- Unread output is capped per session (the newest part is kept).

## Use with Claude Code

```bash
claude mcp add macos-commander -- ssh -T -o BatchMode=yes user@your-mac nc -U .mac-commander.sock
```

Equivalent `.mcp.json` entry:

```json
{
  "mcpServers": {
    "macos-commander": {
      "type": "stdio",
      "command": "ssh",
      "args": ["-T", "-o", "BatchMode=yes", "user@your-mac", "nc", "-U", ".mac-commander.sock"]
    }
  }
}
```

ssh needs key login (`BatchMode` fails rather than prompting). The socket path is relative to the remote home folder.
For a local Mac, use `nc -U ~/.mac-commander.sock` as the command directly.

### Running on the same Mac (no ssh)

Use this when the agent and the Mac are the same machine. [mcp.json.example](mcp.json.example):

```json
{
  "mcpServers": {
    "macos-commander": {
      "type": "stdio",
      "command": "nc",
      "args": ["-U", "/Users/YOURNAME/.mac-commander.sock"]
    }
  }
}
```

Replace `YOURNAME` with your account (use the full path; `~` is not expanded here). Or:
`claude mcp add macos-commander -- nc -U "$HOME/.mac-commander.sock"`. This talks to the LaunchAgent from the
install step, so the permissions are the executable's grants above.

Alternative with no LaunchAgent: `"command": "/Users/YOURNAME/mac-commander/macos-commander-controller"` with no
arguments. The server then runs as a child of whatever launched your agent (Terminal, the Claude app, an editor), so
**that app** is the one that needs Accessibility and Screen Recording, and it only works while that app is running in
your GUI session.

## Notes and limits

- The Mac must be logged in with the display awake; screenshots and input need a live GUI session.
- Typing uses US-layout key codes. Characters not on a US keyboard are sent as Unicode strings, which some apps ignore.
- Anything that can reach the socket can control the Mac as that user. The socket is owner-only; protect ssh access accordingly.
- Shell sessions are not sandboxed and `MC_ALLOWED` does not limit them. Run it only on machines you are willing to hand to the agent.

## License

[MIT](LICENSE)
