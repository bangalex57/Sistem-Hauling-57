from smoke import *
import time,zipfile,io
hasil=[]
def cek(nama,kond,info=''):
    hasil.append((nama,bool(kond)))
    print(('OK    ' if kond else 'GAGAL ')+nama+(('  -> '+str(info)[:200]) if (info and not kond) else ''))
def rpcs(pg,nama): return pg.evaluate("window.__calls.filter(c=>c.rpc==='%s')"%nama)
def ke(pg,h): pg.evaluate("location.hash='#/%s'"%h); pg.wait_for_timeout(500)
def klik_modal_ya(pg):
    pg.click('.modal-box [data-y]'); pg.wait_for_timeout(300)
def uji(pg,galat,gagal):
    hari=pg.evaluate("hariIni()")
    # ---- produksi: simpan, keep header, tanpa foto
    ke(pg,'inputan/produksi')
    pg.select_option('#f_unit_id','1'); pg.select_option('#f_site_id','1'); pg.fill('#f_loading','L1'); pg.fill('#f_dumping','D1'); pg.fill('#f_no_spb','SPB-1'); pg.fill('#f_tonase','32,5')
    pg.click('#btnSimpan'); pg.wait_for_timeout(500)
    c=rpcs(pg,'simpan_produksi'); p=c[-1]['args']['p'] if c else {}
    cek('Produksi memanggil simpan_produksi',len(c)==1,c)
    cek('Tonase "32,5" terkirim 32.5',p.get('tonase')==32.5,p)
    cek('Tanggal timbangan terisi otomatis',p.get('tanggal_timbangan')==hari and p.get('shift_timbangan'),p)
    cek('klien_id (anti ganda) terisi',bool(p.get('klien_id')),p)
    cek('Keep header: unit tetap, SPB kosong',pg.input_value('#f_unit_id')=='1' and pg.input_value('#f_no_spb')=='',pg.input_value('#f_unit_id'))
    pg.uncheck('#keepToggle'); pg.select_option('#f_site_id','1'); pg.fill('#f_loading','L1'); pg.fill('#f_dumping','D1'); pg.fill('#f_no_spb','SPB-2'); pg.fill('#f_tonase','10'); pg.click('#btnSimpan'); pg.wait_for_timeout(500)
    cek('Keep header mati: unit dikosongkan',pg.input_value('#f_unit_id')=='',pg.input_value('#f_unit_id'))
    pg.check('#keepToggle')
    # ---- offline: antre lalu sinkron
    pg.evaluate("window.__offline=true"); pg.context.set_offline(True)
    pg.select_option('#f_unit_id','1'); pg.select_option('#f_site_id','1'); pg.fill('#f_loading','L1'); pg.fill('#f_dumping','D1'); pg.fill('#f_no_spb','SPB-OFF'); pg.fill('#f_tonase','20')
    pg.click('#btnSimpan'); pg.wait_for_timeout(700)
    n=pg.evaluate("antrianSemua().then(a=>a.length)")
    cek('Offline: data masuk antrean perangkat',n==1,n)
    cek('Offline: pesan tersimpan di perangkat',('perangkat' in pg.inner_text('#hasilForm')),pg.inner_text('#hasilForm'))
    cek('Indikator menampilkan menunggu sinkron',('menunggu' in pg.inner_text('#status')),pg.inner_text('#status'))
    pg.evaluate("window.__offline=false"); pg.context.set_offline(False)
    pg.evaluate("window.__calls=[]"); pg.evaluate("sinkronAntrian()"); pg.wait_for_timeout(800)
    n=pg.evaluate("antrianSemua().then(a=>a.length)")
    cek('Online lagi: antrean terkirim dan kosong',n==0 and len(rpcs(pg,'simpan_produksi'))==1,(n,rpcs(pg,'simpan_produksi')))
    # ---- BBM: alokasi menyembunyikan unit
    ke(pg,'inputan/bbm')
    cek('BBM alokasi unit: kolom unit tampil',pg.is_visible('#f_unit_id'))
    pg.select_option('#f_alokasi','umum'); pg.wait_for_timeout(100)
    cek('BBM alokasi umum: unit dan HM tersembunyi',not pg.is_visible('#f_unit_id') and not pg.is_visible('#f_hm_akhir') and pg.is_visible('#f_ket_alokasi'))
    pg.fill('#f_liter','50'); pg.click('#btnSimpan'); pg.wait_for_timeout(400)
    p=rpcs(pg,'simpan_bbm_pakai')[-1]['args']['p']
    cek('BBM umum terkirim tanpa unit/HM',p.get('alokasi')=='umum' and p.get('unit_id') is None and p.get('hm_akhir') is None and p.get('liter')==50,p)
    # ---- pembelian: toggle tipe
    ke(pg,'inputan/pembelian')
    pg.click('[data-tipe=langsung]'); pg.wait_for_timeout(150)
    cek('Pembelian beban langsung: field uraian tampil, barang tersembunyi',pg.is_visible('#f_uraian') and not pg.is_visible('#f_barang_id'))
    pg.select_option('#f_alokasi','unit'); pg.wait_for_timeout(100)
    cek('Beban langsung alokasi unit memunculkan unit',pg.is_visible('#f_unit_id'))
    pg.fill('#f_uraian','Las darurat'); pg.select_option('#f_unit_id','1'); pg.fill('#f_nominal','150000'); pg.click('#btnSimpan'); pg.wait_for_timeout(400)
    p=rpcs(pg,'simpan_pembelian')[-1]['args']['p']
    cek('Pembelian langsung payload benar',p.get('tipe')=='langsung' and p.get('nominal')==150000 and p.get('alokasi')=='unit',p)
    pg.click('[data-tipe=stok]'); pg.select_option('#f_barang_id','__baru'); pg.wait_for_timeout(120)
    cek('Barang baru memunculkan isian nama',pg.is_visible('#f_baru_nama'))
    pg.fill('#f_baru_nama','Ban 1200'); pg.fill('#f_qty','4'); pg.fill('#f_harga','2.500.000'); pg.click('#btnSimpan'); pg.wait_for_timeout(400)
    p=rpcs(pg,'simpan_pembelian')[-1]['args']['p']
    cek('Pembelian stok barang baru + harga 2.500.000 terbaca',p.get('tipe')=='stok' and p.get('baru',{}).get('nama')=='Ban 1200' and p.get('harga')==2500000,p)
    # ---- perbaikan multi item
    ke(pg,'inputan/perbaikan')
    pg.select_option('#f_unit_id','1'); pg.fill('#f_deskripsi','Ganti ban')
    pg.fill('#f_nama_0','Ban 1200'); pg.fill('#f_qty_0','2'); pg.fill('#f_harga_0','2000000')
    pg.click('text=+ Tambah item'); pg.wait_for_timeout(100)
    pg.select_option('#f_sumber_1','stok'); pg.wait_for_timeout(100)
    cek('Item stok: pilih barang tampil, nama/harga tersembunyi',pg.is_visible('#f_barang_id_1') and not pg.is_visible('#f_nama_1') and not pg.is_visible('#f_harga_1'))
    pg.select_option('#f_barang_id_1','1'); pg.fill('#f_qty_1','1')
    pg.click('#btnSimpan'); pg.wait_for_timeout(500)
    p=rpcs(pg,'simpan_perbaikan')[-1]['args']['p']
    it=p.get('items',[])
    cek('Perbaikan 2 item (langsung + stok) terkirim',len(it)==2 and it[0]['sumber']=='langsung' and it[0]['harga']==2000000 and it[1]['sumber']=='stok' and it[1]['barang_id']=='1',p)
    cek('Keep header perbaikan: deskripsi dan unit tetap',pg.input_value('#f_deskripsi')=='Ganti ban' and pg.input_value('#f_unit_id')=='1')
    cek('Daftar item direset ke 1 baris',pg.evaluate("document.querySelectorAll('.dinamis-baris').length")==1)
    # ---- faktur: tarik data, PPN, PPh, kontra bon
    ke(pg,'inputan/fakturbaru')
    pg.select_option('#f_pelanggan_id','1'); pg.click('#fkTarik'); pg.wait_for_timeout(500)
    txt=pg.inner_text('#fkRingkas')
    cek('DPP dari data timbangan = Rp 5.800.000',('5.800.000' in txt),txt)
    pg.check('#f_ppn_on'); pg.check('#f_pph_on'); pg.wait_for_timeout(150)
    txt=pg.inner_text('#fkRingkas')
    cek('PPN 11% = 638.000 dan PPh 2% = 116.000',('638.000' in txt and '116.000' in txt),txt)
    cek('Total kotor 6.322.000',('6.322.000' in txt),txt)
    pg.check('#f_kontra_on'); pg.wait_for_timeout(200)
    pg.fill('#f_nominal_0','100000'); pg.wait_for_timeout(150)
    txt=pg.inner_text('#fkRingkas')
    cek('Sisa netto setelah kontra bon 6.222.000',('6.222.000' in txt),txt)
    pg.click('#fkDraft'); pg.wait_for_timeout(200); klik_modal_ya(pg); pg.wait_for_timeout(300)
    p=rpcs(pg,'buat_faktur')[-1]['args']['p']
    cek('buat_faktur: ppn 11, pph 2, kontra 100000, draft',p.get('ppn')==11 and p.get('pph')==2 and p.get('setuju') is False and len(p.get('kontra',[]))==1 and p['kontra'][0]['nominal']==100000,p)
    # ---- ekspor CSV dan XLSX
    ke(pg,'laporan/lr')
    with pg.expect_download() as d: pg.click('.bar-ekspor [data-f=csv]')
    path=d.value.path(); data=open(path,'rb').read()
    cek('CSV terunduh dengan BOM dan data',data[:3]==b'\xef\xbb\xbf' and b'Kolom A' in data,data[:80])
    with pg.expect_download() as d: pg.click('.bar-ekspor [data-f=xlsx]')
    path=d.value.path(); data=open(path,'rb').read()
    z=zipfile.ZipFile(io.BytesIO(data)); ok=z.testzip() is None and 'xl/worksheets/sheet1.xml' in z.namelist()
    cek('XLSX terunduh dan zip valid',ok,d.value.suggested_filename)
    open('/tmp/unduhan.xlsx','wb').write(data)
    # ---- absen
    ke(pg,'inputan/absensi'); pg.click('#abMasuk'); pg.wait_for_timeout(900)
    c=rpcs(pg,'absen'); p=c[-1]['args']['p'] if c else {}
    cek('Absen masuk membawa GPS dan aksi',p.get('aksi')=='masuk' and abs((p.get('lat') or 0)+6.2)<0.01 and p.get('site_id')==1,p)
    cek('Pesan di luar radius ditampilkan',('luar radius' in pg.inner_text('#abHasil')),pg.inner_text('#abHasil'))
    # ---- payroll
    ke(pg,'laporan/payroll'); pg.click('#pyHitung'); pg.wait_for_timeout(200); klik_modal_ya(pg); pg.wait_for_timeout(300)
    cek('Hitung payroll dipanggil',len(rpcs(pg,'hitung_payroll'))==1)
    pg.click('[data-slip]'); pg.wait_for_timeout(400)
    s=pg.inner_text('.modal-box')
    cek('Slip menampilkan rincian penyesuaian dan THP',('Insentif' in s and 'TAKE HOME PAY' in s and '3.650.000' in s),s[:200])
    pg.click('.modal-box [data-tutup]'); pg.wait_for_timeout(100)
    pg.check('[data-pilih]'); pg.click('#pyBayar'); pg.wait_for_timeout(200); klik_modal_ya(pg); pg.wait_for_timeout(300)
    c=rpcs(pg,'bayar_payroll'); cek('Bayar payroll mengirim id terpilih',c and c[-1]['args']['p_ids']==[7],c)
    # ---- daftar faktur: aksi menurut status
    ke(pg,'laporan/faktur')
    cek('Draft punya Setujui+Batalkan, disetujui punya Pelunasan',pg.evaluate("document.querySelectorAll('[data-s]').length==1 && document.querySelectorAll('[data-b]').length==1 && document.querySelectorAll('[data-p]').length==1"))
    pg.click('[data-p]'); pg.wait_for_timeout(200); pg.click('#pl_s'); pg.wait_for_timeout(400)
    c=rpcs(pg,'catat_pelunasan'); cek('Pelunasan netto dikirim dengan nominal default sisa',c and c[-1]['args']['p_nominal']==1000000,c)
    # ---- persetujuan
    ke(pg,'inputan/persetujuan'); pg.click('[data-y]'); pg.wait_for_timeout(300)
    cek('Persetujuan: setujui memanggil proses_persetujuan',len(rpcs(pg,'proses_persetujuan'))==1)
    # ---- tema gelap
    pg.click('#temaBtn'); cek('Mode gelap aktif',pg.evaluate("document.documentElement.classList.contains('dark')"))
    pg.click('#temaBtn')
g,f=jalankan('admin',uji)
print('\nGALAT KONSOL:',g[:6])
print('RINGKAS: %d OK, %d GAGAL'%(sum(1 for _,k in hasil if k),sum(1 for _,k in hasil if not k)))
