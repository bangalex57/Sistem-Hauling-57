import json,sys,os,re
from playwright.sync_api import sync_playwright
HTML='file:///home/claude/v6/index.html'
FAKE=open('/home/claude/v6/uji/fake_supabase.js',encoding='utf-8').read()
def jalankan(peran='admin',fn=None):
    gagal=[]
    with sync_playwright() as p:
        b=p.chromium.launch()
        ctx=b.new_context(accept_downloads=True,viewport={'width':1280,'height':900},geolocation={'latitude':-6.2,'longitude':106.8},permissions=['geolocation'])
        ctx.add_init_script("localStorage.setItem('sb_url','https://x.supabase.co');localStorage.setItem('sb_key','k');window.__PERAN='%s';"%peran)
        ctx.route(re.compile(r'.*supabase\.js.*'),lambda r:r.fulfill(body=FAKE,content_type='application/javascript'))
        ctx.route(re.compile(r'.*(googleapis|gstatic|cdnjs).*'),lambda r:r.abort())
        pg=ctx.new_page()
        galat=[]
        pg.on('pageerror',lambda e:galat.append('pageerror: '+str(e)))
        pg.on('console',lambda m:galat.append('console.error: '+m.text) if m.type=='error' and 'Failed to load resource' not in m.text and 'ERR_FAILED' not in m.text else None)
        pg.goto(HTML); pg.wait_for_selector('#app:not([hidden])',timeout=8000)
        fn(pg,galat,gagal)
        b.close()
    return galat,gagal
