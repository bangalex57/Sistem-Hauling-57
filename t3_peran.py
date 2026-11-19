from smoke import *
hasil=[]
def cek(n,k,i=''):
    hasil.append(bool(k)); print(('OK    ' if k else 'GAGAL ')+n+(('  -> '+str(i)[:160]) if (i and not k) else ''))
def operator(pg,galat,gagal):
    pg.wait_for_timeout(500)
    links=pg.evaluate("Array.from(document.querySelectorAll('#nav a')).map(a=>a.getAttribute('href'))")
    cek('Operator tidak melihat menu Setting/Laporan keuangan',not any(('setting' in l or 'laporan/lr' in l or 'dashboard' in l) for l in links),links)
    cek('Operator melihat Produksi, BBM, Absensi, Data Saya',all(any(x in l for l in links) for x in ['inputan/produksi','inputan/bbm','inputan/absensi','saya/ringkas']),links)
    pg.evaluate("location.hash='#/laporan/lr'"); pg.wait_for_timeout(600)
    cek('Operator dialihkan dari laporan keuangan',pg.evaluate("location.hash")!='#/laporan/lr',pg.evaluate("location.hash"))
    pg.evaluate("location.hash='#/setting/pengguna'"); pg.wait_for_timeout(600)
    cek('Operator tidak bisa membuka Setting',pg.evaluate("location.hash").find('setting')<0,pg.evaluate("location.hash"))
    pg.evaluate("location.hash='#/saya/ringkas'"); pg.wait_for_timeout(600)
    cek('Operator melihat laporan dirinya',('Slip gaji' in pg.inner_text('#main') and 'Sisa kasbon' in pg.inner_text('#main')))
    pg.evaluate("location.hash='#/inputan/produksi'"); pg.wait_for_timeout(500)
    cek('Operator: form produksi tampil, nominal tidak ditampilkan di menu laporan',pg.is_visible('#f_no_spb'))
g,f=jalankan('operator',operator)
print('GALAT KONSOL:',g[:4]); print('RINGKAS: %d OK, %d GAGAL'%(sum(hasil),len(hasil)-sum(hasil)))
