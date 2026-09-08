#!/usr/bin/python3
import json, os, sys, time
assert not any(k in os.environ for k in ['GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS', 'GEMINI_CLI_HOME'])
with open(os.path.join(os.environ['HOME'], '.gemini/antigravity-cli/settings.json')) as f:
    settings = json.load(f)
assert 'modelProvider' not in settings
assert settings['useG1Credits'] is False
assert 'command(*)' in settings['permissions']['deny']
if sys.argv[1:] == ['models']:
    print('gemini-test-high\tGemini Test (High)')
    sys.exit(0)
assert '--input-format' in sys.argv and '--disable-slash-commands' in sys.argv
assert '--extensions' not in sys.argv and '--prompt' not in sys.argv and '--model' not in sys.argv
message = json.loads(sys.stdin.readline())
assert message['event'] == 'user'
content = message['message']['content']
assert '@' not in content
response = json.loads(content.split('\n', 1)[1])
print(json.dumps({'event': 'init', 'init': {}}))
for fragment in [response[:1], response[1:]]:
    line = (json.dumps({'event': 'step_update', 'step_update': {'step_type': 'agent_response', 'text_delta': fragment}}, ensure_ascii=False) + '\n').encode()
    for byte in line:
        sys.stdout.buffer.write(bytes([byte]))
    sys.stdout.buffer.flush()
    if fragment == response[:1]:
        deadline = time.monotonic() + 8
        marker = os.path.join(os.environ['HOME'], 'first-delta-seen')
        while not os.path.exists(marker):
            assert time.monotonic() < deadline, 'No delta delivered before process completion'
            time.sleep(0.05)
print(json.dumps({'event': 'result' , 'result': {'status': 'SUCCESS', 'response': response}}))
