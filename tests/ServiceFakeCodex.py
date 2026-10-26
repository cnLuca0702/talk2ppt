#!/usr/bin/python3
"""Deterministic local JSON-RPC fixture; never connects to a model or network."""
import sys, json, os, threading, time
if '--version' in sys.argv:
    print('codex-cli 0.163.0')
    sys.exit(0)
lock = threading.Lock()

def state():
    """Optional state file lets offline tests change responses between requests."""
    path = os.environ.get('PPT_TEST_STATE_PATH')
    if not path: return {}
    with open(path) as f: return json.load(f)

def send(o):
    with lock:
        print(json.dumps(o), flush=True)

def record(value):
    with lock:
        with open(os.environ['PPT_TEST_TRACE_PATH'], 'a') as f: f.write(value+'\n')

def respond(req, result): send({'id': req['id'], 'result': result})

def models(req):
    config = state()
    params = req['params']
    assert params.get('limit') == 20
    assert params.get('includeHidden') is False
    cursor = params.get('cursor')
    page = int(cursor.split('-')[-1]) if cursor else 0
    record('model-request:' + str(page))
    time.sleep(config.get('modelDelaySeconds', 0))
    if config.get('modelErrorPage') == page:
        send({'id': req['id'], 'error': {'code': -32000, 'message': 'Synthetic model catalog failure'}})
        return
    pages = config.get('modelPages', [[{'id': 'row-default', 'model': 'test-model', 'displayName': 'Fixture Default', 'isDefault': True}]])
    assert 0 <= page < len(pages)
    next_cursor = 'page-' + str(page + 1) if page + 1 < len(pages) else None
    respond(req, {'data': pages[page], 'nextCursor': next_cursor})

def turn(req):
    prompt = req['params']['input'][0]['text']
    record('turn-request')
    if 'cancel-before-turn' in prompt: time.sleep(0.35)
    respond(req, {'turn': {'id':'turn-test'}})
    send({'method':'turn/started', 'params':{'threadId':'thread-test', 'turn':{'id':'turn-test'}}})
    if 'cancel-before-turn' in prompt: return
    if 'missing-runtime' in prompt:
        send({'method':'item/completed','params':{'threadId':'thread-test','item':{'type':'agentMessage','phase':'final_answer','text':'原生生图失败：failed to spawn code-mode host /app/Contents/Resources/codex-code-mode-host: No such file. Authorization: Bearer PRIVATE-TOKEN access_token=PRIVATE-ACCESS'}}})
    if 'missing-image' not in prompt and 'missing-runtime' not in prompt:
        send({'method':'item/completed','params':{'threadId':'thread-test','item':{'type':'imageGeneration','status':'completed','savedPath':os.environ['PPT_TEST_IMAGE'],'revisedPrompt':'fixture'}}})
    send({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed'}}})

for line in sys.stdin:
    req=json.loads(line); method=req.get('method')
    if method == 'initialized': continue
    if method == 'initialize': respond(req,{})
    elif method == 'config/read': respond(req,{'config':{'mcp_servers':{'test_server':{'enabled':True}}}})
    elif method == 'account/read': respond(req,{'account':{'type':state().get('auth', os.environ.get('PPT_TEST_AUTH','chatgpt'))}})
    elif method == 'modelProvider/capabilities/read': respond(req,{'imageGeneration':state().get('imageGeneration', True),'webSearch':False})
    elif method == 'model/list': models(req)
    elif method == 'thread/start':
        assert req['params']['config']['mcp_servers.test_server.enabled'] is False
        assert req['params']['modelProvider']=='openai'
        record('thread-model:' + req['params']['model'])
        respond(req,{'thread':{'id':'thread-test'}})
    elif method == 'turn/start': threading.Thread(target=turn,args=(req,),daemon=True).start()
    elif method == 'turn/interrupt':
        record('interrupted')
        respond(req,{})
        send({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'interrupted'}}})
    else: respond(req,{})
