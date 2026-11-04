"""Compare the travel-question approaches on a Claude model through the Converse API, with the real Lambda code
called locally as the tools: the old three-query rule vs the route_between tool.

Needs the same BENCH_* variables as benchmark.py, plus AWS credentials that can read the ArcGIS credentials secret
(the Lambda is found by name) and invoke the model. Nothing is deployed or changed.

    BENCH_AWS_PROFILE=... BENCH_KB_ID=... BENCH_AGENT_ID=... BENCH_AGENT_VERSION=... python3 agent_compare.py
"""
import os, sys, time, json, re, statistics as st, importlib.util
from pathlib import Path
import boto3

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import benchmark as B

MODEL = os.environ.get("COMPARE_MODEL", "au.anthropic.claude-sonnet-5-5")
_lambda_client = B._session.client("lambda")
_arcgis_fn = next(f for pg in _lambda_client.get_paginator("list_functions").paginate() for f in pg["Functions"]
                  if "BedrockArcGisLambda" in f["FunctionName"])
os.environ["ARCGIS_SECRET_ARN"] = _arcgis_fn["Environment"]["Variables"]["ARCGIS_SECRET_ARN"]
if B.PROFILE:
    os.environ["AWS_PROFILE"] = B.PROFILE
os.environ["AWS_DEFAULT_REGION"] = B.REGION


def load(name, path):
    sp = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m)
    return m


geocode = load("geocode_l", ROOT / "lambda/arcgis-geocode/index.py")
geojson = load("geojson_l", ROOT / "lambda/geojson-query/index.py")
sba = load("sba", ROOT / "scripts/bedrock/setup-bedrock-agent.py")

# The instruction as deployed before the change (with the old three-query travel rule), and the new rule from the repo.
instr = B.get_instruction()
OLD = ("- For any question about **travel time, drive time, route, or ETA** between two NZ locations, you MUST call the query_geojson tool "
       "to check for current road delays and closures on that route. Use the delays URL and query the full route by making multiple calls "
       "if needed \u2014 one anchored near the origin, one near the midpoint, and one near the destination \u2014 with a radius_km of 100 each. "
       "Combine all results and provide a practical answer including normal drive time and any current delays. Never refuse travel time "
       "questions \u2014 they are operationally relevant for resource deployment and response planning.")
NEW = next(l for l in (ROOT / "scripts/bedrock/nz_rag_responder.txt").read_text(encoding="utf-8").split("\n")
           if l.startswith("- For any question about **travel time"))
if not any(l.startswith("- For any question about **travel time") for l in instr.split("\n")):
    sys.exit("The instruction in results/agent_instruction.txt has no travel-time rule to replace")
_cur = next(l for l in instr.split("\n") if l.startswith("- For any question about **travel time"))
instr = instr.replace(_cur, OLD)   # normalise to the old rule so both variants start from the same text
def spec(f):
    props={k:{"type":"string","description":v["description"]} for k,v in f["parameters"].items()}
    req=[k for k,v in f["parameters"].items() if v.get("required")]
    return {"toolSpec":{"name":f["name"],"description":f["description"],"inputSchema":{"json":{"type":"object","properties":props,"required":req}}}}
by={f['name']:f for f in sba.GEOCODE_FUNCTION_SCHEMA['functions']}
kb=B.KB_TOOL['tools'][0]
TOOLS_A={"tools":[kb,spec(by['find_place']),spec(sba.GEOJSON_FUNCTION_SCHEMA['functions'][0])]}
TOOLS_D={"tools":[kb,spec(by['find_place']),spec(by['route_between']),spec(sba.GEOJSON_FUNCTION_SCHEMA['functions'][0])]}
def call_tool(name,inp):
    t=time.time()
    if name.startswith('GET__x_amz_knowledgebase'):
        ch,_=B.kb_retrieve(inp.get('searchQuery','')); out=B.format_search_results(ch)
    elif name=='find_place':
        out=geocode.find_place(inp['query'], float(inp['lat']) if inp.get('lat') else None, float(inp['lon']) if inp.get('lon') else None)
    elif name=='route_between': out=geocode.route_between(inp['origin'],inp['destination'])
    elif name=='query_geojson':
        ev={"parameters":[{"name":k,"value":v} for k,v in inp.items()]}
        out=geojson.handler(ev,None)['response']['functionResponse']['responseBody']['TEXT']['body']
    else: out='unknown tool'
    return out,time.time()-t
def turn(system,tools,question):
    msgs=[{"role":"user","content":[{"text":question}]}]; t0=time.time(); log=[]; tin=0; tout=0; calls=[]
    for _ in range(8):
        r,ms,_=B.call_with_retry(B._br.converse,modelId=MODEL,messages=msgs,system=[{"text":system}],toolConfig=tools,
            inferenceConfig={"maxTokens":2048,"temperature":1.0,"stopSequences":["</answer>"]})
        tin=max(tin,r['usage']['inputTokens']); tout+=r['usage']['outputTokens']; m=r['output']['message']; msgs.append(m)
        if r['stopReason']=='tool_use':
            res=[]
            for b in m['content']:
                if 'toolUse' in b:
                    u=b['toolUse']; out,dt=call_tool(u['name'],u['input']); calls.append(u['name']); res.append({"toolResult":{"toolUseId":u['toolUseId'],"content":[{"text":out[:24000]}]}})
            msgs.append({"role":"user","content":res}); continue
        txt="".join(b.get('text','') for b in m['content']); mm=re.search(r"<answer>(.*)",txt,re.S); ans=(mm.group(1) if mm else txt).replace('</answer>','').strip()
        return {"s":time.time()-t0,"calls":calls,"max_in":tin,"out":tout,"ans":ans}
    return {"s":time.time()-t0,"calls":calls,"max_in":tin,"out":tout,"ans":None}
PRE="[User: NZP-H.Hoiho, Location: -41.2915, 174.7812] "
QS=["The far is Te Anau from Queenstown","How long to drive from Christchurch to Queenstown?","What is the travel time from Wellington to Palmerston North?","How long to drive from here to Napier?"]
res={'A_current':[], 'D_route_between':[]}
for rep in range(int(os.environ.get('COMPARE_REPS','3'))):
    for q in QS:
        for name,rule,tools in (('A_current',OLD,TOOLS_A),('D_route_between',NEW,TOOLS_D)):
            system=B.build_system_prompt() if False else (instr.replace(OLD,rule)+"\n"+B.ORCH_GUIDELINES+"\n"+B.KB_GUIDELINE)
            r=turn(system,tools,PRE+q); r['q']=q; res[name].append(r); print(f"{name:16} {q[:44]:44} {r['s']:5.1f}s calls={r['calls']}",flush=True)
json.dump(res,open(HERE/'results'/'agent_compare.json','w'))
for name,rs in res.items():
    ok=[r for r in rs if r['ans']]
    print(f"\n{name}: n={len(rs)} ok={len(ok)} mean {st.mean(r['s'] for r in ok):.1f}s median {st.median(r['s'] for r in ok):.1f}s max {max(r['s'] for r in ok):.1f}s | max_in_tok {st.mean(r['max_in'] for r in ok):.0f} out_tok {st.mean(r['out'] for r in ok):.0f} | tool calls/turn {st.mean(len(r['calls']) for r in ok):.1f}")
    for q in QS:
        v=[r for r in ok if r['q']==q]; print(f"   {q[:46]:46} mean {st.mean(r['s'] for r in v):5.1f}s  max {max(r['s'] for r in v):5.1f}s")
