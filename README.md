# macOS Commander Controller

A light weight standalone [MCP](https://modelcontextprotocol.io) server that lets an AI agent work on a modern Mac the way
Desktop Commander does, and also **see the screen and control the mouse and keyboard**: click, type, press shortcuts,
scroll and drag things around.

One Python 3 file, standard library only. No Node, no Homebrew, no compiler. Tested on macOS 27 (arm64).

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

On the Mac you want to control:

```bash
sh install.sh
```

This copies the server to `~/mac-commander/` and installs a LaunchAgent (`local.mac-commander`) that runs it in your
GUI login session and restarts it if it stops. It listens on a private unix socket, `~/.mac-commander.sock`
(mode 0600, no network port). The agent must run in the **GUI session**: mouse clicks and drags are silently ignored
from a plain ssh session.

You can also run it by hand, for testing: `python3 mac-commander.py` speaks MCP on stdin/stdout.

## Permissions (required)

macOS blocks screenshots and synthetic input until you allow them. Open **System Settings > Privacy & Security** and
turn these on. You will be asked for your password, and the grants have to be made on the target Mac itself (or
through its screen), since they are security settings.

1. **Accessibility** (mouse and keyboard). Add the Python that runs the server (/usr/bin/python3).
2. **Screen & System Audio Recording** (screenshots). Add the same Python (/usr/bin/python3).

If it is not in the list, press **+**, then **Cmd+Shift+G** and paste the path.
It may also be easy to navigate to /usr/bin in Finder **Cmd+Shift+G** and then drag the python executable onto the permission page.

Note: This does give these permissions to all python3 programs on the Mac, so be careful if this is too broad and insecure
for your purposes. For my use case, I can accept the risk that entails.

If you run the server **over ssh instead of the LaunchAgent**, or when the first permission prompts appear while you
are connected through ssh, macOS may attribute the request to `sshd-keygen-wrapper` (a name that can differ between
macOS versions; look for `sshd` in the list). In that case add it to the same two lists:

```
/usr/libexec/sshd-keygen-wrapper
```

That grant lets ssh-launched processes take screenshots and send keyboard events, but **clicks and drags still
will not work over ssh**; use the LaunchAgent for those.

After changing a permission, restart the agent: `launchctl kickstart -k gui/$(id -u)/local.mac-commander`.

`screen_info` reports `accessibility: granted` or `NOT granted`, which is the quickest check.

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
install step, so the permissions are the Python grants above.

Alternative with no LaunchAgent: `"command": "python3", "args": ["/path/to/mac-commander.py"]`. The server then runs as
a child of whatever launched your agent (Terminal, the Claude app, an editor), so **that app** is the one that needs
Accessibility and Screen Recording, and it only works while that app is running in your GUI session.

## Notes and limits

- The Mac must be logged in with the display awake; screenshots and input need a live GUI session.
- Typing uses US-layout key codes. Characters not on a US keyboard are sent as Unicode strings, which some apps ignore.
- Anything that can reach the socket can control the Mac as that user. The socket is owner-only; protect ssh access accordingly.
- Shell sessions are not sandboxed and `MC_ALLOWED` does not limit them. Run it only on machines you are willing to hand to the agent.

## License

[MIT](LICENSE)
