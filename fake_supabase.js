// Klien Supabase tiruan untuk uji UI di browser (tanpa jaringan)
(function () {
  const hari = new Date().toISOString().slice(0, 10);
  const DATA = {
    profil_pengguna: [{ id: 'u1', email: 'admin@x.id', nama: 'Admin Uji', peran: window.__PERAN || 'admin', karyawan_id: 1, aktif: true }],
    pengaturan: [{ kunci: 'nama_perusahaan', nilai: 'PT Uji' }, { kunci: 'alamat_perusahaan', nilai: 'Jl. Uji 1' }],
    absensi: [], lembur: [{ id: 1, karyawan_id: 1, tanggal: hari, jam: 2, status: 'usulan' }], persetujuan: [{ id: 1, jenis: 'pembelian', tabel: 'barang_masuk', baris_id: 1, nominal: 6000000, uraian: 'Pembelian ban', diajukan: new Date().toISOString(), status: 'menunggu' }],
    produksi: [{ tanggal_timbangan: hari, shift_timbangan: '1', ritase: 1, tonase: 30, nominal: 3000000 }, { tanggal_timbangan: hari, shift_timbangan: '2', ritase: 1, tonase: 28, nominal: 2800000 }],
    penyesuaian_gaji: [], periode_kunci: [], log_audit: [{ id: 1, waktu: new Date().toISOString(), tabel: 'produksi', aksi: 'INSERT', baris_id: '1', baru: { a: 1 } }],
    unit: [{ id: 1, kode: 'DT-01', nama: 'Dump Truck 1', kategori: 'Dump Truck', status: 'aktif', hm_awal: 100 }], karyawan: [{ id: 1, kode: 'K1', nama: 'Budi', jabatan: 'Driver', aktif: true }],
    site: [{ id: 1, kode: 'S1', nama: 'Site A', lat: -6.2, lng: 106.8, radius_m: 150, aktif: true }], pelanggan: [{ id: 1, kode: 'P1', nama: 'PT Maju', termin_hari: 30, aktif: true, dasar_tonase: 'timbangan' }],
    pemasok: [{ id: 1, kode: 'S1', nama: 'CV Solar', termin_hari: 0, aktif: true }], barang: [{ id: 1, kode: 'BRG-0001', nama: 'Filter Oli', kategori: 'Filter', satuan: 'Pcs', stok_min: 2, aktif: true }],
    komponen_perawatan: [{ id: 1, nama: 'Oli mesin', aktif: true }], interval_perawatan: [], aturan_absensi: [{ id: 1, nama: 'Umum', jam_masuk: '06:00', jam_pulang: '18:00', toleransi_menit: 10, potongan_telat_jenis: 'tidak', potongan_telat_nilai: 0, potongan_alpa_jenis: 'tidak', potongan_alpa_nilai: 0, lembur_aktif: true, lembur_mulai_menit: 60, lembur_jenis: 'per_jam', lembur_nilai: 0, hari_kerja_per_bulan: 26, berlaku_mulai: hari, aktif: true }],
    aturan_persetujuan: [{ jenis: 'pembelian', aktif: true, batas_nominal: 5000000, penyetuju: 'admin', keterangan: '' }], metode_tagihan: [{ id: 1, kode: 'TON_KM', nama: 'Tonase x jarak x tarif', dasar: 'tonase', pakai_jarak: true, aktif: true }],
    kategori_kas: [{ id: 1, arah: 'masuk', nama: 'Pembayaran Hauling', aktivitas: 'Operasional', aktif: true }], akun: [{ kode: '1-1100', nama: 'Kas', kelompok: 'Aset', saldo_normal: 'debit', aktif: true }], pemetaan_akun: [{ kunci: 'PRODUKSI', akun_debit: '1-1300', akun_kredit: '4-1100', aktif: true }],
    aset: [], tarif_rute: [], dokumen: [], karyawan_gaji: [{ karyawan_id: 1, gaji_pokok: 3000000, tarif_makan_per_hari: 25000 }]
  };
  const tab = (judul, kolom, baris) => ({ judul: judul, kolom: kolom, baris: baris });
  const K = (s) => s.split('|').map(x => { const p = x.split(':'); return { k: p[0], l: p[1], t: p[2] }; });
  const RPC = {
    opsi_lapangan: () => ({ saya: { id: 'u1', nama: 'Admin Uji', peran: window.__PERAN || 'admin', karyawan_id: 1 }, unit: [{ id: 1, kode: 'DT-01', nama: 'Dump Truck 1', kategori: 'Dump Truck', status: 'aktif', hm: 120 }], karyawan: [{ id: 1, kode: 'K1', nama: 'Budi', jabatan: 'Driver' }], site: [{ id: 1, kode: 'S1', nama: 'Site A', lat: -6.2, lng: 106.8, radius_m: 150 }],
      rute: [{ site_id: 1, loading: 'L1', dumping: 'D1' }], barang: [{ id: 1, kode: 'BRG-0001', nama: 'Filter Oli', kategori: 'Filter', satuan: 'Pcs', saldo: 10 }], stok_bbm: 500, pemasok: [{ id: 1, kode: 'S1', nama: 'CV Solar', termin: 0 }], pelanggan: [{ id: 1, kode: 'P1', nama: 'PT Maju', termin: 30 }],
      komponen: [{ id: 1, nama: 'Oli mesin' }], kategori_kas: [{ arah: 'masuk', nama: 'Pembayaran Hauling', aktivitas: 'Operasional' }, { arah: 'keluar', nama: 'Gaji', aktivitas: 'Operasional' }], akun: [{ kode: '1-1100', nama: 'Kas', kelompok: 'Aset' }, { kode: '4-1200', nama: 'Pendapatan Sewa', kelompok: 'Pendapatan' }, { kode: '5-1950', nama: 'Beban Lain', kelompok: 'Beban' }], metode: [{ id: 1, kode: 'TON_KM', nama: 'Tonase x jarak x tarif', dasar: 'tonase', pakai_jarak: true }] }),
    dash_keuangan: () => ({ pendapatan: 100e6, beban: 60e6, laba: 40e6, margin: 40, tonase: 1000, pendapatan_per_ton: 100000, bulan: [{ b: '2026-10', pendapatan: 50e6, beban: 30e6 }, { b: '2026-11', pendapatan: 50e6, beban: 30e6 }], pelanggan: [{ nama: 'PT Maju', pendapatan: 100e6, tonase: 1000 }],
      rincian: { total: 60e6, item: [{ kunci: 'bbm', nama: 'Biaya Solar (BBM)', jumlah: 20e6 }, { kunci: 'suku', nama: 'Suku Cadang', jumlah: 5e6 }, { kunci: 'ban', nama: 'Perawatan & Ban', jumlah: 5e6 }, { kunci: 'gaji', nama: 'Gaji', jumlah: 20e6 }, { kunci: 'jasa', nama: 'Jasa Bengkel', jumlah: 2e6 }, { kunci: 'lain', nama: 'Lainnya', jumlah: 8e6 }], mentah: {} } }),
    dash_kas: () => ({ saldo_awal: 10e6, masuk: 50e6, keluar: 30e6, saldo_akhir: 30e6, kontra: 1e6, aktivitas: [{ nama: 'Operasional', masuk: 50e6, keluar: 30e6, sub: [{ nama: 'Pembayaran Hauling', masuk: 50e6, keluar: 0 }, { nama: 'Gaji', masuk: 0, keluar: 30e6 }] }], rekening: [{ nama: 'kas', awal: 5e6, masuk: 20e6, keluar: 10e6 }, { nama: 'bank', awal: 5e6, masuk: 30e6, keluar: 20e6 }], bulan: [{ b: '2026-11', masuk: 50e6, keluar: 30e6 }] }),
    dash_armada: () => ({ gaji_tampil: true, unit: [{ unit: 'DT-01', liter: 100, bbm: 1e6, suku: 1e5, ban: 2e5, jasa: 1e5, premi: 3e5, biaya: 1.7e6, tonase: 100, ritase: 5 }], rincian: { item: [{ kunci: 'bbm', nama: 'Biaya Solar (BBM)', jumlah: 1e6 }, { kunci: 'lain', nama: 'Lain', jumlah: 1 }], mentah: { suku: 1e5, ban: 2e5, jasa: 1e5 } }, total_biaya: 1.7e6, tonase: 100, biaya_per_ton: 17000 }),
    dash_rute: () => ({ rute: [{ rute: 'Site A: L1 - D1', trip: 10, ritase: 10, tonase: 300, nominal: 30e6 }], hari: [{ tanggal: '2026-11-01', tonase: 100, ritase: 3 }, { tanggal: '2026-11-02', tonase: 200, ritase: 7 }], total: { trip: 10, ritase: 10, tonase: 300, nominal: 30e6 } }),
    peringatan: () => ({ dokumen: [{ tipe: 'unit', nama: 'DT-01', dokumen: 'STNK', berlaku: '2026-11-01', sisa_hari: -5, level: 'expired' }, { tipe: 'karyawan', nama: 'Budi', dokumen: 'SIM', berlaku: '2026-11-25', sisa_hari: 6, level: 'h7' }], stok_minimum: [{ kode: 'X' }], servis: [{ unit: 'DT-01' }], faktur: [], persetujuan_menunggu: 1, lembur_menunggu: 1, hadir_hari_ini: 3, belum_absen: 2 }),
    lap_faktur: () => tab('Daftar Faktur Penagihan', K('id:ID:n|nomor:No faktur:t|tanggal:Tanggal:d|pelanggan:Pelanggan:t|jatuh_tempo:Jatuh tempo:d|dpp:DPP:n|ppn:PPN:n|pph:PPh:n|total_kotor:Kotor:n|kontra_berlaku:Kontra:n|dibayar_kas:Dibayar:n|sisa:Sisa:n|status:Status:t|hari_telat:Telat:n'), [{ id: 1, nomor: 'FP-202611-001', tanggal: '2026-11-30', pelanggan: 'PT Maju', jatuh_tempo: '2026-12-30', dpp: 1e8, ppn: 11e6, pph: 2e6, total_kotor: 109e6, kontra_berlaku: 0, dibayar_kas: 0, sisa: 109e6, status: 'draft', hari_telat: 0 }, { id: 2, nomor: 'FP-202611-002', tanggal: '2026-11-30', pelanggan: 'PT Maju', jatuh_tempo: '2026-12-30', dpp: 1e6, ppn: 0, pph: 0, total_kotor: 1e6, kontra_berlaku: 0, dibayar_kas: 0, sisa: 1e6, status: 'disetujui', hari_telat: 0 }]),
    lap_tagihan: () => tab('Daftar Tagihan Pemasok', K('id:ID:n|nomor:No:t|tanggal:Tgl:d|pemasok:Pemasok:t|uraian:Uraian:t|jumlah:Jumlah:n|dibayar_kas:Dibayar:n|dibayar_kontra:Kontra:n|sisa:Sisa:n|jatuh_tempo:Tempo:d|status:Status:t'), [{ id: 5, nomor: 'TG-1', tanggal: '2026-11-01', pemasok: 'CV Solar', uraian: 'Solar', jumlah: 5e6, dibayar_kas: 0, dibayar_kontra: 0, sisa: 5e6, jatuh_tempo: '2026-11-01', status: 'aktif' }]),
    lap_payroll: () => tab('Rekap Payroll', K('id:ID:n|nama:Nama:t|jabatan:Jabatan:t|hari_hadir:Hari:n|gaji_pokok:Gaji:n|thp:THP:n|status_bayar:Bayar:t'), [{ id: 7, nama: 'Budi', jabatan: 'Driver', hari_hadir: 20, gaji_pokok: 3e6, thp: 3.1e6, status_bayar: 'belum' }]),
    lap_perawatan: () => tab('Status Perawatan Unit', K('unit:Unit:t|komponen:Komponen:t|sisa_hm:Sisa HM:n|status:Status:t'), [{ unit: 'DT-01', komponen: 'Oli mesin', sisa_hm: -10, status: 'terlambat' }, { unit: 'DT-01', komponen: 'Filter', sisa_hm: 200, status: 'aman' }]),
    lap_konsumsi_bbm: () => tab('Konsumsi BBM per Unit', K('unit:Unit:t|liter:Liter:n|status:Status:t'), [{ unit: 'DT-01', liter: 100, status: 'Wajar' }]),
    detail_faktur: () => ({ faktur: { id: 1, nomor: 'FP-1', tanggal: '2026-11-30', jatuh_tempo: '2026-12-30', pelanggan: 'PT Maju', dpp: 1e8, ppn: 11e6, pph: 2e6, total_kotor: 109e6, kontra_bon_total: 1e5, dibayar_kas: 0, sisa: 109e6, status: 'draft' }, pelanggan: { npwp: '1', alamat: 'x' }, baris: [{ deskripsi: 'Hauling', kuantitas: 100, satuan: 'ton', tarif: 1000, jumlah: 1e8 }], kontra: [{ pemasok: 'CV Solar', nominal: 1e5, keterangan: 'Solar' }] }),
    slip_gaji: () => ({ payroll: { gaji_pokok: 3e6, premi_ritase: 1e5, premi_tonase: 0, hari_hadir: 20, tarif_makan: 25000, uang_makan: 5e5, pendapatan_kotor: 3.6e6, pendapatan_tidak_tetap: 2e5, potongan_kasbon: 1e5, potongan_tidak_tetap: 1.5e5, thp: 3.65e6, status_bayar: 'belum', periode_mulai: '2026-11-01', periode_akhir: '2026-11-30' }, karyawan: { nama: 'Budi', jabatan: 'Driver' }, penyesuaian: [{ tanggal: '2026-11-10', jenis: 'pendapatan', kategori: 'bonus', keterangan: 'Insentif', nominal: 2e5 }, { tanggal: '2026-11-12', jenis: 'potongan', kategori: 'kasbon', keterangan: '', nominal: 1e5 }] }),
    saya_laporan: () => ({ absensi: [{ tanggal: hari, status: 'hadir', masuk: new Date().toISOString(), pulang: null, telat_menit: 0, jam_kerja: null }], produksi: [{ tanggal: hari, no_spb: 'S1', rute: 'L1 - D1', ritase: 1, tonase: 30, premi: 50000 }], lembur: [], kasbon_saldo: 100000, slip: [{ id: 7, periode_mulai: '2026-11-01', periode_akhir: '2026-11-30', thp: 3e6, status_bayar: 'sudah' }], perawatan: [] }),
    lap_neraca: () => tab('Neraca', K('u:Uraian:t|j:Jumlah (Rp):n'), [{ u: 'ASET', _g: 'h' }, { u: '1-1100  Kas', j: 100 }, { u: 'Total Aset', j: 100, _g: 't' }]),
    kunci_periode: () => ({}), hitung_payroll: () => 1, bayar_payroll: () => ({ jumlah: 1, total: 3e6 }), buat_faktur: () => ({ id: 3, nomor: 'FP-202611-003', dpp: 5.8e6, ppn: 0, pph: 0, total_kotor: 5.8e6, kontra: 0, netto: 5.8e6, trip: 2 }),
    catat_pelunasan: () => ({ kas_id: 1, sisa: 0 }), setujui_faktur: () => ({}), batal_faktur: () => ({}), proses_persetujuan: () => ({}), proses_lembur: () => ({ nominal: 100000 }), batalkan_transaksi: () => ({}), lapor_gagal_sinkron: () => null,
    simpan_produksi: () => ({ id: 11, nominal: 3000000, premi: 50000, perlu_cek: false, pesan: '' }), simpan_bbm_pakai: () => ({ id: 12, nilai: 1500000, harga_fifo: 15000 }), simpan_pengeluaran: () => ({ id: 13, nilai: 100000 }), simpan_pembelian: () => ({ id: 14, nilai: 500000, status: 'aktif', pesan: '' }),
    simpan_perbaikan: () => ({ id: 15, total: 200000 }), simpan_servis: () => ({ id: 16, perbaikan_id: 17, total: 100 }), simpan_kas: () => ({ id: 18, status: 'aktif', pesan: '' }), simpan_kasbon: () => ({ id: 19 }), simpan_penyesuaian: () => ({ id: 20 }), simpan_jurnal_manual: () => ({ id: 21, nomor: 'JM-1', status: 'aktif' }),
    simpan_tagihan: () => ({ id: 22, nomor: 'TG-2' }), absen: (a) => ({ id: 23, aksi: a.p.aksi, telat_menit: 5, di_luar_radius: true, jarak_m: 300 }), catat_absensi_admin: () => ({ id: 24 })
  };
  window.__calls = [];
  window.__offline = false;
  function Q(tabel) {
    const q = { t: tabel, ops: [], head: false, single: false };
    ['select', 'eq', 'neq', 'is', 'not', 'gte', 'lte', 'gt', 'lt', 'order', 'limit', 'insert', 'update', 'delete', 'upsert'].forEach(m => { q[m] = function () { q.ops.push([m].concat(Array.from(arguments))); if (m === 'select' && arguments[1] && arguments[1].head) q.head = true; return q; }; });
    q.maybeSingle = () => { q.single = true; return q; }; q.single = false; q.single_ = () => q;
    q.then = (res, rej) => new Promise(r => setTimeout(r, 5)).then(() => {
      if (window.__offline) throw new TypeError('Failed to fetch');
      window.__calls.push({ tabel: tabel, ops: q.ops.map(o => o[0]) });
      const mut = q.ops.find(o => ['insert', 'update', 'delete', 'upsert'].indexOf(o[0]) >= 0);
      if (mut) return { data: null, error: null };
      const rows = (DATA[tabel] || []).slice();
      if (q.head) return { data: null, count: rows.length, error: null };
      return { data: q.single ? (rows[0] || null) : rows, error: null, count: rows.length };
    }).then(res, rej);
    return q;
  }
  const sesi = { user: { id: 'u1', email: 'admin@x.id' } };
  window.supabase = {
    createClient: () => ({
      auth: { getSession: async () => ({ data: { session: window.__tanpaSesi ? null : sesi } }), onAuthStateChange: () => ({}), signOut: async () => ({}), signInWithPassword: async () => ({ data: {}, error: null }), signUp: async () => ({ data: {}, error: null }) },
      from: Q,
      rpc: async (nama, args) => {
        await new Promise(r => setTimeout(r, 5));
        if (window.__offline) return { data: null, error: { message: 'TypeError: Failed to fetch' } };
        window.__calls.push({ rpc: nama, args: args });
        if (window.__rpcGalat && window.__rpcGalat[nama]) return { data: null, error: { code: 'P0001', message: window.__rpcGalat[nama] } };
        let f = RPC[nama];
        if (!f && /^lap_/.test(nama)) f = () => tab('Laporan Uji', K('a:Kolom A:t|b:Angka:n|c:Tanggal:d'), [{ a: 'x', b: 1500, c: '2026-11-05' }, { a: 'Total', b: 3000, _g: 't' }]);
        if (!f) return { data: null, error: { code: 'P0001', message: 'RPC tidak ditiru: ' + nama } };
        return { data: f(args), error: null };
      },
      storage: { from: () => ({ upload: async () => ({ error: null }) }) }
    })
  };
})();
