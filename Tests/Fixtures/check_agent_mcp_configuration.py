"""Parse actual Swift output without running a command or touching client configs (Python 3.11+)."""
import json
import shlex
import sys
import tomllib

result = json.load(sys.stdin)
shell_args = shlex.split(result["shell"])
assert shell_args[:4] == ["claude", "mcp", "add-json", result["name"]]
assert shell_args[5:] == ["--scope", "user"]
assert json.loads(shell_args[4]) == {"command": result["path"], "type": "stdio", "args": []}
assert tomllib.loads(result["toml"]) == {"mcp_servers": {result["name"]: {"command": result["path"]}}}
print("Codex TOML and Claude Code CLI/JSON round trip: exact path, selector and stdio-only payload")
