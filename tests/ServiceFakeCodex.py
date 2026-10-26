#!/usr/bin/python3
"""Deterministic local JSON-RPC fixture; never connects to a model or network."""
import sys, json, os, threading, time
if '--version' in sys.argv:
    print('codex-cli 0.163.0')
    sys.exit(0)
lock = threading.Lock()
current = None

def send(o):
    with lock:
        print(json.dumps(o), flush=True)

def record(value):
    with open(os.environ['PPT_TEST_TRACE_PATH'], 'a') as f: f.write(value+'\n')

def respond(req, result): send({'id': req['id'], 'result': result})

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
    elif method == 'account/read': respond(req,{'account':{'type':os.environ.get('PPT_TEST_AUTH','chatgpt')}})
    elif method == 'modelProvider/capabilities/read': respond(req,{'imageGeneration':True,'webSearch':False})
    elif method == 'model/list': respond(req,{'data':[{'model':'test-model','isDefault':True}]})
    elif method == 'thread/start':
        assert req['params']['config']['mcp_servers.test_server.enabled'] is False
        assert req['params']['modelProvider']=='openai'
        respond(req,{'thread':{'id':'thread-test'}})
    elif method == 'turn/start': threading.Thread(target=turn,args=(req,),daemon=True).start()
    elif method == 'turn/interrupt':
        record('interrupted')
        respond(req,{})
        send({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'interrupted'}}})
    else: respond(req,{})
