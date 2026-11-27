"""Fills a LOCAL GeoClass dev server (localhost:8788, key 'local-check-key') with made-up demo sessions for screenshots."""
import json, urllib.request, secrets, random, sys
B='http://localhost:8788/api/'
H={'Authorization':'Bearer local-check-key','Content-Type':'application/json'}
def call(m,p,body=None,auth=True):
    r=urllib.request.Request(B+p,method=m,data=json.dumps(body).encode() if body is not None else None,headers=H if auth else {'Content-Type':'application/json'})
    return json.load(urllib.request.urlopen(r))
def rid(): return secrets.token_urlsafe(18)
out={}
def sess(key,name,game,**kw):
    r=call('POST','sessions',{'name':name,'game':game,**kw}); out[key]=r['token']; return r
P=[("Paris","პარიზი","FR",48.8566,2.3522,"To see the Louvre","ლუვრის სანახავად","train"),("Tokyo","ტოკიო","JP",35.68,139.69,"Food and temples","საჭმელი და ტაძრები","plane"),("Kazbegi","ყაზბეგი","GE",42.66,44.64,"Mountains and Gergeti","მთები და გერგეტი","car"),("New York","ნიუ-იორკი","US",40.71,-74.0,"Skyscrapers","ცათამბჯენები","plane"),("Rome","რომი","IT",41.9,12.5,"History","ისტორია","plane"),("Cairo","კაირო","EG",30.04,31.24,"The pyramids","პირამიდები","plane"),("Batumi","ბათუმი","GE",41.64,41.63,"The sea","ზღვა","train"),("Reykjavik","რეიკიავიკი","IS",64.15,-21.94,"Northern lights","ჩრდილოეთის ციალი","plane"),("Rio de Janeiro","რიო-დე-ჟანეირო","BR",-22.9,-43.2,"Carnival","კარნავალი","plane"),("Sydney","სიდნეი","AU",-33.87,151.21,"The opera house","ოპერის თეატრი","plane"),("Istanbul","სტამბოლი","TR",41.01,28.98,"Bazaars","ბაზრები","bus"),("Barcelona","ბარსელონა","ES",41.39,2.17,"Football","ფეხბურთი","plane"),("Mestia","მესტია","GE",43.05,42.73,"Svan towers","სვანური კოშკები","car"),("Cape Town","კეიპტაუნი","ZA",-33.92,18.42,"Table Mountain","მაგიდის მთა","plane"),("Vienna","ვენა","AT",48.21,16.37,"Music","მუსიკა","train"),("Kyoto","კიოტო","JP",35.01,135.77,"Gardens","ბაღები","plane"),("Lisbon","ლისაბონი","PT",38.72,-9.14,"The ocean","ოკეანე","plane"),("Vardzia","ვარძია","GE",41.38,43.28,"Cave city","გამოქვაბული ქალაქი","bus")]
for lang,name in (('en','Grade 8A — travel map'),('ka','VIII ა — მოგზაურობის რუკა')):
    tok=sess('travel_'+lang,name,'travel')['token']
    for pe,pk,c,la,lo,we,wk,tr in P:
        call('POST','submit',{'token':tok,'submissionId':rid(),'participantId':rid(),'lat':la,'lon':lo,'answer':{'place':pe if lang=='en' else pk,'country':c,'reason':we if lang=='en' else wk,'transport':tr,'company':random.choice(['family','friends','class'])}},auth=False)
tasks=[{'lat':41.6938,'lon':44.8015,'mode':'to_map','format':'dms','label':''},{'lat':42.6625,'lon':44.6408,'mode':'read','format':'dd','label':''},{'lat':41.6168,'lon':41.6367,'mode':'to_map','format':'utm','label':''}]
for lang,name in (('en','Grade 8B — coordinates'),('ka','VIII ბ — კოორდინატები')):
    sess('coords_'+lang,name,'coordinates',tasks=tasks)
for lang,name in (('en','Grade 9A — map puzzle'),('ka','IX ა — რუკის ფაზლი')):
    r=sess('puzzle_'+lang,name,'puzzle',puzzle={'kind':'regions','area':'georgia','rotation':'none','help':'outline','names':False,'look':'map','base':'osm','seed':1234,'pieces':12})
    call('POST','sessions/%s/timer'%r['session']['id'],{'seconds':3600})
for lang,name in (('en','Grade 9B — map layout'),('ka','IX ბ — რუკის გაფორმება')):
    sess('layout_'+lang,name,'layout',layout={'area':'georgia','legend':list(range(12))})
deck=[{'shape':s,'palette':'red_green','seed':7+i} for i,s in enumerate(['georgia','africa','south_america','australia'])]
for lang,name in (('en','Grade 7 — colour plates'),('ka','VII — ფერების წრეები')):
    sess('plates_'+lang,name,'plates',plates={'deck':deck})
json.dump(out,open(sys.argv[1],'w'))
print(list(out))
