from smoke import *
def uji(pg,galat,gagal):
    rutes=pg.evaluate("Object.keys(HALAMAN)")
    print(len(rutes),'halaman terdaftar')
    for r in rutes:
        n0=len(galat)
        pg.evaluate("location.hash='#/%s'"%r); pg.wait_for_timeout(450)
        txt=pg.inner_text('#main')[:140].replace('\n',' | ')
        gal=galat[n0:]
        isi_err=pg.evaluate("!!document.querySelector('#main .msg-er')")
        status='OK' if not gal and not isi_err else 'GAGAL'
        if status=='GAGAL': gagal.append(r)
        print(f'{status:6}{r:26}{txt[:90]}', ('| '+'; '.join(gal)[:200]) if gal else '')
g,f=jalankan('admin',uji)
print('\nGALAT KONSOL:',g[:5]); print('HALAMAN GAGAL:',f)
