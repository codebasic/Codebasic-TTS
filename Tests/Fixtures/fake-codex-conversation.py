#!/usr/bin/python3
"""Offline generation fixture; never runs an actual Codex server or model."""
import json
import os
import sys

for line in sys.stdin:
    request = json.loads(line)
    with open(os.path.join(os.getcwd(), 'conversation-requests.jsonl'), 'a') as log:
        log.write(json.dumps(request) + '\n')
    if 'id' not in request:
        continue
    method = request['method']
    params = request.get('params', {})
    if method == 'initialize':
        assert params['capabilities']['experimentalApi'] is True
        result = {}
    elif method == 'account/read':
        result = {'account': {'type': 'chatgpt'}}
    elif method == 'thread/start':
        assert params['ephemeral'] is True
        assert params['approvalPolicy'] == 'never'
        assert 'current test rules' in params['baseInstructions']
        result = {'thread': {'id': 'fixture-thread'}}
    elif method == 'thread/injectItems':
        assert [m['role'] for m in params['items']] == ['user', 'assistant']
        assert params['items'][0]['content'][0]['text'] == 'old test input'
        assert params['items'][1]['content'][0]['text'] == 'old test answer'
        result = {}
    elif method == 'turn/start':
        assert params['input'][0]['text'] == 'current test input'
        result = {}
    else:
        raise AssertionError(method)
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    if method == 'turn/start':
        print(json.dumps({'method': 'item/agentMessage/delta', 'params': {'delta': 'fixture answer'}}), flush=True)
        print(json.dumps({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}}), flush=True)
