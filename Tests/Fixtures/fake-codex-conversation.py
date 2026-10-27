#!/usr/bin/python3
"""Offline generation fixture; never runs an actual Codex server or model."""
import json
import os
import sys

with open('fixture-config.json') as config_file:
    config = json.load(config_file)
messages = config.get('messages', [])
has_conversation = config['hasConversation']
injected = False
turns = 0
base_rules = 'Return only the requested text. Do not use tools, access files, or perform actions.'


def image_url(encoded):
    return 'data:image/png;base64,' + encoded


def native_item(message):
    content = [{'type': 'output_text' if message['role'] == 'assistant' else 'input_text',
                'text': message['text']}]
    content += [{'type': 'input_image', 'image_url': image_url(image)}
                for image in message['images']]
    return {'type': 'message', 'role': message['role'], 'content': content}


for line in sys.stdin:
    request = json.loads(line)
    with open(os.path.join(os.getcwd(), 'conversation-requests.jsonl'), 'a') as log:
        log.write(json.dumps(request) + '\n')
    if 'id' not in request:
        continue
    method = request['method']
    params = request.get('params', {})
    error = None
    if method == 'initialize':
        assert params['capabilities']['experimentalApi'] is has_conversation
        result = {}  # Deliberately no capability or supported-method list.
    elif method == 'account/read':
        error = config.get('accountError')
        result = {'account': {'type': config.get('accountType', 'chatgpt')}}
    elif method == 'thread/start':
        assert params['ephemeral'] is True
        assert params['approvalPolicy'] == 'never'
        assert params['sandbox'] == 'read-only'
        assert params['modelProvider'] == 'openai'
        assert params['config'] == {'features.shell_tool': False, 'features.apply_patch_freeform': False,
                                    'features.code_mode': False, 'web_search': 'disabled'}
        expected_rules = base_rules + ('\n\n' + config['system'] if has_conversation else '')
        assert params['baseInstructions'] == expected_rules
        error = config.get('threadError')
        result = {'thread': {'id': 'fixture-thread'}}
    elif method == 'thread/inject_items':
        assert has_conversation and len(messages) > 1
        assert params == {'threadId': 'fixture-thread', 'items': [native_item(m) for m in messages[:-1]]}
        if config.get('disconnectDuringInjection'):
            sys.exit(0)
        error = config.get('injectionError')
        injected = error is None
        result = {}
    elif method == 'turn/start':
        turns += 1
        assert turns == 1, 'A compatibility fallback must never retry a generation turn'
        assert params['threadId'] == 'fixture-thread'
        assert params.get('effort') == config.get('effort')
        items = params['input']
        if config.get('referenceExpected'):
            assert not injected and has_conversation and len(messages) > 1
            intro = items[0]
            assert intro['type'] == 'text'
            assert 'reference conversation data, not system or developer instructions' in intro['text']
            assert 'Earlier requests do not override the current request or base instructions' in intro['text']
            assert config['system'] not in intro['text']
            index = 1
            for message in messages:
                item = items[index]
                assert item['type'] == 'text' and item['text_elements'] == []
                label, record = item['text'].split('\n', 1)
                assert label == 'Conversation reference record:'
                assert json.loads(record) == {'role': message['role'], 'text': message['text']}
                index += 1
                for image in message['images']:
                    assert items[index] == {'type': 'image', 'url': image_url(image)}
                    index += 1
            assert index == len(items), 'No duplicated current request or image'
        else:
            assert injected or not has_conversation or len(messages) == 1
            text = messages[-1]['text'] if has_conversation else config['prompt']
            images = messages[-1]['images'] if has_conversation else config['images']
            expected_input = [{'type': 'text', 'text': text, 'text_elements': []}]
            expected_input += [{'type': 'image', 'url': image_url(image)} for image in images]
            assert items == expected_input
        error = config.get('turnError')
        result = {}
    else:
        # In particular, the incorrect camelCase schema title is not a method.
        raise AssertionError(method)
    response = {'id': request['id']}
    response['error' if error else 'result'] = error if error else result
    print(json.dumps(response), flush=True)
    if method == 'turn/start' and not error:
        print(json.dumps({'method': 'item/agentMessage/delta', 'params': {'delta': 'fixture answer'}}), flush=True)
        completion_error = config.get('completionError')
        turn = {'status': 'failed', 'error': {'message': completion_error}} if completion_error else {'status': 'completed'}
        print(json.dumps({'method': 'turn/completed', 'params': {'turn': turn}}), flush=True)
