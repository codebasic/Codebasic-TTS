#!/usr/bin/python3
"""Offline app-server fixture: splits stdout writes and never authenticates or calls a model."""
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"userAgent": "fixture"}
    elif method == "account/read":
        result = {"account": {"type": "apiKey"}}
    elif method == "echo":
        result = request["params"]
    else:
        print(json.dumps({"id": request["id"], "error": {"code": -32601, "message": "unsupported"}}), flush=True)
        continue
    payload = json.dumps({"id": request["id"], "result": result}) + "\n"
    sys.stdout.write(payload[:8]); sys.stdout.flush()
    sys.stdout.write(payload[8:]); sys.stdout.flush()
