"""Archives the demo sessions of the other language so the teacher list shows one language only."""
import json,urllib.request,sys
H={'Authorization':'Bearer local-check-key','Content-Type':'application/json'}
def call(m,p,b=None):
    return json.load(urllib.request.urlopen(urllib.request.Request('http://localhost:8788/api/'+p,method=m,data=json.dumps(b).encode() if b is not None else None,headers=H)))
show=sys.argv[1]; tok=json.load(open(sys.argv[2])); qr={}
for s in call('GET','sessions?archived=1')['sessions'] if False else call('GET','sessions')['sessions']:
    en=s['name'].startswith('Grade')
    call('PATCH','sessions/'+s['id'],{'archived': en != (show=='en')})
    if s['game']=='travel' and en==(show=='en'): qr[s['id']]=tok['travel_'+show]
print(json.dumps(qr))
