-- =====================================================================
-- SISTEM HAULING V6 (Supabase / PostgreSQL)
-- Jalankan seluruh berkas ini sekali di Supabase > SQL Editor.
-- Aman untuk proyek baru (mulai dari nol). Urutan bagian: 1 dasar, 2 operasional, 3 SDM, 4 keuangan,
-- 5 jurnal (view), 6 RPC transaksi, 7 laporan, 8 keamanan (RLS), 9 data awal.
-- =====================================================================
set check_function_bodies = off;

-- Keamanan: fungsi baru TIDAK otomatis bisa dipanggil klien. Hanya fungsi API yang diberi GRANT EXECUTE di bagian 8.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public revoke execute on functions from authenticated;

-- ---------- 1. DASAR: waktu, pengaturan, akses ----------
create or replace function hari_ini() returns date language sql stable as $$
  select (now() at time zone 'Asia/Jakarta')::date
$$;

create table pengaturan (
  kunci text primary key,
  nilai text,
  keterangan text
);

create table site (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text not null,
  lat numeric,
  lng numeric,
  radius_m integer not null default 150 check (radius_m > 0),
  aktif boolean not null default true
);

create table profil_pengguna (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  nama text,
  peran text not null default 'operator' check (peran in ('admin','keuangan','manajemen','supervisor','operator')),
  karyawan_id bigint,
  aktif boolean not null default false,
  dibuat timestamptz not null default now()
);

create table log_audit (
  id bigint generated always as identity primary key,
  waktu timestamptz not null default now(),
  user_id uuid,
  tabel text,
  aksi text,
  baris_id text,
  lama jsonb,
  baru jsonb
);

create or replace function peran_saya() returns text language sql stable security definer set search_path = public as $$
  select peran from profil_pengguna where id = auth.uid() and aktif
$$;

create or replace function karyawan_saya() returns bigint language sql stable security definer set search_path = public as $$
  select karyawan_id from profil_pengguna where id = auth.uid() and aktif
$$;

create or replace function adalah(p text[]) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(peran_saya() = any(p), false)
$$;

create or replace function wajib_peran(p text[]) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not adalah(p) then
    raise exception 'Akses ditolak untuk peran Anda.';
  end if;
end $$;

-- pengguna pertama otomatis Admin aktif; berikutnya Operator nonaktif sampai diaktifkan Admin
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from profil_pengguna;
  insert into profil_pengguna(id, email, nama, peran, aktif)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'nama', new.email), case when n = 0 then 'admin' else 'operator' end, n = 0);
  return new;
end $$;

create trigger trg_user_baru after insert on auth.users for each row execute function handle_new_user();

create or replace function audit_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare j jsonb;
begin
  if tg_op = 'DELETE' then j := to_jsonb(old); else j := to_jsonb(new); end if;
  insert into log_audit(user_id, tabel, aksi, baris_id, lama, baru)
  values (auth.uid(), tg_table_name, tg_op, coalesce(j->>'id', j->>'kunci', ''),
          case when tg_op <> 'INSERT' then to_jsonb(old) end, case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return null;
end $$;

-- ---------- master ----------
create table karyawan (
  id bigint generated always as identity primary key,
  kode text unique,
  nama text not null,
  jabatan text not null default 'Driver',
  site_id bigint references site(id),
  tgl_masuk date,
  no_hp text,
  bank text,
  no_rekening text,
  aktif boolean not null default true
);

create table karyawan_gaji (
  karyawan_id bigint primary key references karyawan(id) on delete cascade,
  gaji_pokok numeric not null default 0 check (gaji_pokok >= 0),
  tarif_makan_per_hari numeric not null default 0 check (tarif_makan_per_hari >= 0)
);

alter table profil_pengguna add constraint fk_profil_karyawan foreign key (karyawan_id) references karyawan(id) on delete set null;

create table unit (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text,
  kategori text,
  merek text,
  model text,
  tahun integer,
  plat text,
  status text not null default 'aktif' check (status in ('aktif','standby','breakdown','nonaktif')),
  bisa_disewakan boolean not null default false,       -- disiapkan untuk Fase 2 (sewa alat)
  hm_awal numeric not null default 0,
  site_id bigint references site(id)
);

create table dokumen (
  id bigint generated always as identity primary key,
  pemilik_tipe text not null check (pemilik_tipe in ('unit','karyawan')),
  pemilik_id bigint not null,
  jenis text not null,
  nomor text,
  berlaku_sampai date not null,
  keterangan text
);

create table pelanggan (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text not null,
  npwp text,
  alamat text,
  termin_hari integer not null default 30 check (termin_hari >= 0),
  dasar_tonase text not null default 'timbangan' check (dasar_tonase in ('timbangan','terima')),
  aktif boolean not null default true
);

create table pemasok (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text not null,
  termin_hari integer not null default 0 check (termin_hari >= 0),
  aktif boolean not null default true
);

-- Metode tagihan. Fase 1 hanya TON_KM aktif; lainnya disiapkan untuk Fase 2 dan diaktifkan Admin.
create table metode_tagihan (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text not null,
  dasar text not null check (dasar in ('tonase','ritase','volume','hm','hari','bulan','tetap')),
  pakai_jarak boolean not null default false,
  nilai_minimum numeric,
  aktif boolean not null default false
);

create table tarif_rute (
  id bigint generated always as identity primary key,
  pelanggan_id bigint not null references pelanggan(id),
  site_id bigint not null references site(id),
  loading text not null,
  dumping text not null,
  jarak_km numeric not null default 0 check (jarak_km >= 0),
  metode_id bigint not null references metode_tagihan(id),
  tarif numeric not null check (tarif >= 0),
  premi_jenis text not null default 'ritase' check (premi_jenis in ('ritase','tonase')),
  premi_nilai numeric not null default 0 check (premi_nilai >= 0),
  berlaku_mulai date not null,
  aktif boolean not null default true,
  unique (site_id, loading, dumping, berlaku_mulai)
);
create index ix_tarif_rute_cari on tarif_rute (site_id, loading, dumping, berlaku_mulai desc);

-- pembukuan
create table periode_kunci (
  id bigint generated always as identity primary key,
  sampai date not null,
  dikunci_oleh uuid default auth.uid(),
  waktu timestamptz not null default now()
);

create or replace function tanggal_terkunci(d date) returns boolean language sql stable security definer set search_path = public as $$
  select d is not null and exists (select 1 from periode_kunci k where d <= k.sampai
                                   and k.id = (select max(id) from periode_kunci))
$$;

create or replace function cek_kunci_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare kol text := tg_argv[0]; dn date; dl date;
begin
  if tg_op <> 'DELETE' then dn := (to_jsonb(new)->>kol)::date; end if;
  if tg_op <> 'INSERT' then dl := (to_jsonb(old)->>kol)::date; end if;
  if tanggal_terkunci(dn) or tanggal_terkunci(dl) then
    raise exception 'Periode sudah dikunci. Transaksi bertanggal sampai % tidak bisa diubah.', (select max(sampai) from periode_kunci);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
-- ---------- 2. OPERASIONAL: produksi, BBM, gudang, perbaikan, perawatan ----------
create table produksi (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  shift text not null check (shift in ('1','2')),
  tanggal_timbangan date,
  shift_timbangan text check (shift_timbangan in ('1','2')),
  unit_id bigint not null references unit(id),
  karyawan_id bigint not null references karyawan(id),
  site_id bigint not null references site(id),
  loading text not null,
  dumping text not null,
  no_spb text,
  ritase integer not null default 1 check (ritase > 0),
  tonase numeric not null check (tonase >= 0),
  tonase_terima numeric check (tonase_terima >= 0),
  volume_m3 numeric check (volume_m3 >= 0),
  jam_masuk_loading time, jam_keluar_loading time, jam_masuk_dumping time, jam_keluar_dumping time,
  keterangan text,
  -- hasil hitung otomatis (nilai mati yang dihitung database)
  tarif_id bigint,
  pelanggan_id bigint,
  metode_id bigint,
  jarak_km numeric,
  tarif numeric,
  nominal numeric,
  premi numeric not null default 0,
  premi_jenis text,
  perlu_cek boolean not null default false,
  faktur_id bigint,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create unique index ux_produksi_spb on produksi (lower(no_spb)) where status <> 'batal' and no_spb is not null and no_spb <> '';
create index ix_produksi_tgb on produksi (tanggal_timbangan);
create index ix_produksi_pel on produksi (pelanggan_id, tanggal_timbangan) where faktur_id is null;

create or replace function trg_produksi() returns trigger language plpgsql as $$
declare r record; q numeric; dt text;
begin
  if tg_op = 'UPDATE' and old.faktur_id is not null and new.status = 'aktif' and (
       new.tonase is distinct from old.tonase or new.ritase is distinct from old.ritase
    or new.tanggal_timbangan is distinct from old.tanggal_timbangan or new.site_id is distinct from old.site_id
    or new.loading is distinct from old.loading or new.dumping is distinct from old.dumping
    or new.volume_m3 is distinct from old.volume_m3 or new.tonase_terima is distinct from old.tonase_terima) then
    raise exception 'Trip ini sudah ditagih pada faktur. Batalkan faktur draft dulu sebelum mengubahnya.';
  end if;
  new.tanggal_timbangan := coalesce(new.tanggal_timbangan, new.tanggal);
  new.shift_timbangan := coalesce(new.shift_timbangan, new.shift);
  -- tarif dipilih menurut TANGGAL TIMBANGAN (bukan tanggal produksi)
  select t.id, t.pelanggan_id, t.metode_id, t.jarak_km, t.tarif, t.premi_jenis, t.premi_nilai, m.dasar, m.pakai_jarak
    into r
    from tarif_rute t join metode_tagihan m on m.id = t.metode_id
   where t.site_id = new.site_id and lower(t.loading) = lower(new.loading) and lower(t.dumping) = lower(new.dumping)
     and t.aktif and t.berlaku_mulai <= new.tanggal_timbangan
   order by t.berlaku_mulai desc limit 1;
  if not found then
    new.tarif_id := null; new.pelanggan_id := null; new.metode_id := null; new.jarak_km := null; new.tarif := null;
    new.nominal := null; new.premi := 0; new.perlu_cek := true;
    return new;
  end if;
  new.tarif_id := r.id; new.pelanggan_id := r.pelanggan_id; new.metode_id := r.metode_id;
  new.jarak_km := r.jarak_km; new.tarif := r.tarif;
  select dasar_tonase into dt from pelanggan where id = r.pelanggan_id;
  q := case r.dasar
         when 'tonase' then case when dt = 'terima' and new.tonase_terima is not null then new.tonase_terima else new.tonase end
         when 'ritase' then new.ritase::numeric
         when 'volume' then new.volume_m3
         when 'tetap' then 1
         else null end;
  new.nominal := case when q is null then null else round(q * case when r.pakai_jarak then r.jarak_km else 1 end * r.tarif, 2) end;
  new.perlu_cek := (new.nominal is null);
  new.premi_jenis := r.premi_jenis;
  new.premi := round(case r.premi_jenis when 'ritase' then new.ritase * r.premi_nilai when 'tonase' then new.tonase * r.premi_nilai else 0 end, 2);
  return new;
end $$;
create trigger trg_produksi_hitung before insert or update on produksi for each row execute function trg_produksi();
create trigger trg_produksi_kunci before insert or update or delete on produksi for each row execute function cek_kunci_trg('tanggal_timbangan');

-- ---------- FIFO (BBM dan barang gudang) ----------
create table fifo_konsumsi (
  id bigint generated always as identity primary key,
  sumber text not null,
  sumber_id bigint not null,
  lapis text not null check (lapis in ('bbm','barang')),
  lapis_id bigint not null,
  qty numeric not null,
  harga numeric not null
);
create index ix_fifo_sumber on fifo_konsumsi (sumber, sumber_id);

create table bbm_masuk (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  no_po text,
  pemasok_id bigint references pemasok(id),
  supplier text,
  liter numeric not null check (liter > 0),
  harga_per_liter numeric not null check (harga_per_liter > 0),
  nilai numeric generated always as (round(liter * harga_per_liter, 2)) stored,
  sisa numeric not null default 0,
  cara_bayar text not null default 'tunai' check (cara_bayar in ('tunai','kredit')),
  rekening text not null default 'kas' check (rekening in ('kas','bank')),
  status text not null default 'aktif' check (status in ('aktif','menunggu','ditolak','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);

create table barang (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text not null,
  kategori text not null default 'Spare Part' check (kategori in ('Spare Part','Ban','Oli','Filter','Alat Bengkel','ATK/Mess','Lainnya')),
  satuan text not null default 'Pcs',
  stok_min numeric not null default 0,
  aktif boolean not null default true
);

create table barang_masuk (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  no_ref text,
  pemasok_id bigint references pemasok(id),
  supplier text,
  barang_id bigint not null references barang(id),
  qty numeric not null check (qty > 0),
  harga numeric not null check (harga > 0),
  nilai numeric generated always as (round(qty * harga, 2)) stored,
  sisa numeric not null default 0,
  cara_bayar text not null default 'tunai' check (cara_bayar in ('tunai','kredit')),
  rekening text not null default 'kas' check (rekening in ('kas','bank')),
  status text not null default 'aktif' check (status in ('aktif','menunggu','ditolak','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create index ix_barang_masuk_fifo on barang_masuk (barang_id, tanggal, id) where status = 'aktif' and sisa > 0;
create index ix_bbm_masuk_fifo on bbm_masuk (tanggal, id) where status = 'aktif' and sisa > 0;

create or replace function trg_masuk_sisa() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.sisa := case when new.status = 'aktif' then (case tg_table_name when 'bbm_masuk' then (to_jsonb(new)->>'liter')::numeric else (to_jsonb(new)->>'qty')::numeric end) else 0 end;
  end if;
  return new;
end $$;
create trigger trg_bbm_masuk_sisa before insert on bbm_masuk for each row execute function trg_masuk_sisa();
create trigger trg_barang_masuk_sisa before insert on barang_masuk for each row execute function trg_masuk_sisa();
create trigger trg_bbm_masuk_kunci before insert or update or delete on bbm_masuk for each row execute function cek_kunci_trg('tanggal');
create trigger trg_barang_masuk_kunci before insert or update or delete on barang_masuk for each row execute function cek_kunci_trg('tanggal');

create or replace function fifo_ambil(p_lapis text, p_barang bigint, p_qty numeric, p_tgl date, p_sumber text, p_sumber_id bigint)
returns numeric language plpgsql as $$
declare r record; butuh numeric := p_qty; ambil numeric; total numeric := 0;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'Jumlah harus lebih dari 0.'; end if;
  if p_lapis = 'bbm' then
    for r in select id, sisa, harga_per_liter as harga from bbm_masuk
              where status = 'aktif' and sisa > 0 and tanggal <= p_tgl order by tanggal, id for update loop
      exit when butuh <= 0;
      ambil := least(r.sisa, butuh);
      update bbm_masuk set sisa = sisa - ambil where id = r.id;
      insert into fifo_konsumsi(sumber, sumber_id, lapis, lapis_id, qty, harga) values (p_sumber, p_sumber_id, 'bbm', r.id, ambil, r.harga);
      total := total + ambil * r.harga; butuh := butuh - ambil;
    end loop;
  else
    for r in select id, sisa, harga from barang_masuk
              where barang_id = p_barang and status = 'aktif' and sisa > 0 and tanggal <= p_tgl order by tanggal, id for update loop
      exit when butuh <= 0;
      ambil := least(r.sisa, butuh);
      update barang_masuk set sisa = sisa - ambil where id = r.id;
      insert into fifo_konsumsi(sumber, sumber_id, lapis, lapis_id, qty, harga) values (p_sumber, p_sumber_id, 'barang', r.id, ambil, r.harga);
      total := total + ambil * r.harga; butuh := butuh - ambil;
    end loop;
  end if;
  if butuh > 0.000001 then
    raise exception 'Stok tidak cukup pada % (kurang %).', p_tgl, round(butuh, 2);
  end if;
  return round(total, 2);
end $$;

create or replace function fifo_kembali(p_sumber text, p_sumber_id bigint) returns void language plpgsql as $$
declare r record;
begin
  for r in select * from fifo_konsumsi where sumber = p_sumber and sumber_id = p_sumber_id loop
    if r.lapis = 'bbm' then update bbm_masuk set sisa = sisa + r.qty where id = r.lapis_id;
    else update barang_masuk set sisa = sisa + r.qty where id = r.lapis_id; end if;
  end loop;
  delete from fifo_konsumsi where sumber = p_sumber and sumber_id = p_sumber_id;
end $$;

-- ---------- pengisian BBM ----------
create table bbm_pakai (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  shift text not null check (shift in ('1','2')),
  unit_id bigint references unit(id),
  karyawan_id bigint references karyawan(id),
  alokasi text not null default 'unit' check (alokasi in ('unit','lapangan','umum','lain')),
  ket_alokasi text,
  hm_awal numeric,
  hm_akhir numeric,
  liter numeric not null check (liter > 0),
  lokasi text,
  harga_fifo numeric,
  nilai numeric,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);

create or replace function trg_bbm_pakai() returns trigger language plpgsql as $$
declare total numeric; h numeric;
begin
  if tg_op = 'INSERT' and new.status = 'aktif' then
    if new.alokasi = 'unit' then
      if new.unit_id is null then raise exception 'No unit wajib untuk alokasi Unit Armada.'; end if;
      if new.hm_akhir is null then raise exception 'HM akhir wajib untuk alokasi Unit Armada.'; end if;
      if new.hm_awal is null then
        select hm_akhir into h from bbm_pakai where unit_id = new.unit_id and status = 'aktif' and hm_akhir is not null order by tanggal desc, id desc limit 1;
        if h is null then select hm_awal into h from unit where id = new.unit_id; end if;
        new.hm_awal := h;
      end if;
      if new.hm_akhir < new.hm_awal then raise exception 'HM akhir tidak boleh lebih kecil dari HM awal.'; end if;
    elsif new.alokasi = 'lain' and coalesce(new.ket_alokasi, '') = '' then
      raise exception 'Keterangan alokasi wajib untuk Lain-lain / Non-Operasional.';
    end if;
    total := fifo_ambil('bbm', null, new.liter, new.tanggal, 'bbm_pakai', new.id);
    new.nilai := total;
    new.harga_fifo := round(total / new.liter, 4);
  end if;
  return new;
end $$;
create trigger trg_bbm_pakai_hitung before insert on bbm_pakai for each row execute function trg_bbm_pakai();
create trigger trg_bbm_pakai_kunci before insert or update or delete on bbm_pakai for each row execute function cek_kunci_trg('tanggal');

-- ---------- pengeluaran barang, pembelian langsung ----------
create table perbaikan (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  shift text check (shift in ('1','2')),
  unit_id bigint not null references unit(id),
  pelapor_id bigint references karyawan(id),
  mekanik_id bigint references karyawan(id),
  kategori text,
  hm numeric,
  deskripsi text,
  asal text not null default 'perbaikan' check (asal in ('perbaikan','servis','pengeluaran','pembelian_langsung')),
  total numeric not null default 0,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);

create table barang_keluar (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  shift text check (shift in ('1','2')),
  barang_id bigint not null references barang(id),
  qty numeric not null check (qty > 0),
  alokasi text not null default 'unit' check (alokasi in ('unit','lapangan','umum','lain')),
  unit_id bigint references unit(id),
  penerima_id bigint references karyawan(id),
  keterangan text,
  harga_fifo numeric,
  nilai numeric,
  perbaikan_id bigint references perbaikan(id),
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);

create or replace function trg_barang_keluar() returns trigger language plpgsql as $$
declare total numeric;
begin
  if tg_op = 'INSERT' and new.status = 'aktif' then
    if new.alokasi = 'unit' and new.unit_id is null then raise exception 'No unit wajib untuk alokasi Unit Armada.'; end if;
    if new.alokasi = 'lain' and coalesce(new.keterangan, '') = '' then raise exception 'Keterangan wajib untuk alokasi Lain-lain / Non-Operasional.'; end if;
    total := fifo_ambil('barang', new.barang_id, new.qty, new.tanggal, 'barang_keluar', new.id);
    new.nilai := total;
    new.harga_fifo := round(total / new.qty, 4);
  end if;
  return new;
end $$;
create trigger trg_barang_keluar_hitung before insert on barang_keluar for each row execute function trg_barang_keluar();
create trigger trg_barang_keluar_kunci before insert or update or delete on barang_keluar for each row execute function cek_kunci_trg('tanggal');
create trigger trg_perbaikan_kunci before insert or update or delete on perbaikan for each row execute function cek_kunci_trg('tanggal');

create table perbaikan_item (
  id bigint generated always as identity primary key,
  perbaikan_id bigint not null references perbaikan(id) on delete cascade,
  jenis_item text not null check (jenis_item in ('suku_cadang','ban','perawatan_rutin','jasa_bengkel')),
  nama text not null,
  qty numeric not null check (qty > 0),
  satuan text not null default 'Pcs',
  harga numeric not null check (harga >= 0),
  subtotal numeric generated always as (round(qty * harga, 2)) stored,
  sumber text not null default 'langsung' check (sumber in ('stok','langsung')),
  barang_id bigint references barang(id),
  barang_keluar_id bigint references barang_keluar(id),
  komponen_id bigint
);
create index ix_perbaikan_item_p on perbaikan_item (perbaikan_id);

create table pembelian_langsung (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  pemasok_id bigint references pemasok(id),
  supplier text,
  uraian text not null,
  alokasi text not null default 'lapangan' check (alokasi in ('unit','lapangan','umum','lain')),
  unit_id bigint references unit(id),
  kategori_kerusakan text,
  nominal numeric not null check (nominal > 0),
  cara_bayar text not null default 'tunai' check (cara_bayar in ('tunai','kredit')),
  rekening text not null default 'kas' check (rekening in ('kas','bank')),
  keterangan text,
  perbaikan_id bigint references perbaikan(id),
  status text not null default 'aktif' check (status in ('aktif','menunggu','ditolak','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create trigger trg_pembelian_langsung_kunci before insert or update or delete on pembelian_langsung for each row execute function cek_kunci_trg('tanggal');

-- ---------- perawatan berkala (satuan HM) ----------
create table komponen_perawatan (
  id bigint generated always as identity primary key,
  nama text unique not null,
  keterangan text,
  aktif boolean not null default true
);

create table interval_perawatan (
  id bigint generated always as identity primary key,
  komponen_id bigint not null references komponen_perawatan(id) on delete cascade,
  cakupan text not null default 'umum' check (cakupan in ('umum','kategori','unit')),
  kategori text,
  unit_id bigint references unit(id),
  interval_hm numeric not null check (interval_hm > 0),
  ambang_segera_hm numeric not null default 50 check (ambang_segera_hm >= 0),
  aktif boolean not null default true,
  check ((cakupan = 'umum') or (cakupan = 'kategori' and kategori is not null) or (cakupan = 'unit' and unit_id is not null))
);

create table servis (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  unit_id bigint not null references unit(id),
  hm numeric not null check (hm >= 0),
  mekanik_id bigint references karyawan(id),
  keterangan text,
  perbaikan_id bigint references perbaikan(id),
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);

create table servis_item (
  id bigint generated always as identity primary key,
  servis_id bigint not null references servis(id) on delete cascade,
  komponen_id bigint not null references komponen_perawatan(id),
  nama text,
  qty numeric not null default 1 check (qty > 0),
  satuan text not null default 'Pcs',
  sumber text not null default 'langsung' check (sumber in ('stok','langsung')),
  barang_id bigint references barang(id),
  harga numeric not null default 0 check (harga >= 0)
);

-- HM terbaru sebuah unit: dari BBM, perbaikan, servis, atau HM awal unit
create or replace function hm_terakhir(p_unit bigint) returns numeric language sql stable as $$
  select greatest(
    coalesce((select hm_awal from unit where id = p_unit), 0),
    coalesce((select max(hm_akhir) from bbm_pakai where unit_id = p_unit and status = 'aktif'), 0),
    coalesce((select max(hm) from perbaikan where unit_id = p_unit and status = 'aktif'), 0),
    coalesce((select max(hm) from servis where unit_id = p_unit and status = 'aktif'), 0))
$$;

-- status perawatan per unit x komponen (interval paling khusus menang: unit > kategori > umum)
create or replace view v_status_perawatan as
with pasangan as (
  select u.id as unit_id, u.kode as unit_kode, u.kategori, k.id as komponen_id, k.nama as komponen,
         (select i.id from interval_perawatan i
           where i.komponen_id = k.id and i.aktif
             and ((i.cakupan = 'unit' and i.unit_id = u.id) or (i.cakupan = 'kategori' and i.kategori = u.kategori) or i.cakupan = 'umum')
           order by case i.cakupan when 'unit' then 1 when 'kategori' then 2 else 3 end limit 1) as interval_id
    from unit u cross join komponen_perawatan k
   where u.status <> 'nonaktif' and k.aktif
)
select p.unit_id, p.unit_kode, p.komponen_id, p.komponen, i.interval_hm, i.ambang_segera_hm,
       coalesce(l.hm_terakhir_ganti, un.hm_awal) as hm_terakhir_ganti,
       (l.hm_terakhir_ganti is not null) as pernah_diganti,
       hm_terakhir(p.unit_id) as hm_sekarang,
       coalesce(l.hm_terakhir_ganti, un.hm_awal) + i.interval_hm as hm_jadwal_berikut,
       coalesce(l.hm_terakhir_ganti, un.hm_awal) + i.interval_hm - hm_terakhir(p.unit_id) as sisa_hm,
       case when coalesce(l.hm_terakhir_ganti, un.hm_awal) + i.interval_hm - hm_terakhir(p.unit_id) <= 0 then 'terlambat'
            when coalesce(l.hm_terakhir_ganti, un.hm_awal) + i.interval_hm - hm_terakhir(p.unit_id) <= i.ambang_segera_hm then 'segera'
            else 'aman' end as status
  from pasangan p
  join interval_perawatan i on i.id = p.interval_id
  join unit un on un.id = p.unit_id
  left join lateral (
    select max(s.hm) as hm_terakhir_ganti from servis s join servis_item si on si.servis_id = s.id
     where s.unit_id = p.unit_id and s.status = 'aktif' and si.komponen_id = p.komponen_id) l on true;
-- ---------- 3. SDM: absensi, lembur, kasbon, penyesuaian gaji, payroll ----------
create table aturan_absensi (
  id bigint generated always as identity primary key,
  nama text not null,
  jabatan text,                         -- kosong = berlaku umum; diisi = khusus jabatan itu
  shift text check (shift in ('1','2')), -- kosong = semua shift
  jam_masuk time not null default '06:00',
  jam_pulang time not null default '18:00',
  toleransi_menit integer not null default 10 check (toleransi_menit >= 0),
  potongan_telat_jenis text not null default 'tidak' check (potongan_telat_jenis in ('tidak','tetap','per_menit','persen_harian')),
  potongan_telat_nilai numeric not null default 0 check (potongan_telat_nilai >= 0),
  potongan_alpa_jenis text not null default 'tidak' check (potongan_alpa_jenis in ('tidak','tetap','persen_harian')),
  potongan_alpa_nilai numeric not null default 0 check (potongan_alpa_nilai >= 0),
  lembur_aktif boolean not null default true,
  lembur_mulai_menit integer not null default 60 check (lembur_mulai_menit >= 0),
  lembur_jenis text not null default 'per_jam' check (lembur_jenis in ('per_jam','kelipatan')),
  lembur_nilai numeric not null default 0 check (lembur_nilai >= 0),
  hari_kerja_per_bulan integer not null default 26 check (hari_kerja_per_bulan > 0),
  berlaku_mulai date not null default current_date,
  aktif boolean not null default true
);

create or replace function aturan_untuk(p_jabatan text, p_shift text, p_tgl date) returns setof aturan_absensi language sql stable as $$
  select * from aturan_absensi a
   where a.aktif and a.berlaku_mulai <= p_tgl
     and (a.jabatan is null or lower(a.jabatan) = lower(coalesce(p_jabatan, '')))
     and (a.shift is null or a.shift = p_shift)
   order by (a.jabatan is not null) desc, (a.shift is not null) desc, a.berlaku_mulai desc, a.id desc
   limit 1
$$;

create or replace function jarak_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric) returns numeric language sql immutable as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null
         else round((2 * 6371000 * asin(sqrt(
                power(sin(radians((lat2 - lat1)::double precision) / 2), 2) +
                cos(radians(lat1::double precision)) * cos(radians(lat2::double precision)) *
                power(sin(radians((lng2 - lng1)::double precision) / 2), 2))))::numeric, 1) end
$$;

create table absensi (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  karyawan_id bigint not null references karyawan(id),
  tanggal date not null,
  shift text check (shift in ('1','2')),
  status text not null default 'hadir' check (status in ('hadir','izin','sakit','alpa','cuti','libur')),
  masuk_waktu timestamptz,
  pulang_waktu timestamptz,
  masuk_lat numeric, masuk_lng numeric, pulang_lat numeric, pulang_lng numeric,
  site_id bigint references site(id),
  jarak_masuk_m numeric,
  di_luar_radius boolean not null default false,
  sumber text not null default 'mandiri' check (sumber in ('mandiri','admin')),
  dicatat_oleh uuid default auth.uid(),
  alasan_koreksi text,
  telat_menit integer not null default 0,
  jam_kerja numeric,
  keterangan text,
  dibuat timestamptz not null default now(),
  unique (karyawan_id, tanggal)
);
create index ix_absensi_tgl on absensi (tanggal);

create or replace function trg_absensi() returns trigger language plpgsql as $$
declare jab text; a aturan_absensi; s record; tmasuk timestamptz;
begin
  new.telat_menit := 0;
  select jabatan into jab from karyawan where id = new.karyawan_id;
  if new.status = 'hadir' and new.masuk_waktu is not null then
    select * into a from aturan_untuk(jab, new.shift, new.tanggal);
    if found then
      tmasuk := (new.tanggal + a.jam_masuk) at time zone 'Asia/Jakarta';
      if new.masuk_waktu > tmasuk + make_interval(mins => a.toleransi_menit) then
        new.telat_menit := floor(extract(epoch from (new.masuk_waktu - tmasuk)) / 60)::integer;
      end if;
    end if;
    if new.site_id is null then select site_id into new.site_id from karyawan where id = new.karyawan_id; end if;
    select lat, lng, radius_m into s from site where id = new.site_id;
    if found and s.lat is not null and new.masuk_lat is not null then
      new.jarak_masuk_m := jarak_m(new.masuk_lat, new.masuk_lng, s.lat, s.lng);
      new.di_luar_radius := new.jarak_masuk_m > s.radius_m;
    end if;
  end if;
  if new.masuk_waktu is not null and new.pulang_waktu is not null then
    if new.pulang_waktu < new.masuk_waktu then raise exception 'Waktu pulang tidak boleh sebelum waktu masuk.'; end if;
    new.jam_kerja := round(extract(epoch from (new.pulang_waktu - new.masuk_waktu)) / 3600, 2);
  end if;
  if new.sumber = 'admin' and coalesce(new.alasan_koreksi, '') = '' then
    raise exception 'Alasan wajib diisi untuk absensi yang dicatat atau dikoreksi Admin/Supervisor.';
  end if;
  return new;
end $$;
create trigger trg_absensi_hitung before insert or update on absensi for each row execute function trg_absensi();

create table lembur (
  id bigint generated always as identity primary key,
  absensi_id bigint unique not null references absensi(id) on delete cascade,
  karyawan_id bigint not null references karyawan(id),
  tanggal date not null,
  jam numeric not null check (jam > 0),
  nominal numeric not null default 0,
  status text not null default 'usulan' check (status in ('usulan','disetujui','ditolak')),
  disetujui_oleh uuid,
  waktu_setuju timestamptz,
  alasan text
);

-- usulan lembur otomatis bila jam kerja melebihi jam standar shift + batas minimum menit
create or replace function trg_absensi_lembur() returns trigger language plpgsql as $$
declare jab text; a aturan_absensi; standar numeric; lebih numeric;
begin
  if new.status = 'hadir' and new.jam_kerja is not null then
    select jabatan into jab from karyawan where id = new.karyawan_id;
    select * into a from aturan_untuk(jab, new.shift, new.tanggal);
    if found and a.lembur_aktif then
      standar := extract(epoch from (a.jam_pulang - a.jam_masuk)) / 3600;
      if standar <= 0 then standar := standar + 24; end if;
      lebih := new.jam_kerja - standar;
      if lebih * 60 >= a.lembur_mulai_menit then
        insert into lembur(absensi_id, karyawan_id, tanggal, jam) values (new.id, new.karyawan_id, new.tanggal, round(lebih, 2))
        on conflict (absensi_id) do update set jam = excluded.jam where lembur.status = 'usulan';
      else
        delete from lembur where absensi_id = new.id and status = 'usulan';
      end if;
    end if;
  end if;
  return null;
end $$;
create trigger trg_absensi_lembur_aksi after insert or update on absensi for each row execute function trg_absensi_lembur();

create table kasbon (
  id bigint generated always as identity primary key,
  tanggal date not null,
  karyawan_id bigint not null references karyawan(id),
  jenis text not null check (jenis in ('pinjam','potong')),
  nominal numeric not null check (nominal > 0),
  keterangan text,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);

create table penyesuaian_gaji (
  id bigint generated always as identity primary key,
  tanggal date not null,
  karyawan_id bigint not null references karyawan(id),
  jenis text not null check (jenis in ('pendapatan','potongan')),
  kategori text not null check (kategori in ('bonus','insentif','tunjangan_lain','lembur','kasbon','denda','klaim','telat','alpa','lainnya')),
  keterangan text,
  nominal numeric not null check (nominal > 0),
  sumber text not null default 'manual' check (sumber in ('manual','absensi','lembur')),
  ref_id bigint,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create index ix_penyesuaian_kar on penyesuaian_gaji (karyawan_id, tanggal);

create table payroll (
  id bigint generated always as identity primary key,
  karyawan_id bigint not null references karyawan(id),
  bulan date not null,
  periode_mulai date not null,
  periode_akhir date not null,
  gaji_pokok numeric not null default 0,
  premi_ritase numeric not null default 0,
  premi_tonase numeric not null default 0,
  hari_hadir integer not null default 0,
  tarif_makan numeric not null default 0,
  uang_makan numeric not null default 0,
  pendapatan_kotor numeric not null default 0,
  pendapatan_tidak_tetap numeric not null default 0,
  potongan_kasbon numeric not null default 0,
  potongan_tidak_tetap numeric not null default 0,
  thp numeric not null default 0,
  status_bayar text not null default 'belum' check (status_bayar in ('belum','menunggu','sudah')),
  tanggal_bayar date,
  kas_id bigint,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dihitung timestamptz not null default now(),
  unique (karyawan_id, periode_mulai, periode_akhir)
);
create trigger trg_payroll_kunci before insert or update or delete on payroll for each row execute function cek_kunci_trg('periode_akhir');
create trigger trg_penyesuaian_kunci before insert or update or delete on penyesuaian_gaji for each row execute function cek_kunci_trg('tanggal');

-- saldo pinjaman per karyawan
create or replace view v_saldo_kasbon as
select k.id as karyawan_id, k.nama,
       coalesce(sum(case when b.jenis = 'pinjam' then b.nominal else -b.nominal end), 0) as saldo
  from karyawan k left join kasbon b on b.karyawan_id = k.id and b.status = 'aktif'
 group by k.id, k.nama;
-- ---------- 4. KEUANGAN: kas, akun, jurnal manual, aset, faktur, tagihan, persetujuan, lampiran ----------
create table akun (
  kode text primary key,
  nama text not null,
  kelompok text not null check (kelompok in ('Aset','Liabilitas','Ekuitas','Pendapatan','Beban')),
  sub_kelompok text,
  saldo_normal text not null check (saldo_normal in ('debit','kredit')),
  aktif boolean not null default true
);

create table pemetaan_akun (
  kunci text primary key,
  keterangan text,
  akun_debit text references akun(kode),
  akun_kredit text references akun(kode),
  aktif boolean not null default true
);

create table kategori_kas (
  id bigint generated always as identity primary key,
  arah text not null check (arah in ('masuk','keluar')),
  nama text not null,
  aktivitas text not null default 'Operasional' check (aktivitas in ('Operasional','Investasi','Non-Operasional','Pribadi')),
  aktif boolean not null default true,
  unique (arah, nama)
);

create table buku_kas (
  id bigint generated always as identity primary key,
  klien_id uuid unique,
  tanggal date not null,
  arah text not null check (arah in ('masuk','keluar')),
  sub_kategori text not null,
  aktivitas text check (aktivitas in ('Operasional','Investasi','Non-Operasional','Pribadi')),
  rekening text not null default 'kas' check (rekening in ('kas','bank')),
  uraian text not null,
  referensi text,
  ref_tabel text,
  ref_id bigint,
  jumlah numeric not null check (jumlah > 0),
  penanggung_jawab text,
  status text not null default 'aktif' check (status in ('aktif','menunggu','ditolak','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create index ix_kas_ref on buku_kas (ref_tabel, ref_id);
create index ix_kas_tgl on buku_kas (tanggal);

create or replace function trg_kas() returns trigger language plpgsql as $$
begin
  if new.aktivitas is null then
    select aktivitas into new.aktivitas from kategori_kas where arah = new.arah and lower(nama) = lower(new.sub_kategori) limit 1;
    new.aktivitas := coalesce(new.aktivitas, 'Operasional');
  end if;
  return new;
end $$;
create trigger trg_kas_isi before insert on buku_kas for each row execute function trg_kas();
create trigger trg_kas_kunci before insert or update or delete on buku_kas for each row execute function cek_kunci_trg('tanggal');

create table jurnal (
  id bigint generated always as identity primary key,
  nomor text unique,
  tanggal date not null,
  uraian text not null,
  status text not null default 'aktif' check (status in ('aktif','menunggu','ditolak','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create table jurnal_baris (
  id bigint generated always as identity primary key,
  jurnal_id bigint not null references jurnal(id) on delete cascade,
  kode_akun text not null references akun(kode),
  debit numeric not null default 0 check (debit >= 0),
  kredit numeric not null default 0 check (kredit >= 0),
  uraian text,
  check (debit > 0 or kredit > 0)
);
create trigger trg_jurnal_kunci before insert or update or delete on jurnal for each row execute function cek_kunci_trg('tanggal');

create table aset (
  id bigint generated always as identity primary key,
  kode text unique not null,
  nama text not null,
  kategori text not null default 'Kendaraan',
  unit_id bigint references unit(id),
  tgl_perolehan date not null,
  mulai_susut date not null,
  harga numeric not null check (harga > 0),
  nilai_residu numeric not null default 0 check (nilai_residu >= 0),
  umur_bulan integer not null check (umur_bulan > 0),
  metode text not null default 'garis_lurus' check (metode in ('garis_lurus','saldo_menurun','unit_produksi')),
  basis_unit text check (basis_unit in ('tonase','ritase')),
  total_unit numeric,
  status text not null default 'aktif' check (status in ('aktif','dijual','dihapus'))
);

-- penyusutan per aset per bulan (dihitung, tidak disimpan)
create or replace view v_penyusutan as
select b.aset_id, b.awal_bulan, (b.awal_bulan + interval '1 month' - interval '1 day')::date as akhir_bulan, b.ke + 1 as bulan_ke, b.kode, b.nama,
       case b.metode
         when 'garis_lurus' then round((b.harga - b.nilai_residu) / b.umur_bulan, 2)
         when 'saldo_menurun' then round(greatest(0, least(
              b.harga * power(1 - 2.0 / b.umur_bulan, b.ke) * (2.0 / b.umur_bulan),
              b.harga * power(1 - 2.0 / b.umur_bulan, b.ke) - b.nilai_residu)), 2)
         else round(case when coalesce(b.total_unit, 0) > 0 then (b.harga - b.nilai_residu) * b.pemakaian / b.total_unit else 0 end, 2)
       end as beban
  from (
    select a.id as aset_id, a.kode, a.nama, a.harga, a.nilai_residu, a.umur_bulan, a.metode, a.total_unit, g.k as ke,
           (date_trunc('month', a.mulai_susut)::date + make_interval(months => g.k))::date as awal_bulan,
           coalesce((select case a.basis_unit when 'tonase' then sum(p.tonase) when 'ritase' then sum(p.ritase)::numeric else 0 end
                       from produksi p
                      where a.metode = 'unit_produksi' and p.unit_id = a.unit_id and p.status = 'aktif'
                        and p.tanggal_timbangan >= (date_trunc('month', a.mulai_susut)::date + make_interval(months => g.k))::date
                        and p.tanggal_timbangan < (date_trunc('month', a.mulai_susut)::date + make_interval(months => g.k + 1))::date), 0) as pemakaian
      from aset a
     cross join lateral generate_series(0, a.umur_bulan - 1) as g(k)
     where a.status <> 'dihapus'
  ) b
 where b.awal_bulan <= date_trunc('month', hari_ini())::date;

create table faktur (
  id bigint generated always as identity primary key,
  nomor text unique not null,
  tanggal date not null,
  pelanggan_id bigint not null references pelanggan(id),
  periode_dari date,
  periode_sampai date,
  termin_hari integer not null default 0,
  jatuh_tempo date not null,
  dpp numeric not null default 0,
  ppn_persen numeric not null default 0 check (ppn_persen >= 0 and ppn_persen <= 100),
  ppn numeric not null default 0,
  pph_persen numeric not null default 0 check (pph_persen >= 0 and pph_persen <= 100),
  pph numeric not null default 0,
  total_kotor numeric not null default 0,
  kontra_bon_total numeric not null default 0,
  netto numeric generated always as (total_kotor - kontra_bon_total) stored,
  status text not null default 'draft' check (status in ('draft','disetujui','batal')),
  tanggal_disetujui date,
  keterangan text,
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create table faktur_baris (
  id bigint generated always as identity primary key,
  faktur_id bigint not null references faktur(id) on delete cascade,
  deskripsi text not null,
  kategori text not null default 'hauling' check (kategori in ('hauling','sewa','borongan','lain')),
  kuantitas numeric not null default 1,
  satuan text,
  tarif numeric not null default 0,
  jumlah numeric not null default 0,
  akun_pendapatan text references akun(kode),
  dari_produksi boolean not null default false
);
alter table produksi add constraint fk_produksi_faktur foreign key (faktur_id) references faktur(id);
create trigger trg_faktur_kunci before insert or update on faktur for each row execute function cek_kunci_trg('tanggal');

create table tagihan_pemasok (
  id bigint generated always as identity primary key,
  nomor text unique not null,
  tanggal date not null,
  pemasok_id bigint not null references pemasok(id),
  uraian text,
  jumlah numeric not null check (jumlah > 0),
  termin_hari integer not null default 0,
  jatuh_tempo date not null,
  jurnalkan boolean not null default false,
  akun_beban text references akun(kode),
  dari_kontra_bon boolean not null default false,
  status text not null default 'aktif' check (status in ('aktif','batal')),
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create table kontra_bon (
  id bigint generated always as identity primary key,
  faktur_id bigint not null references faktur(id) on delete cascade,
  pemasok_id bigint not null references pemasok(id),
  tagihan_id bigint references tagihan_pemasok(id),
  nominal numeric not null check (nominal > 0),
  keterangan text,
  status text not null default 'draft' check (status in ('draft','berlaku','batal')),
  tanggal_berlaku date
);

create or replace view v_faktur_saldo as
select f.id, f.nomor, f.tanggal, f.pelanggan_id, p.nama as pelanggan, f.jatuh_tempo, f.dpp, f.ppn, f.pph, f.total_kotor,
       f.kontra_bon_total, f.netto, f.status, b.dibayar as dibayar_kas,
       case when f.status = 'disetujui' then f.kontra_bon_total else 0 end as kontra_berlaku,
       case when f.status = 'batal' then 0
            else f.total_kotor - b.dibayar - case when f.status = 'disetujui' then f.kontra_bon_total else 0 end end as sisa,
       case when f.status = 'disetujui' and f.jatuh_tempo < hari_ini()
                 and (f.total_kotor - b.dibayar - f.kontra_bon_total) > 0.005 then hari_ini() - f.jatuh_tempo else 0 end as hari_telat
  from faktur f
  join pelanggan p on p.id = f.pelanggan_id
 cross join lateral (select coalesce(sum(k.jumlah), 0) as dibayar from buku_kas k
                      where k.ref_tabel = 'faktur' and k.ref_id = f.id and k.arah = 'masuk' and k.status = 'aktif') b;

create or replace view v_tagihan_saldo as
select t.id, t.nomor, t.tanggal, t.pemasok_id, p.nama as pemasok, t.uraian, t.jumlah, t.jatuh_tempo, t.status,
       b.dibayar as dibayar_kas, c.kontra as dibayar_kontra,
       case when t.status = 'batal' then 0 else t.jumlah - b.dibayar - c.kontra end as sisa,
       case when t.status = 'aktif' and t.jatuh_tempo < hari_ini() and (t.jumlah - b.dibayar - c.kontra) > 0.005
            then hari_hari else 0 end as hari_telat
  from (select t0.*, (hari_ini() - t0.jatuh_tempo) as hari_hari from tagihan_pemasok t0) t
  join pemasok p on p.id = t.pemasok_id
 cross join lateral (select coalesce(sum(k.jumlah), 0) as dibayar from buku_kas k
                      where k.ref_tabel = 'tagihan_pemasok' and k.ref_id = t.id and k.arah = 'keluar' and k.status = 'aktif') b
 cross join lateral (select coalesce(sum(kb.nominal), 0) as kontra from kontra_bon kb
                      join faktur f on f.id = kb.faktur_id
                      where kb.tagihan_id = t.id and kb.status = 'berlaku' and f.status = 'disetujui') c;

-- persetujuan bertingkat
create table aturan_persetujuan (
  jenis text primary key check (jenis in ('pembelian','kas_keluar','jurnal_manual','pembayaran_payroll')),
  aktif boolean not null default true,
  batas_nominal numeric not null default 0 check (batas_nominal >= 0),
  penyetuju text not null default 'admin' check (penyetuju in ('admin','admin_keuangan')),
  keterangan text
);
create table persetujuan (
  id bigint generated always as identity primary key,
  jenis text not null,
  tabel text not null,
  baris_id bigint not null,
  nominal numeric not null default 0,
  uraian text,
  diajukan_oleh uuid default auth.uid(),
  diajukan timestamptz not null default now(),
  status text not null default 'menunggu' check (status in ('menunggu','disetujui','ditolak')),
  diproses_oleh uuid,
  diproses timestamptz,
  alasan text
);

-- foto dan lampiran (opsional)
create table lampiran (
  id bigint generated always as identity primary key,
  tabel text not null,
  baris_id bigint,
  klien_id uuid,
  jenis text,
  path text not null,
  ukuran integer,
  dibuat_oleh uuid default auth.uid(),
  dibuat timestamptz not null default now()
);
create index ix_lampiran_ref on lampiran (tabel, baris_id);

create table antrian_sinkron (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid(),
  waktu timestamptz not null default now(),
  rpc text,
  payload jsonb,
  galat text,
  status text not null default 'gagal' check (status in ('gagal','selesai'))
);
-- ---------- 5. BUKU BESAR: jurnal otomatis dihitung dari data sumber (view), ditambah jurnal manual ----------
create or replace function mulai_pembukuan() returns date language sql stable as $$
  select nullif(nilai, '')::date from pengaturan where kunci = 'mulai_pembukuan'
$$;

create or replace view v_pasangan as
-- produksi: pendapatan hauling diakui pada tanggal timbangan
select coalesce(p.tanggal_timbangan, p.tanggal) as tanggal, 'produksi'::text as sumber, p.id as ref_id,
       ('Pendapatan hauling SPB ' || coalesce(p.no_spb, '#' || p.id))::text as uraian,
       pm.akun_debit, pm.akun_kredit, p.nominal as jumlah, null::text as rekening
  from produksi p join pemetaan_akun pm on pm.kunci = 'PRODUKSI' and pm.aktif
 where p.status = 'aktif' and p.nominal > 0
union all
select b.tanggal, 'bbm_masuk', b.id, ('Pembelian BBM ' || coalesce(b.no_po, '')), pm.akun_debit, pm.akun_kredit, b.nilai, null
  from bbm_masuk b join pemetaan_akun pm on pm.kunci = 'BBM_MASUK' and pm.aktif
 where b.status = 'aktif'
union all
select b.tanggal, 'bbm_pakai', b.id, ('Pemakaian BBM ' || b.alokasi), pm.akun_debit, pm.akun_kredit, b.nilai, null
  from bbm_pakai b
  join pemetaan_akun pm on pm.aktif and pm.kunci = case b.alokasi when 'unit' then 'BBM_PAKAI' when 'lapangan' then 'BBM_PAKAI|Lapangan' when 'umum' then 'BBM_PAKAI|Umum' else 'BBM_PAKAI|Lain' end
 where b.status = 'aktif' and b.nilai > 0
union all
select p.tanggal, 'perbaikan', i.id, ('Perbaikan unit ' || i.nama), pm.akun_debit, pm.akun_kredit, i.subtotal, null
  from perbaikan_item i join perbaikan p on p.id = i.perbaikan_id
  join pemetaan_akun pm on pm.aktif and pm.kunci = case i.sumber when 'stok' then 'PERBAIKAN|Stok' else 'PERBAIKAN' end
 where p.status = 'aktif' and i.subtotal > 0
union all
select b.tanggal, 'barang_masuk', b.id, ('Penerimaan barang ' || coalesce(b.no_ref, '')), pm.akun_debit, pm.akun_kredit, b.nilai, null
  from barang_masuk b join pemetaan_akun pm on pm.kunci = 'STOK_MASUK' and pm.aktif
 where b.status = 'aktif'
union all
select k.tanggal, 'barang_keluar', k.id, ('Pengeluaran barang ' || k.alokasi), pm.akun_debit, pm.akun_kredit, k.nilai, null
  from barang_keluar k
  join pemetaan_akun pm on pm.aktif and pm.kunci = case k.alokasi when 'lapangan' then 'STOK_KELUAR|Lapangan' when 'umum' then 'STOK_KELUAR|Umum' else 'STOK_KELUAR|Lain' end
 where k.status = 'aktif' and k.alokasi <> 'unit' and k.nilai > 0
union all
select l.tanggal, 'pembelian_langsung', l.id, ('Beban langsung ' || l.uraian), pm.akun_debit, pm.akun_kredit, l.nominal, null
  from pembelian_langsung l
  join pemetaan_akun pm on pm.aktif and pm.kunci = case l.alokasi when 'lapangan' then 'BEBAN_LANGSUNG|Lapangan' when 'umum' then 'BEBAN_LANGSUNG|Umum' else 'BEBAN_LANGSUNG|Lain' end
 where l.status = 'aktif' and l.alokasi <> 'unit'
union all
-- payroll: dibukukan pada akhir periode
select pr.periode_akhir, 'payroll', pr.id, (x.uraian || ' ' || k.nama), pm.akun_debit, pm.akun_kredit, x.jumlah, null
  from payroll pr
  join karyawan k on k.id = pr.karyawan_id
 cross join lateral (values
        ('PAYROLL_GAJI', 'Gaji pokok', pr.gaji_pokok),
        ('PAYROLL_PREMI', 'Premi driver', pr.premi_ritase + pr.premi_tonase),
        ('PAYROLL_MAKAN', 'Uang makan', pr.uang_makan),
        ('PAYROLL_BONUS', 'Pendapatan tidak tetap', pr.pendapatan_tidak_tetap),
        ('PAYROLL_KASBON', 'Potongan kasbon', pr.potongan_kasbon),
        ('PAYROLL_POTONGAN', 'Potongan denda/klaim/lain', pr.potongan_tidak_tetap - pr.potongan_kasbon)) as x(kunci, uraian, jumlah)
  join pemetaan_akun pm on pm.kunci = x.kunci and pm.aktif
 where pr.status = 'aktif' and x.jumlah > 0
union all
-- buku kas: pemetaan menurut sub kategori, cadangan KAS_MASUK|* atau KAS_KELUAR|*
select k.tanggal, 'buku_kas', k.id, ('Kas ' || k.arah || ' ' || k.sub_kategori || ': ' || k.uraian),
       coalesce(ps.akun_debit, pf.akun_debit), coalesce(ps.akun_kredit, pf.akun_kredit), k.jumlah, k.rekening
  from buku_kas k
  left join pemetaan_akun ps on ps.aktif and ps.kunci = (case k.arah when 'masuk' then 'KAS_MASUK|' else 'KAS_KELUAR|' end) || k.sub_kategori
  left join pemetaan_akun pf on pf.aktif and pf.kunci = case k.arah when 'masuk' then 'KAS_MASUK|*' else 'KAS_KELUAR|*' end
 where k.status = 'aktif' and coalesce(ps.akun_debit, pf.akun_debit) is not null and coalesce(ps.akun_kredit, pf.akun_kredit) is not null
union all
-- faktur disetujui: PPN, PPh, kontra bon
select f.tanggal_disetujui, 'faktur', f.id, (x.uraian || ' ' || f.nomor), pm.akun_debit, pm.akun_kredit, x.jumlah, null
  from faktur f
 cross join lateral (values ('FAKTUR_PPN', 'PPN keluaran', f.ppn), ('FAKTUR_PPH', 'PPh dipotong pelanggan', f.pph), ('FAKTUR_KONTRA', 'Kontra bon', f.kontra_bon_total)) as x(kunci, uraian, jumlah)
  join pemetaan_akun pm on pm.kunci = x.kunci and pm.aktif
 where f.status = 'disetujui' and x.jumlah > 0
union all
-- faktur disetujui: baris manual (sewa, borongan, lain) diakui sebagai pendapatan
select f.tanggal_disetujui, 'faktur_baris', fb.id, ('Pendapatan ' || fb.deskripsi || ' ' || f.nomor), pm.akun_debit, coalesce(fb.akun_pendapatan, pm.akun_kredit), fb.jumlah, null
  from faktur_baris fb join faktur f on f.id = fb.faktur_id
  join pemetaan_akun pm on pm.kunci = 'FAKTUR_MANUAL' and pm.aktif
 where f.status = 'disetujui' and not fb.dari_produksi and fb.jumlah > 0
union all
select t.tanggal, 'tagihan', t.id, ('Tagihan pemasok ' || t.nomor), coalesce(t.akun_beban, pm.akun_debit), pm.akun_kredit, t.jumlah, null
  from tagihan_pemasok t join pemetaan_akun pm on pm.kunci = 'TAGIHAN' and pm.aktif
 where t.jurnalkan and t.status = 'aktif'
union all
select v.akhir_bulan, 'penyusutan', v.aset_id, ('Penyusutan ' || v.nama || ' bulan ke-' || v.bulan_ke), pm.akun_debit, pm.akun_kredit, v.beban, null
  from v_penyusutan v join pemetaan_akun pm on pm.kunci = 'PENYUSUTAN' and pm.aktif
 where v.beban > 0;

create or replace view v_jurnal as
select x.tanggal, x.sumber, x.ref_id, x.uraian,
       case when x.rekening = 'bank' and x.akun_debit = '1-1100' then '1-1200' else x.akun_debit end as kode_akun,
       x.jumlah as debit, 0::numeric as kredit
  from v_pasangan x
 where x.akun_debit is not null and x.akun_kredit is not null and x.tanggal >= coalesce(mulai_pembukuan(), date '1900-01-01')
union all
select x.tanggal, x.sumber, x.ref_id, x.uraian,
       case when x.rekening = 'bank' and x.akun_kredit = '1-1100' then '1-1200' else x.akun_kredit end,
       0::numeric, x.jumlah
  from v_pasangan x
 where x.akun_debit is not null and x.akun_kredit is not null and x.tanggal >= coalesce(mulai_pembukuan(), date '1900-01-01')
union all
select j.tanggal, 'jurnal_manual', j.id, coalesce(b.uraian, j.uraian), b.kode_akun, b.debit, b.kredit
  from jurnal j join jurnal_baris b on b.jurnal_id = j.id
 where j.status = 'aktif';

-- saldo per akun sampai tanggal tertentu
create or replace function saldo_akun(p_tgl date) returns table (kode text, nama text, kelompok text, sub_kelompok text, saldo_normal text, debit numeric, kredit numeric, saldo numeric)
language sql stable as $$
  select a.kode, a.nama, a.kelompok, a.sub_kelompok, a.saldo_normal,
         coalesce(sum(j.debit), 0), coalesce(sum(j.kredit), 0),
         case when a.saldo_normal = 'debit' then coalesce(sum(j.debit - j.kredit), 0) else coalesce(sum(j.kredit - j.debit), 0) end
    from akun a left join v_jurnal j on j.kode_akun = a.kode and j.tanggal <= p_tgl
   group by a.kode, a.nama, a.kelompok, a.sub_kelompok, a.saldo_normal
$$;
-- ---------- 6. RPC TRANSAKSI (semua perhitungan dan validasi di database) ----------
-- pembaca nilai json yang rapi
create or replace function jt(p jsonb, k text) returns text language sql immutable as $$ select nullif(btrim(p->>k), '') $$;
create or replace function jn(p jsonb, k text) returns numeric language sql immutable as $$ select nullif(btrim(p->>k), '')::numeric $$;
create or replace function jb(p jsonb, k text) returns bigint language sql immutable as $$ select nullif(btrim(p->>k), '')::bigint $$;
create or replace function jd(p jsonb, k text) returns date language sql immutable as $$ select nullif(btrim(p->>k), '')::date $$;
create or replace function ju(p jsonb, k text) returns uuid language sql immutable as $$ select nullif(btrim(p->>k), '')::uuid $$;

-- persetujuan bertingkat: berlaku untuk transaksi yang diinput non-Admin
create or replace function perlu_setuju(p_jenis text, p_nominal numeric) returns boolean language sql stable security definer set search_path = public as $$
  select not adalah(array['admin']) and exists (select 1 from aturan_persetujuan a where a.jenis = p_jenis and a.aktif and p_nominal >= a.batas_nominal)
$$;

create or replace function ajukan_persetujuan(p_jenis text, p_tabel text, p_id bigint, p_nominal numeric, p_uraian text) returns void language sql security definer set search_path = public as $$
  insert into persetujuan(jenis, tabel, baris_id, nominal, uraian) values (p_jenis, p_tabel, p_id, p_nominal, p_uraian)
$$;

create or replace function catat_kas(p_tgl date, p_arah text, p_sub text, p_uraian text, p_ref text, p_ref_tabel text, p_ref_id bigint,
                                     p_jumlah numeric, p_rek text, p_status text, p_pj text) returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into buku_kas(tanggal, arah, sub_kategori, uraian, referensi, ref_tabel, ref_id, jumlah, rekening, status, penanggung_jawab)
  values (p_tgl, p_arah, p_sub, p_uraian, p_ref, p_ref_tabel, p_ref_id, p_jumlah, coalesce(p_rek, 'kas'), coalesce(p_status, 'aktif'), p_pj)
  returning id into v;
  return v;
end $$;

create or replace function jenis_item_barang(p_kategori text) returns text language sql immutable as $$
  select case p_kategori when 'Ban' then 'ban' when 'Oli' then 'perawatan_rutin' when 'Filter' then 'perawatan_rutin' else 'suku_cadang' end
$$;

-- ---------- produksi ----------
create or replace function simpan_produksi(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v produksi; hadir text; ada bigint; pesan text := '';
begin
  perform wajib_peran(array['admin','keuangan','supervisor','operator']);
  if ju(p, 'klien_id') is not null then
    select id into ada from produksi where klien_id = ju(p, 'klien_id');
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  insert into produksi(klien_id, tanggal, shift, tanggal_timbangan, shift_timbangan, unit_id, karyawan_id, site_id, loading, dumping, no_spb,
                       ritase, tonase, tonase_terima, volume_m3, jam_masuk_loading, jam_keluar_loading, jam_masuk_dumping, jam_keluar_dumping, keterangan)
  values (ju(p, 'klien_id'), jd(p, 'tanggal'), jt(p, 'shift'), jd(p, 'tanggal_timbangan'), jt(p, 'shift_timbangan'), jb(p, 'unit_id'), jb(p, 'karyawan_id'), jb(p, 'site_id'),
          jt(p, 'loading'), jt(p, 'dumping'), jt(p, 'no_spb'), coalesce(jn(p, 'ritase'), 1)::integer, jn(p, 'tonase'), jn(p, 'tonase_terima'), jn(p, 'volume_m3'),
          nullif(p->>'jam_masuk_loading', '')::time, nullif(p->>'jam_keluar_loading', '')::time, nullif(p->>'jam_masuk_dumping', '')::time, nullif(p->>'jam_keluar_dumping', '')::time, jt(p, 'keterangan'))
  returning * into v;
  select status into hadir from absensi where karyawan_id = v.karyawan_id and tanggal = v.tanggal;
  if hadir is not null and hadir <> 'hadir' then pesan := 'PERHATIAN: driver tercatat ' || hadir || ' pada tanggal ini.'; end if;
  if v.perlu_cek then pesan := trim(pesan || ' Tarif rute belum ada untuk tanggal timbangan ini; nominal belum terhitung.'); end if;
  return jsonb_build_object('id', v.id, 'nominal', v.nominal, 'premi', v.premi, 'jarak_km', v.jarak_km, 'tarif', v.tarif, 'perlu_cek', v.perlu_cek, 'pesan', pesan);
end $$;

-- ---------- BBM pakai ----------
create or replace function simpan_bbm_pakai(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v bbm_pakai; ada bigint;
begin
  perform wajib_peran(array['admin','keuangan','supervisor','operator']);
  if ju(p, 'klien_id') is not null then
    select id into ada from bbm_pakai where klien_id = ju(p, 'klien_id');
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  insert into bbm_pakai(klien_id, tanggal, shift, unit_id, karyawan_id, alokasi, ket_alokasi, hm_awal, hm_akhir, liter, lokasi)
  values (ju(p, 'klien_id'), jd(p, 'tanggal'), jt(p, 'shift'), jb(p, 'unit_id'), jb(p, 'karyawan_id'), coalesce(jt(p, 'alokasi'), 'unit'), jt(p, 'ket_alokasi'),
          jn(p, 'hm_awal'), jn(p, 'hm_akhir'), jn(p, 'liter'), jt(p, 'lokasi'))
  returning * into v;
  return jsonb_build_object('id', v.id, 'nilai', v.nilai, 'harga_fifo', v.harga_fifo, 'hm_awal', v.hm_awal);
end $$;

-- ---------- pengeluaran barang dan perbaikan ----------
create or replace function buat_barang_keluar(p_tgl date, p_shift text, p_barang bigint, p_qty numeric, p_alokasi text, p_unit bigint,
                                              p_penerima bigint, p_ket text, p_klien uuid, p_perbaikan bigint) returns barang_keluar language plpgsql security definer set search_path = public as $$
declare r barang_keluar;
begin
  insert into barang_keluar(tanggal, shift, barang_id, qty, alokasi, unit_id, penerima_id, keterangan, klien_id, perbaikan_id)
  values (p_tgl, p_shift, p_barang, p_qty, p_alokasi, p_unit, p_penerima, p_ket, p_klien, p_perbaikan)
  returning * into r;
  return r;
end $$;

create or replace function buat_perbaikan(h jsonb, items jsonb, p_asal text) returns bigint language plpgsql security definer set search_path = public as $$
declare pid bigint; it jsonb; bk barang_keluar; b barang; tgl date := jd(h, 'tanggal'); v_unit bigint := jb(h, 'unit_id');
begin
  if v_unit is null then raise exception 'No unit wajib diisi.'; end if;
  if items is null or jsonb_array_length(items) = 0 then raise exception 'Isi minimal satu item.'; end if;
  insert into perbaikan(klien_id, tanggal, shift, unit_id, pelapor_id, mekanik_id, kategori, hm, deskripsi, asal)
  values (ju(h, 'klien_id'), tgl, jt(h, 'shift'), v_unit, jb(h, 'pelapor_id'), jb(h, 'mekanik_id'), jt(h, 'kategori'), jn(h, 'hm'), jt(h, 'deskripsi'), p_asal)
  returning id into pid;
  for it in select * from jsonb_array_elements(items) loop
    if coalesce(jt(it, 'sumber'), 'langsung') = 'stok' then
      select * into b from barang where id = jb(it, 'barang_id');
      if not found then raise exception 'Barang untuk item stok tidak ditemukan.'; end if;
      bk := buat_barang_keluar(tgl, jt(h, 'shift'), b.id, jn(it, 'qty'), 'unit', v_unit, jb(h, 'pelapor_id'), jt(h, 'deskripsi'), null, pid);
      insert into perbaikan_item(perbaikan_id, jenis_item, nama, qty, satuan, harga, sumber, barang_id, barang_keluar_id, komponen_id)
      values (pid, coalesce(jt(it, 'jenis_item'), jenis_item_barang(b.kategori)), coalesce(jt(it, 'nama'), b.nama), bk.qty, b.satuan, bk.nilai / bk.qty, 'stok', b.id, bk.id, jb(it, 'komponen_id'));
    else
      if jt(it, 'nama') is null then raise exception 'Nama item wajib diisi.'; end if;
      insert into perbaikan_item(perbaikan_id, jenis_item, nama, qty, satuan, harga, sumber, komponen_id)
      values (pid, coalesce(jt(it, 'jenis_item'), 'suku_cadang'), jt(it, 'nama'), jn(it, 'qty'), coalesce(jt(it, 'satuan'), 'Pcs'), coalesce(jn(it, 'harga'), 0), 'langsung', jb(it, 'komponen_id'));
    end if;
  end loop;
  update perbaikan set total = (select coalesce(sum(subtotal), 0) from perbaikan_item where perbaikan_id = pid) where id = pid;
  return pid;
end $$;

create or replace function simpan_perbaikan(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ada bigint; pid bigint; tot numeric;
begin
  perform wajib_peran(array['admin','keuangan','supervisor','operator']);
  if ju(p, 'klien_id') is not null then
    select id into ada from perbaikan where klien_id = ju(p, 'klien_id');
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  pid := buat_perbaikan(p, p->'items', 'perbaikan');
  select total into tot from perbaikan where id = pid;
  return jsonb_build_object('id', pid, 'total', tot);
end $$;

create or replace function simpan_pengeluaran(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ada bigint; b barang; al text := coalesce(jt(p, 'alokasi'), 'unit'); pid bigint; bk barang_keluar; tot numeric;
begin
  perform wajib_peran(array['admin','keuangan','supervisor','operator']);
  if ju(p, 'klien_id') is not null then
    select id into ada from barang_keluar where klien_id = ju(p, 'klien_id');
    if ada is null then select id into ada from perbaikan where klien_id = ju(p, 'klien_id'); end if;
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  select * into b from barang where id = jb(p, 'barang_id') and aktif;
  if not found then raise exception 'Barang tidak ditemukan.'; end if;
  if al = 'unit' then
    pid := buat_perbaikan(jsonb_build_object('klien_id', p->>'klien_id', 'tanggal', p->>'tanggal', 'shift', p->>'shift', 'unit_id', p->>'unit_id',
             'pelapor_id', p->>'penerima_id', 'kategori', p->>'kategori', 'deskripsi', coalesce(jt(p, 'keterangan'), 'Pengeluaran ' || b.nama)),
           jsonb_build_array(jsonb_build_object('barang_id', b.id, 'qty', p->>'qty', 'sumber', 'stok')), 'pengeluaran');
    select total into tot from perbaikan where id = pid;
    return jsonb_build_object('perbaikan_id', pid, 'nilai', tot);
  end if;
  bk := buat_barang_keluar(jd(p, 'tanggal'), jt(p, 'shift'), b.id, jn(p, 'qty'), al, null, jb(p, 'penerima_id'), jt(p, 'keterangan'), ju(p, 'klien_id'), null);
  return jsonb_build_object('id', bk.id, 'nilai', bk.nilai, 'harga_fifo', bk.harga_fifo);
end $$;

-- ---------- servis berkala ----------
create or replace function simpan_servis(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ada bigint; sid bigint; pid bigint; it jsonb; items jsonb := '[]'::jsonb; nm text;
begin
  perform wajib_peran(array['admin','keuangan','supervisor','operator']);
  if ju(p, 'klien_id') is not null then
    select id into ada from servis where klien_id = ju(p, 'klien_id');
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  if p->'items' is null or jsonb_array_length(p->'items') = 0 then raise exception 'Pilih minimal satu komponen yang diganti.'; end if;
  insert into servis(klien_id, tanggal, unit_id, hm, mekanik_id, keterangan)
  values (ju(p, 'klien_id'), jd(p, 'tanggal'), jb(p, 'unit_id'), jn(p, 'hm'), jb(p, 'mekanik_id'), jt(p, 'keterangan')) returning id into sid;
  for it in select * from jsonb_array_elements(p->'items') loop
    select nama into nm from komponen_perawatan where id = jb(it, 'komponen_id');
    insert into servis_item(servis_id, komponen_id, nama, qty, satuan, sumber, barang_id, harga)
    values (sid, jb(it, 'komponen_id'), coalesce(jt(it, 'nama'), nm), coalesce(jn(it, 'qty'), 1), coalesce(jt(it, 'satuan'), 'Pcs'),
            coalesce(jt(it, 'sumber'), 'langsung'), jb(it, 'barang_id'), coalesce(jn(it, 'harga'), 0));
    items := items || jsonb_build_array(jsonb_build_object('jenis_item', coalesce(jt(it, 'jenis_item'), 'perawatan_rutin'), 'nama', coalesce(jt(it, 'nama'), nm),
              'qty', coalesce(jn(it, 'qty'), 1), 'satuan', coalesce(jt(it, 'satuan'), 'Pcs'), 'sumber', coalesce(jt(it, 'sumber'), 'langsung'),
              'barang_id', it->>'barang_id', 'harga', coalesce(jn(it, 'harga'), 0), 'komponen_id', it->>'komponen_id'));
  end loop;
  pid := buat_perbaikan(jsonb_build_object('tanggal', p->>'tanggal', 'unit_id', p->>'unit_id', 'pelapor_id', p->>'mekanik_id', 'mekanik_id', p->>'mekanik_id',
           'kategori', 'Servis berkala', 'hm', p->>'hm', 'deskripsi', coalesce(jt(p, 'keterangan'), 'Servis berkala')), items, 'servis');
  update servis set perbaikan_id = pid where id = sid;
  return jsonb_build_object('id', sid, 'perbaikan_id', pid, 'total', (select total from perbaikan where id = pid));
end $$;
-- ---------- pembelian (stok gudang vs beban langsung) ----------
create or replace function finalisasi_langsung(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare l pembelian_langsung; pid bigint;
begin
  select * into l from pembelian_langsung where id = p_id;
  if l.alokasi = 'unit' and l.perbaikan_id is null then
    pid := buat_perbaikan(jsonb_build_object('tanggal', l.tanggal::text, 'unit_id', l.unit_id::text, 'kategori', coalesce(l.kategori_kerusakan, 'Perbaikan darurat'), 'deskripsi', l.uraian),
             jsonb_build_array(jsonb_build_object('jenis_item', 'jasa_bengkel', 'nama', l.uraian, 'qty', 1, 'satuan', 'Unit', 'harga', l.nominal, 'sumber', 'langsung')), 'pembelian_langsung');
    update pembelian_langsung set perbaikan_id = pid where id = p_id;
  end if;
  update pembelian_langsung set status = 'aktif' where id = p_id;
  update buku_kas set status = 'aktif' where ref_tabel = 'pembelian_langsung' and ref_id = p_id and status = 'menunggu';
end $$;

create or replace function simpan_pembelian(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare tipe text := jt(p, 'tipe'); tgl date := jd(p, 'tanggal'); cara text := coalesce(jt(p, 'cara_bayar'), 'tunai'); rek text := coalesce(jt(p, 'rekening'), 'kas');
        sup text := jt(p, 'supplier'); nilai numeric; st text; vid bigint; ada bigint; b barang; baru jsonb := p->'baru'; qty numeric; harga numeric; ref text; pesan text := '';
begin
  perform wajib_peran(array['admin','keuangan','supervisor','operator']);
  if tipe not in ('bbm','stok','langsung') then raise exception 'Pilih tipe pembelian.'; end if;
  if cara not in ('tunai','kredit') then raise exception 'Pilih cara bayar.'; end if;
  if ju(p, 'klien_id') is not null then
    select id into ada from (select id, klien_id from bbm_masuk union all select id, klien_id from barang_masuk union all select id, klien_id from pembelian_langsung) x where klien_id = ju(p, 'klien_id') limit 1;
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  if tipe = 'bbm' then
    qty := jn(p, 'qty'); harga := jn(p, 'harga'); nilai := round(qty * harga, 2);
    st := case when perlu_setuju('pembelian', nilai) then 'menunggu' else 'aktif' end;
    insert into bbm_masuk(klien_id, tanggal, no_po, pemasok_id, supplier, liter, harga_per_liter, cara_bayar, rekening, status)
    values (ju(p, 'klien_id'), tgl, jt(p, 'no_ref'), jb(p, 'pemasok_id'), sup, qty, harga, cara, rek, st) returning id into vid;
    ref := coalesce(jt(p, 'no_ref'), 'BBM-' || vid);
    if cara = 'tunai' then perform catat_kas(tgl, 'keluar', 'Pembelian Stok Gudang', 'Pembelian BBM ' || qty || ' L' || coalesce(' dari ' || sup, ''), ref, 'bbm_masuk', vid, nilai, rek, st, null); end if;
    if st = 'menunggu' then perform ajukan_persetujuan('pembelian', 'bbm_masuk', vid, nilai, 'Pembelian BBM ' || qty || ' L'); end if;
  elsif tipe = 'stok' then
    if baru is not null and jsonb_typeof(baru) = 'object' and jt(baru, 'nama') is not null then
      insert into barang(kode, nama, kategori, satuan, stok_min)
      values ('BRG-' || lpad((select coalesce(max(substring(kode from 5)::int), 0) + 1 from barang where kode ~ '^BRG-[0-9]+$')::text, 4, '0'),
              jt(baru, 'nama'), coalesce(jt(baru, 'kategori'), 'Spare Part'), coalesce(jt(baru, 'satuan'), 'Pcs'), coalesce(jn(baru, 'stok_min'), 0)) returning * into b;
    else
      select * into b from barang where id = jb(p, 'barang_id') and aktif;
      if not found then raise exception 'Barang tidak ditemukan.'; end if;
    end if;
    qty := jn(p, 'qty'); harga := jn(p, 'harga'); nilai := round(qty * harga, 2);
    st := case when perlu_setuju('pembelian', nilai) then 'menunggu' else 'aktif' end;
    insert into barang_masuk(klien_id, tanggal, no_ref, pemasok_id, supplier, barang_id, qty, harga, cara_bayar, rekening, status)
    values (ju(p, 'klien_id'), tgl, jt(p, 'no_ref'), jb(p, 'pemasok_id'), sup, b.id, qty, harga, cara, rek, st) returning id into vid;
    ref := coalesce(jt(p, 'no_ref'), 'BRM-' || vid);
    if cara = 'tunai' then perform catat_kas(tgl, 'keluar', 'Pembelian Stok Gudang', 'Pembelian ' || b.nama || ' ' || qty || ' ' || b.satuan || coalesce(' dari ' || sup, ''), ref, 'barang_masuk', vid, nilai, rek, st, null); end if;
    if st = 'menunggu' then perform ajukan_persetujuan('pembelian', 'barang_masuk', vid, nilai, 'Pembelian ' || b.nama); end if;
  else
    nilai := jn(p, 'nominal');
    if jt(p, 'uraian') is null then raise exception 'Uraian barang/jasa wajib diisi.'; end if;
    if coalesce(jt(p, 'alokasi'), 'lapangan') = 'lain' and jt(p, 'keterangan') is null then raise exception 'Keterangan wajib untuk alokasi Lain-lain.'; end if;
    if coalesce(jt(p, 'alokasi'), 'lapangan') = 'unit' and jb(p, 'unit_id') is null then raise exception 'No unit wajib untuk alokasi Unit Armada.'; end if;
    st := case when perlu_setuju('pembelian', nilai) then 'menunggu' else 'aktif' end;
    insert into pembelian_langsung(klien_id, tanggal, pemasok_id, supplier, uraian, alokasi, unit_id, kategori_kerusakan, nominal, cara_bayar, rekening, keterangan, status)
    values (ju(p, 'klien_id'), tgl, jb(p, 'pemasok_id'), sup, jt(p, 'uraian'), coalesce(jt(p, 'alokasi'), 'lapangan'), jb(p, 'unit_id'), jt(p, 'kategori'), nilai, cara, rek, jt(p, 'keterangan'), 'menunggu') returning id into vid;
    if cara = 'tunai' then perform catat_kas(tgl, 'keluar', 'Beban Langsung', jt(p, 'uraian') || coalesce(' (' || sup || ')', ''), 'PBL-' || vid, 'pembelian_langsung', vid, nilai, rek, 'menunggu', null); end if;
    if st = 'aktif' then perform finalisasi_langsung(vid); else perform ajukan_persetujuan('pembelian', 'pembelian_langsung', vid, nilai, jt(p, 'uraian')); end if;
  end if;
  if st = 'menunggu' then pesan := 'Menunggu persetujuan Admin; belum masuk laporan.'; end if;
  return jsonb_build_object('id', vid, 'nilai', nilai, 'status', st, 'pesan', pesan);
end $$;

-- ---------- buku kas, kasbon, penyesuaian ----------
create or replace function simpan_kas(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare arah text := jt(p, 'arah'); jumlah numeric := jn(p, 'jumlah'); sub text := jt(p, 'sub_kategori'); st text := 'aktif'; vid bigint; jenis text; rt text := jt(p, 'ref_tabel'); rid bigint := jb(p, 'ref_id'); v_sisa numeric; ada bigint;
begin
  perform wajib_peran(array['admin','keuangan']);
  if arah not in ('masuk','keluar') then raise exception 'Pilih jenis kas (masuk atau keluar).'; end if;
  if sub is null or jt(p, 'uraian') is null then raise exception 'Sub kategori dan uraian wajib diisi.'; end if;
  if ju(p, 'klien_id') is not null then
    select id into ada from buku_kas where klien_id = ju(p, 'klien_id');
    if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
  end if;
  if rt = 'faktur' then
    select sisa into v_sisa from v_faktur_saldo where id = rid;
    if v_sisa is null then raise exception 'Faktur tidak ditemukan.'; end if;
    if jumlah > v_sisa + 0.005 then raise exception 'Jumlah melebihi sisa faktur (%).', v_sisa; end if;
  elsif rt = 'tagihan_pemasok' then
    select sisa into v_sisa from v_tagihan_saldo where id = rid;
    if v_sisa is null then raise exception 'Tagihan tidak ditemukan.'; end if;
    if jumlah > v_sisa + 0.005 then raise exception 'Jumlah melebihi sisa tagihan (%).', v_sisa; end if;
  elsif rt is not null then raise exception 'Referensi tidak dikenal.';
  end if;
  if arah = 'keluar' then
    jenis := case when sub = 'Gaji' then 'pembayaran_payroll' else 'kas_keluar' end;
    if perlu_setuju(jenis, jumlah) then st := 'menunggu'; end if;
  end if;
  insert into buku_kas(klien_id, tanggal, arah, sub_kategori, aktivitas, rekening, uraian, referensi, ref_tabel, ref_id, jumlah, penanggung_jawab, status)
  values (ju(p, 'klien_id'), jd(p, 'tanggal'), arah, sub, jt(p, 'aktivitas'), coalesce(jt(p, 'rekening'), 'kas'), jt(p, 'uraian'), jt(p, 'referensi'), rt, rid, jumlah, jt(p, 'penanggung_jawab'), st) returning id into vid;
  if st = 'menunggu' then perform ajukan_persetujuan(jenis, 'buku_kas', vid, jumlah, jt(p, 'uraian')); end if;
  return jsonb_build_object('id', vid, 'status', st, 'pesan', case when st = 'menunggu' then 'Menunggu persetujuan Admin; belum masuk laporan.' else '' end);
end $$;

create or replace function simpan_kasbon(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare jml numeric := jn(p, 'nominal'); kid bigint := jb(p, 'karyawan_id'); vid bigint; kas bigint; st text := 'aktif'; nm text;
begin
  perform wajib_peran(array['admin','keuangan']);
  select nama into nm from karyawan where id = kid;
  if nm is null then raise exception 'Karyawan tidak ditemukan.'; end if;
  insert into kasbon(tanggal, karyawan_id, jenis, nominal, keterangan) values (jd(p, 'tanggal'), kid, 'pinjam', jml, jt(p, 'keterangan')) returning id into vid;
  if coalesce((p->>'catat_kas')::boolean, true) then
    if perlu_setuju('kas_keluar', jml) then st := 'menunggu'; end if;
    kas := catat_kas(jd(p, 'tanggal'), 'keluar', 'Kasbon', 'Kasbon ' || nm, 'KSB-' || vid, 'kasbon', vid, jml, coalesce(jt(p, 'rekening'), 'kas'), st, null);
    if st = 'menunggu' then perform ajukan_persetujuan('kas_keluar', 'buku_kas', kas, jml, 'Kasbon ' || nm); end if;
  end if;
  return jsonb_build_object('id', vid, 'status', st);
end $$;

create or replace function simpan_penyesuaian(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare kid bigint := jb(p, 'karyawan_id'); jenis text := jt(p, 'jenis'); kat text := jt(p, 'kategori'); jml numeric := jn(p, 'nominal'); v_sisa numeric; vid bigint;
begin
  perform wajib_peran(array['admin','keuangan']);
  if jenis not in ('pendapatan','potongan') then raise exception 'Pilih jenis penyesuaian.'; end if;
  if jenis = 'pendapatan' and kat not in ('bonus','insentif','tunjangan_lain','lainnya') then raise exception 'Kategori tidak sesuai untuk pendapatan.'; end if;
  if jenis = 'potongan' and kat not in ('kasbon','denda','klaim','lainnya') then raise exception 'Kategori tidak sesuai untuk potongan.'; end if;
  if kat = 'kasbon' then
    select saldo into v_sisa from v_saldo_kasbon where karyawan_id = kid;
    if jml > coalesce(v_sisa, 0) + 0.005 then raise exception 'Potongan kasbon melebihi sisa pinjaman (%).', coalesce(v_sisa, 0); end if;
  end if;
  insert into penyesuaian_gaji(tanggal, karyawan_id, jenis, kategori, keterangan, nominal) values (jd(p, 'tanggal'), kid, jenis, kat, jt(p, 'keterangan'), jml) returning id into vid;
  if kat = 'kasbon' then
    insert into kasbon(tanggal, karyawan_id, jenis, nominal, keterangan) values (jd(p, 'tanggal'), kid, 'potong', jml, 'Potong gaji (penyesuaian #' || vid || ')');
  end if;
  return jsonb_build_object('id', vid);
end $$;

-- ---------- payroll ----------
create or replace function hitung_payroll(p_mulai date, p_akhir date) returns integer language plpgsql security definer set search_path = public as $$
declare r record; ar aturan_absensi; jml numeric; n integer := 0; rit numeric; ton numeric; hr integer; pend numeric; pot numeric; potk numeric; kotor numeric; um numeric;
begin
  perform wajib_peran(array['admin','keuangan']);
  if p_akhir < p_mulai then raise exception 'Periode akhir tidak boleh sebelum periode mulai.'; end if;
  delete from penyesuaian_gaji where sumber in ('absensi','lembur') and tanggal between p_mulai and p_akhir;
  -- potongan telat dan alpa dari absensi (aturan ditentukan Admin)
  for r in select a.id, a.tanggal, a.status, a.telat_menit, a.karyawan_id, a.shift, k.jabatan, coalesce(g.gaji_pokok, 0) as gaji
             from absensi a join karyawan k on k.id = a.karyawan_id left join karyawan_gaji g on g.karyawan_id = a.karyawan_id
            where a.tanggal between p_mulai and p_akhir and ((a.status = 'hadir' and a.telat_menit > 0) or a.status = 'alpa') loop
    select * into ar from aturan_untuk(r.jabatan, r.shift, r.tanggal);
    if found then
      jml := 0;
      if r.status = 'hadir' then
        jml := case ar.potongan_telat_jenis when 'tetap' then ar.potongan_telat_nilai when 'per_menit' then r.telat_menit * ar.potongan_telat_nilai
                 when 'persen_harian' then r.gaji / ar.hari_kerja_per_bulan * ar.potongan_telat_nilai / 100 else 0 end;
      else
        jml := case ar.potongan_alpa_jenis when 'tetap' then ar.potongan_alpa_nilai
                 when 'persen_harian' then r.gaji / ar.hari_kerja_per_bulan * ar.potongan_alpa_nilai / 100 else 0 end;
      end if;
      jml := round(jml, 2);
      if jml > 0 then
        insert into penyesuaian_gaji(tanggal, karyawan_id, jenis, kategori, keterangan, nominal, sumber, ref_id)
        values (r.tanggal, r.karyawan_id, 'potongan', case when r.status = 'alpa' then 'alpa' else 'telat' end,
                case when r.status = 'alpa' then 'Alpa' else 'Terlambat ' || r.telat_menit || ' menit' end, jml, 'absensi', r.id);
      end if;
    end if;
  end loop;
  -- lembur yang disetujui
  insert into penyesuaian_gaji(tanggal, karyawan_id, jenis, kategori, keterangan, nominal, sumber, ref_id)
  select l.tanggal, l.karyawan_id, 'pendapatan', 'lembur', 'Lembur ' || l.jam || ' jam', l.nominal, 'lembur', l.id
    from lembur l where l.status = 'disetujui' and l.nominal > 0 and l.tanggal between p_mulai and p_akhir;
  -- payroll per karyawan
  for r in select k.id, k.nama, g.gaji_pokok, g.tarif_makan_per_hari from karyawan k join karyawan_gaji g on g.karyawan_id = k.id where k.aktif loop
    select coalesce(sum(premi) filter (where premi_jenis = 'ritase'), 0), coalesce(sum(premi) filter (where premi_jenis = 'tonase'), 0)
      into rit, ton from produksi where karyawan_id = r.id and status = 'aktif' and tanggal between p_mulai and p_akhir;
    select count(distinct tanggal) into hr from absensi where karyawan_id = r.id and status = 'hadir' and tanggal between p_mulai and p_akhir;
    select coalesce(sum(nominal) filter (where jenis = 'pendapatan'), 0), coalesce(sum(nominal) filter (where jenis = 'potongan'), 0),
           coalesce(sum(nominal) filter (where jenis = 'potongan' and kategori = 'kasbon'), 0)
      into pend, pot, potk from penyesuaian_gaji where karyawan_id = r.id and status = 'aktif' and tanggal between p_mulai and p_akhir;
    um := hr * r.tarif_makan_per_hari;
    kotor := r.gaji_pokok + rit + ton + um;
    insert into payroll(karyawan_id, bulan, periode_mulai, periode_akhir, gaji_pokok, premi_ritase, premi_tonase, hari_hadir, tarif_makan, uang_makan, pendapatan_kotor,
                        pendapatan_tidak_tetap, potongan_kasbon, potongan_tidak_tetap, thp)
    values (r.id, date_trunc('month', p_akhir)::date, p_mulai, p_akhir, r.gaji_pokok, rit, ton, hr, r.tarif_makan_per_hari, um, kotor, pend, potk, pot, kotor + pend - pot)
    on conflict (karyawan_id, periode_mulai, periode_akhir) do update
      set gaji_pokok = excluded.gaji_pokok, premi_ritase = excluded.premi_ritase, premi_tonase = excluded.premi_tonase, hari_hadir = excluded.hari_hadir,
          tarif_makan = excluded.tarif_makan, uang_makan = excluded.uang_makan, pendapatan_kotor = excluded.pendapatan_kotor,
          pendapatan_tidak_tetap = excluded.pendapatan_tidak_tetap, potongan_kasbon = excluded.potongan_kasbon,
          potongan_tidak_tetap = excluded.potongan_tidak_tetap, thp = excluded.thp, status = 'aktif', dihitung = now()
      where payroll.status_bayar = 'belum';
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function bayar_payroll(p_ids bigint[], p_tgl date, p_rek text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; st text; kas bigint; n integer := 0; total numeric := 0;
begin
  perform wajib_peran(array['admin','keuangan']);
  for r in select pr.id, pr.thp, k.nama from payroll pr join karyawan k on k.id = pr.karyawan_id where pr.id = any(p_ids) and pr.status = 'aktif' and pr.status_bayar = 'belum' and pr.thp > 0 loop
    st := case when perlu_setuju('pembayaran_payroll', r.thp) then 'menunggu' else 'aktif' end;
    kas := catat_kas(p_tgl, 'keluar', 'Gaji', 'Gaji netto ' || r.nama, 'PAY-' || r.id, 'payroll', r.id, r.thp, coalesce(p_rek, 'kas'), st, null);
    update payroll set status_bayar = case st when 'aktif' then 'sudah' else 'menunggu' end, tanggal_bayar = p_tgl, kas_id = kas where id = r.id;
    if st = 'menunggu' then perform ajukan_persetujuan('pembayaran_payroll', 'buku_kas', kas, r.thp, 'Gaji netto ' || r.nama); end if;
    n := n + 1; total := total + r.thp;
  end loop;
  if n = 0 then raise exception 'Tidak ada payroll yang bisa dibayar (sudah dibayar atau take home pay 0).'; end if;
  return jsonb_build_object('jumlah', n, 'total', total);
end $$;

-- ---------- jurnal manual ----------
create or replace function simpan_jurnal_manual(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare b jsonb; d numeric := 0; k numeric := 0; vid bigint; st text; nmr text; tgl date := jd(p, 'tanggal');
begin
  perform wajib_peran(array['admin','keuangan']);
  if p->'baris' is null or jsonb_array_length(p->'baris') < 2 then raise exception 'Jurnal minimal dua baris.'; end if;
  for b in select * from jsonb_array_elements(p->'baris') loop
    d := d + coalesce(jn(b, 'debit'), 0); k := k + coalesce(jn(b, 'kredit'), 0);
  end loop;
  if abs(d - k) > 0.005 or d <= 0 then raise exception 'Jurnal tidak seimbang: debit % kredit %.', d, k; end if;
  st := case when perlu_setuju('jurnal_manual', d) then 'menunggu' else 'aktif' end;
  nmr := 'JM-' || to_char(tgl, 'YYYYMM') || '-' || lpad(((select count(*) from jurnal where nomor like 'JM-' || to_char(tgl, 'YYYYMM') || '-%') + 1)::text, 3, '0');
  insert into jurnal(nomor, tanggal, uraian, status) values (nmr, tgl, coalesce(jt(p, 'uraian'), 'Jurnal manual'), st) returning id into vid;
  for b in select * from jsonb_array_elements(p->'baris') loop
    insert into jurnal_baris(jurnal_id, kode_akun, debit, kredit, uraian) values (vid, jt(b, 'kode_akun'), coalesce(jn(b, 'debit'), 0), coalesce(jn(b, 'kredit'), 0), jt(b, 'uraian'));
  end loop;
  if st = 'menunggu' then perform ajukan_persetujuan('jurnal_manual', 'jurnal', vid, d, coalesce(jt(p, 'uraian'), 'Jurnal manual')); end if;
  return jsonb_build_object('id', vid, 'nomor', nmr, 'status', st);
end $$;

-- ---------- faktur, kontra bon, tagihan ----------
create or replace function nomor_berikut(p_tabel text, p_awal text) returns text language plpgsql as $$
declare n integer;
begin
  if p_tabel = 'faktur' then
    select coalesce(max(substring(nomor from length(p_awal) + 1)::integer), 0) + 1 into n from faktur where nomor like p_awal || '%' and substring(nomor from length(p_awal) + 1) ~ '^[0-9]+$';
  else
    select coalesce(max(substring(nomor from length(p_awal) + 1)::integer), 0) + 1 into n from tagihan_pemasok where nomor like p_awal || '%' and substring(nomor from length(p_awal) + 1) ~ '^[0-9]+$';
  end if;
  return p_awal || lpad(n::text, 3, '0');
end $$;

create or replace function buat_faktur(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare pel pelanggan; tgl date; fid bigint; nmr text; v_dpp numeric := 0; ppnp numeric := coalesce(jn(p, 'ppn'), 0); pphp numeric := coalesce(jn(p, 'pph'), 0);
        g record; b jsonb; kt jsonb; kontra numeric := 0; ntrip integer := 0; ppn_ numeric; pph_ numeric; kotor numeric; v_sisa numeric; ter integer; jml numeric; mode text := coalesce(jt(p, 'mode'), 'produksi');
begin
  perform wajib_peran(array['admin','keuangan']);
  select * into pel from pelanggan where id = jb(p, 'pelanggan_id');
  if not found then raise exception 'Pilih pelanggan.'; end if;
  tgl := coalesce(jd(p, 'tanggal'), jd(p, 'sampai'), hari_ini());
  ter := coalesce(jn(p, 'termin')::integer, pel.termin_hari);
  nmr := nomor_berikut('faktur', 'FP-' || to_char(tgl, 'YYYYMM') || '-');
  insert into faktur(nomor, tanggal, pelanggan_id, periode_dari, periode_sampai, termin_hari, jatuh_tempo, ppn_persen, pph_persen, keterangan)
  values (nmr, tgl, pel.id, jd(p, 'dari'), jd(p, 'sampai'), ter, tgl + ter, ppnp, pphp, jt(p, 'keterangan')) returning id into fid;
  if mode = 'produksi' then
    if jd(p, 'dari') is null or jd(p, 'sampai') is null then raise exception 'Isi rentang tanggal timbangan.'; end if;
    for g in select t.tarif_id, s.nama as site, t.loading, t.dumping, max(t.jarak_km) as jarak, max(t.tarif) as tarif, count(*) as trip, sum(t.ritase) as rit,
                    sum(case when pl.dasar_tonase = 'terima' and t.tonase_terima is not null then t.tonase_terima else t.tonase end) as ton, sum(t.nominal) as nominal
               from produksi t join site s on s.id = t.site_id join pelanggan pl on pl.id = t.pelanggan_id
              where t.pelanggan_id = pel.id and t.faktur_id is null and t.status = 'aktif' and t.nominal > 0
                and t.tanggal_timbangan between jd(p, 'dari') and jd(p, 'sampai')
              group by t.tarif_id, s.nama, t.loading, t.dumping order by s.nama, t.loading, t.dumping loop
      insert into faktur_baris(faktur_id, deskripsi, kategori, kuantitas, satuan, tarif, jumlah, dari_produksi)
      values (fid, 'Hauling ' || g.site || ' ' || g.loading || ' - ' || g.dumping || ' (' || g.trip || ' trip, ' || g.rit || ' rit, ' || round(g.ton, 2) || ' ton x ' || g.jarak || ' km)',
              'hauling', round(g.ton, 2), 'ton', g.tarif, round(g.nominal, 2), true);
      v_dpp := v_dpp + round(g.nominal, 2); ntrip := ntrip + g.trip;
    end loop;
    update produksi set faktur_id = fid
     where pelanggan_id = pel.id and faktur_id is null and status = 'aktif' and nominal > 0 and tanggal_timbangan between jd(p, 'dari') and jd(p, 'sampai');
  end if;
  if p->'baris_manual' is not null then
    for b in select * from jsonb_array_elements(p->'baris_manual') loop
      if jt(b, 'deskripsi') is null then continue; end if;
      jml := round(coalesce(jn(b, 'kuantitas'), 1) * coalesce(jn(b, 'tarif'), 0), 2);
      insert into faktur_baris(faktur_id, deskripsi, kategori, kuantitas, satuan, tarif, jumlah, akun_pendapatan)
      values (fid, jt(b, 'deskripsi'), coalesce(jt(b, 'kategori'), 'lain'), coalesce(jn(b, 'kuantitas'), 1), jt(b, 'satuan'), coalesce(jn(b, 'tarif'), 0), jml, jt(b, 'akun_pendapatan'));
      v_dpp := v_dpp + jml;
    end loop;
  end if;
  if v_dpp <= 0 then raise exception 'Tidak ada yang bisa ditagihkan (tidak ada trip bernominal pada rentang itu dan tidak ada baris manual).'; end if;
  ppn_ := round(v_dpp * ppnp / 100, 2); pph_ := round(v_dpp * pphp / 100, 2); kotor := round(v_dpp + ppn_ - pph_, 2);
  if p->'kontra' is not null then
    for kt in select * from jsonb_array_elements(p->'kontra') loop
      if jn(kt, 'nominal') is null then continue; end if;
      if jb(kt, 'pemasok_id') is null then raise exception 'Pilih pemasok untuk kontra bon.'; end if;
      if jb(kt, 'tagihan_id') is not null then
        select sisa into v_sisa from v_tagihan_saldo where id = jb(kt, 'tagihan_id') and pemasok_id = jb(kt, 'pemasok_id');
        if v_sisa is null then raise exception 'Tagihan kontra bon tidak ditemukan atau bukan milik pemasok itu.'; end if;
        if jn(kt, 'nominal') > v_sisa + 0.005 then raise exception 'Pemotongan melebihi sisa utang tagihan (%).', v_sisa; end if;
      end if;
      insert into kontra_bon(faktur_id, pemasok_id, tagihan_id, nominal, keterangan) values (fid, jb(kt, 'pemasok_id'), jb(kt, 'tagihan_id'), round(jn(kt, 'nominal'), 2), jt(kt, 'keterangan'));
      kontra := kontra + round(jn(kt, 'nominal'), 2);
    end loop;
  end if;
  if kontra > kotor + 0.005 then raise exception 'Total kontra bon (%) melebihi total tagihan kotor (%).', kontra, kotor; end if;
  update faktur set dpp = round(v_dpp, 2), ppn = ppn_, pph = pph_, total_kotor = kotor, kontra_bon_total = kontra where id = fid;
  if coalesce((p->>'setuju')::boolean, false) then perform setujui_faktur(fid); end if;
  return jsonb_build_object('id', fid, 'nomor', nmr, 'dpp', v_dpp, 'ppn', ppn_, 'pph', pph_, 'total_kotor', kotor, 'kontra', kontra, 'netto', kotor - kontra, 'trip', ntrip);
end $$;

create or replace function setujui_faktur(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare f faktur; k record; tid bigint; v_sisa numeric;
begin
  perform wajib_peran(array['admin','keuangan']);
  select * into f from faktur where id = p_id for update;
  if not found then raise exception 'Faktur tidak ditemukan.'; end if;
  if f.status <> 'draft' then raise exception 'Faktur berstatus %; hanya Draft yang bisa disetujui.', f.status; end if;
  for k in select * from kontra_bon where faktur_id = p_id and status = 'draft' order by id loop
    tid := k.tagihan_id;
    if tid is null then
      insert into tagihan_pemasok(nomor, tanggal, pemasok_id, uraian, jumlah, termin_hari, jatuh_tempo, jurnalkan, dari_kontra_bon)
      values (nomor_berikut('tagihan', 'TG-' || to_char(hari_ini(), 'YYYYMM') || '-'), hari_ini(), k.pemasok_id, 'Kontra bon faktur ' || f.nomor || coalesce(': ' || k.keterangan, ''), k.nominal, 0, hari_ini(), false, true)
      returning id into tid;
      update kontra_bon set tagihan_id = tid where id = k.id;
    else
      select v.sisa into v_sisa from v_tagihan_saldo v where v.id = tid;
      if k.nominal > coalesce(v_sisa, 0) + 0.005 then raise exception 'Sisa utang tagihan tidak cukup untuk kontra bon (sisa %).', coalesce(v_sisa, 0); end if;
    end if;
    update kontra_bon set status = 'berlaku', tanggal_berlaku = hari_ini() where id = k.id;
  end loop;
  update faktur set status = 'disetujui', tanggal_disetujui = hari_ini() where id = p_id;
  return jsonb_build_object('nomor', f.nomor, 'status', 'disetujui');
end $$;

create or replace function batal_faktur(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare f faktur;
begin
  perform wajib_peran(array['admin','keuangan']);
  select * into f from faktur where id = p_id for update;
  if not found then raise exception 'Faktur tidak ditemukan.'; end if;
  if f.status <> 'draft' then raise exception 'Hanya faktur Draft yang bisa dibatalkan. Faktur yang sudah disetujui dikoreksi dengan jurnal manual.'; end if;
  update produksi set faktur_id = null where faktur_id = p_id;
  update kontra_bon set status = 'batal' where faktur_id = p_id and status = 'draft';
  update faktur set status = 'batal' where id = p_id;
  return jsonb_build_object('nomor', f.nomor, 'status', 'batal');
end $$;

create or replace function catat_pelunasan(p_faktur bigint, p_tgl date, p_nominal numeric, p_rek text) returns jsonb language plpgsql security definer set search_path = public as $$
declare f record; kas bigint; nom numeric;
begin
  perform wajib_peran(array['admin','keuangan']);
  select * into f from v_faktur_saldo where id = p_faktur;
  if not found then raise exception 'Faktur tidak ditemukan.'; end if;
  if f.status <> 'disetujui' then raise exception 'Faktur berstatus %. Setujui dulu agar PPN, PPh, dan kontra bon berlaku.', f.status; end if;
  nom := coalesce(p_nominal, f.sisa);
  if nom <= 0 then raise exception 'Nominal harus lebih dari 0.'; end if;
  if nom > f.sisa + 0.005 then raise exception 'Nominal melebihi sisa pembayaran netto (%).', f.sisa; end if;
  kas := catat_kas(p_tgl, 'masuk', 'Pembayaran Hauling', 'Pelunasan netto faktur ' || f.nomor || ' ' || f.pelanggan, f.nomor, 'faktur', f.id, nom, coalesce(p_rek, 'kas'), 'aktif', null);
  return jsonb_build_object('kas_id', kas, 'sisa', round(f.sisa - nom, 2));
end $$;

create or replace function simpan_tagihan(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare vid bigint; tgl date := jd(p, 'tanggal'); ter integer; nmr text;
begin
  perform wajib_peran(array['admin','keuangan']);
  select termin_hari into ter from pemasok where id = jb(p, 'pemasok_id');
  if ter is null then raise exception 'Pilih pemasok.'; end if;
  ter := coalesce(jn(p, 'termin')::integer, ter);
  nmr := coalesce(jt(p, 'nomor'), nomor_berikut('tagihan', 'TG-' || to_char(tgl, 'YYYYMM') || '-'));
  insert into tagihan_pemasok(nomor, tanggal, pemasok_id, uraian, jumlah, termin_hari, jatuh_tempo, jurnalkan, akun_beban)
  values (nmr, tgl, jb(p, 'pemasok_id'), jt(p, 'uraian'), jn(p, 'jumlah'), ter, tgl + ter, coalesce((p->>'jurnalkan')::boolean, false), jt(p, 'akun_beban')) returning id into vid;
  return jsonb_build_object('id', vid, 'nomor', nmr);
end $$;
-- ---------- persetujuan ----------
create or replace function proses_persetujuan(p_id bigint, p_setuju boolean, p_alasan text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r persetujuan; a aturan_persetujuan;
begin
  perform wajib_peran(array['admin','keuangan']);
  select * into r from persetujuan where id = p_id for update;
  if not found then raise exception 'Pengajuan tidak ditemukan.'; end if;
  if r.status <> 'menunggu' then raise exception 'Pengajuan sudah diproses (%).', r.status; end if;
  select * into a from aturan_persetujuan where jenis = r.jenis;
  if found and a.penyetuju = 'admin' and not adalah(array['admin']) then raise exception 'Jenis ini hanya dapat disetujui Admin.'; end if;
  if r.diajukan_oleh = auth.uid() and not adalah(array['admin']) then raise exception 'Pengaju tidak boleh menyetujui transaksinya sendiri.'; end if;
  if not p_setuju and coalesce(btrim(p_alasan), '') = '' then raise exception 'Alasan penolakan wajib diisi.'; end if;
  if p_setuju then
    case r.tabel
      when 'barang_masuk' then
        update barang_masuk set status = 'aktif', sisa = qty where id = r.baris_id;
        update buku_kas set status = 'aktif' where ref_tabel = 'barang_masuk' and ref_id = r.baris_id and status = 'menunggu';
      when 'bbm_masuk' then
        update bbm_masuk set status = 'aktif', sisa = liter where id = r.baris_id;
        update buku_kas set status = 'aktif' where ref_tabel = 'bbm_masuk' and ref_id = r.baris_id and status = 'menunggu';
      when 'pembelian_langsung' then
        perform finalisasi_langsung(r.baris_id);
      when 'buku_kas' then
        update buku_kas set status = 'aktif' where id = r.baris_id;
        update payroll set status_bayar = 'sudah' where kas_id = r.baris_id;
      when 'jurnal' then
        update jurnal set status = 'aktif' where id = r.baris_id;
      else
        raise exception 'Jenis pengajuan tidak dikenal.';
    end case;
  else
    case r.tabel
      when 'barang_masuk' then
        update barang_masuk set status = 'ditolak' where id = r.baris_id;
        update buku_kas set status = 'ditolak' where ref_tabel = 'barang_masuk' and ref_id = r.baris_id and status = 'menunggu';
      when 'bbm_masuk' then
        update bbm_masuk set status = 'ditolak' where id = r.baris_id;
        update buku_kas set status = 'ditolak' where ref_tabel = 'bbm_masuk' and ref_id = r.baris_id and status = 'menunggu';
      when 'pembelian_langsung' then
        update pembelian_langsung set status = 'ditolak' where id = r.baris_id;
        update buku_kas set status = 'ditolak' where ref_tabel = 'pembelian_langsung' and ref_id = r.baris_id and status = 'menunggu';
      when 'buku_kas' then
        update buku_kas set status = 'ditolak' where id = r.baris_id;
        update payroll set status_bayar = 'belum', kas_id = null, tanggal_bayar = null where kas_id = r.baris_id;
      when 'jurnal' then
        update jurnal set status = 'ditolak' where id = r.baris_id;
      else
        raise exception 'Jenis pengajuan tidak dikenal.';
    end case;
  end if;
  update persetujuan set status = case when p_setuju then 'disetujui' else 'ditolak' end, diproses_oleh = auth.uid(), diproses = now(), alasan = p_alasan where id = p_id;
  return jsonb_build_object('id', p_id, 'status', case when p_setuju then 'disetujui' else 'ditolak' end);
end $$;

-- ---------- pembatalan transaksi (stok dikembalikan bila perlu) ----------
create or replace function batalkan_transaksi(p_tabel text, p_id bigint, p_alasan text) returns jsonb language plpgsql security definer set search_path = public as $$
declare x record;
begin
  perform wajib_peran(array['admin','keuangan']);
  if coalesce(btrim(p_alasan), '') = '' then raise exception 'Alasan pembatalan wajib diisi.'; end if;
  if p_tabel = 'produksi' then
    select faktur_id into x from produksi where id = p_id;
    if x.faktur_id is not null then raise exception 'Trip sudah ditagih pada faktur. Batalkan faktur draft dulu.'; end if;
    update produksi set status = 'batal' where id = p_id;
  elsif p_tabel = 'bbm_pakai' then
    perform fifo_kembali('bbm_pakai', p_id);
    update bbm_pakai set status = 'batal' where id = p_id;
  elsif p_tabel = 'bbm_masuk' then
    select liter, sisa into x from bbm_masuk where id = p_id;
    if x.sisa < x.liter - 0.0001 then raise exception 'BBM dari penerimaan ini sudah terpakai; batalkan pemakaiannya dulu.'; end if;
    update bbm_masuk set status = 'batal', sisa = 0 where id = p_id;
    update buku_kas set status = 'batal' where ref_tabel = 'bbm_masuk' and ref_id = p_id;
  elsif p_tabel = 'barang_masuk' then
    select qty, sisa into x from barang_masuk where id = p_id;
    if x.sisa < x.qty - 0.0001 then raise exception 'Barang dari penerimaan ini sudah terpakai; batalkan pengeluarannya dulu.'; end if;
    update barang_masuk set status = 'batal', sisa = 0 where id = p_id;
    update buku_kas set status = 'batal' where ref_tabel = 'barang_masuk' and ref_id = p_id;
  elsif p_tabel = 'barang_keluar' then
    select perbaikan_id into x from barang_keluar where id = p_id;
    if x.perbaikan_id is not null then return batalkan_transaksi('perbaikan', x.perbaikan_id, p_alasan); end if;
    perform fifo_kembali('barang_keluar', p_id);
    update barang_keluar set status = 'batal' where id = p_id;
  elsif p_tabel = 'perbaikan' then
    for x in select barang_keluar_id as bk from perbaikan_item where perbaikan_id = p_id and barang_keluar_id is not null loop
      perform fifo_kembali('barang_keluar', x.bk);
      update barang_keluar set status = 'batal' where id = x.bk;
    end loop;
    update perbaikan set status = 'batal' where id = p_id;
    update servis set status = 'batal' where perbaikan_id = p_id;
  elsif p_tabel = 'pembelian_langsung' then
    select perbaikan_id into x from pembelian_langsung where id = p_id;
    if x.perbaikan_id is not null then update perbaikan set status = 'batal' where id = x.perbaikan_id; end if;
    update pembelian_langsung set status = 'batal' where id = p_id;
    update buku_kas set status = 'batal' where ref_tabel = 'pembelian_langsung' and ref_id = p_id;
  elsif p_tabel = 'buku_kas' then
    update buku_kas set status = 'batal' where id = p_id;
    update payroll set status_bayar = 'belum', kas_id = null, tanggal_bayar = null where kas_id = p_id;
  elsif p_tabel = 'kasbon' then update kasbon set status = 'batal' where id = p_id;
  elsif p_tabel = 'penyesuaian_gaji' then update penyesuaian_gaji set status = 'batal' where id = p_id;
  elsif p_tabel = 'tagihan_pemasok' then update tagihan_pemasok set status = 'batal' where id = p_id;
  elsif p_tabel = 'jurnal' then update jurnal set status = 'batal' where id = p_id;
  else raise exception 'Tabel tidak dapat dibatalkan lewat fungsi ini.';
  end if;
  return jsonb_build_object('tabel', p_tabel, 'id', p_id, 'status', 'batal');
end $$;

-- ---------- absensi ----------
create or replace function absen(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare kid bigint := karyawan_saya(); aksi text := jt(p, 'aksi'); wkt timestamptz := coalesce(nullif(p->>'waktu', '')::timestamptz, now()); tgl date; v absensi; ada bigint;
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor','operator']);
  if kid is null then raise exception 'Akun Anda belum ditautkan ke data karyawan. Hubungi Admin.'; end if;
  if wkt > now() + interval '5 minutes' then raise exception 'Waktu absen tidak valid.'; end if;
  if aksi not in ('masuk','pulang') then raise exception 'Aksi absen tidak dikenal.'; end if;
  tgl := (wkt at time zone 'Asia/Jakarta')::date;
  if aksi = 'masuk' then
    if ju(p, 'klien_id') is not null then
      select id into ada from absensi where klien_id = ju(p, 'klien_id');
      if ada is not null then return jsonb_build_object('id', ada, 'duplikat', true); end if;
    end if;
    insert into absensi(klien_id, karyawan_id, tanggal, shift, status, masuk_waktu, masuk_lat, masuk_lng, site_id, keterangan, sumber)
    values (ju(p, 'klien_id'), kid, tgl, coalesce(jt(p, 'shift'), '1'), 'hadir', wkt, jn(p, 'lat'), jn(p, 'lng'), jb(p, 'site_id'), jt(p, 'keterangan'), 'mandiri')
    on conflict (karyawan_id, tanggal) do update
      set status = 'hadir', masuk_waktu = excluded.masuk_waktu, masuk_lat = excluded.masuk_lat, masuk_lng = excluded.masuk_lng, shift = excluded.shift,
          site_id = excluded.site_id, keterangan = excluded.keterangan, sumber = 'mandiri', klien_id = coalesce(absensi.klien_id, excluded.klien_id)
      where absensi.masuk_waktu is null
    returning * into v;
    if not found then raise exception 'Anda sudah absen masuk pada tanggal ini.'; end if;
  else
    select * into v from absensi where karyawan_id = kid and masuk_waktu is not null and pulang_waktu is null and masuk_waktu > wkt - interval '24 hours' order by masuk_waktu desc limit 1;
    if not found then
      select * into v from absensi where karyawan_id = kid and pulang_waktu is not null and pulang_waktu > wkt - interval '24 hours' order by pulang_waktu desc limit 1;
      if found then return jsonb_build_object('id', v.id, 'duplikat', true); end if;
      raise exception 'Belum ada absen masuk. Absen masuk dulu.';
    end if;
    update absensi set pulang_waktu = wkt, pulang_lat = jn(p, 'lat'), pulang_lng = jn(p, 'lng') where id = v.id returning * into v;
  end if;
  return jsonb_build_object('id', v.id, 'aksi', aksi, 'tanggal', v.tanggal, 'telat_menit', v.telat_menit, 'di_luar_radius', v.di_luar_radius, 'jarak_m', v.jarak_masuk_m, 'jam_kerja', v.jam_kerja);
end $$;

create or replace function catat_absensi_admin(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare tgl date := jd(p, 'tanggal'); jm time := nullif(p->>'jam_masuk', '')::time; jp time := nullif(p->>'jam_pulang', '')::time; tm timestamptz; tp timestamptz; v absensi;
begin
  perform wajib_peran(array['admin','keuangan','supervisor']);
  if jb(p, 'karyawan_id') is null then raise exception 'Pilih karyawan.'; end if;
  if jt(p, 'alasan') is null then raise exception 'Alasan wajib diisi.'; end if;
  if jm is not null then tm := (tgl + jm) at time zone 'Asia/Jakarta'; end if;
  if jp is not null then
    tp := (tgl + jp) at time zone 'Asia/Jakarta';
    if tm is not null and tp < tm then tp := tp + interval '1 day'; end if;
  end if;
  insert into absensi(karyawan_id, tanggal, shift, status, masuk_waktu, pulang_waktu, sumber, alasan_koreksi, keterangan, dicatat_oleh)
  values (jb(p, 'karyawan_id'), tgl, coalesce(jt(p, 'shift'), '1'), coalesce(jt(p, 'status'), 'hadir'), tm, tp, 'admin', jt(p, 'alasan'), jt(p, 'keterangan'), auth.uid())
  on conflict (karyawan_id, tanggal) do update
    set status = excluded.status, shift = excluded.shift, masuk_waktu = excluded.masuk_waktu, pulang_waktu = excluded.pulang_waktu, sumber = 'admin',
        alasan_koreksi = excluded.alasan_koreksi, keterangan = excluded.keterangan, dicatat_oleh = auth.uid()
  returning * into v;
  return jsonb_build_object('id', v.id, 'telat_menit', v.telat_menit, 'jam_kerja', v.jam_kerja);
end $$;

create or replace function proses_lembur(p_id bigint, p_setuju boolean, p_alasan text) returns jsonb language plpgsql security definer set search_path = public as $$
declare l lembur; jab text; a aturan_absensi; gaji numeric; nom numeric := 0; sh text;
begin
  perform wajib_peran(array['admin','keuangan','supervisor']);
  select * into l from lembur where id = p_id for update;
  if not found then raise exception 'Lembur tidak ditemukan.'; end if;
  if p_setuju then
    select k.jabatan into jab from karyawan k where k.id = l.karyawan_id;
    select shift into sh from absensi where id = l.absensi_id;
    select * into a from aturan_untuk(jab, sh, l.tanggal);
    select coalesce(gaji_pokok, 0) into gaji from karyawan_gaji where karyawan_id = l.karyawan_id;
    if found then
      nom := case a.lembur_jenis when 'per_jam' then l.jam * a.lembur_nilai else l.jam * (coalesce(gaji, 0) / 173) * a.lembur_nilai end;
    end if;
    update lembur set status = 'disetujui', nominal = round(coalesce(nom, 0), 2), disetujui_oleh = auth.uid(), waktu_setuju = now(), alasan = p_alasan where id = p_id;
  else
    if coalesce(btrim(p_alasan), '') = '' then raise exception 'Alasan penolakan wajib diisi.'; end if;
    update lembur set status = 'ditolak', nominal = 0, disetujui_oleh = auth.uid(), waktu_setuju = now(), alasan = p_alasan where id = p_id;
  end if;
  return jsonb_build_object('id', p_id, 'nominal', nom);
end $$;

-- ---------- kunci periode ----------
create or replace function kunci_periode(p_sampai date) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin']);
  insert into periode_kunci(sampai) values (coalesce(p_sampai, date '1900-01-01'));
  return jsonb_build_object('sampai', p_sampai);
end $$;

-- ---------- data pilihan untuk formulir (juga disimpan di perangkat untuk mode offline) ----------
create or replace function opsi_lapangan() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if peran_saya() is null then raise exception 'Akun belum aktif. Hubungi Admin.'; end if;
  return jsonb_build_object(
    'saya', (select jsonb_build_object('id', id, 'nama', nama, 'peran', peran, 'karyawan_id', karyawan_id) from profil_pengguna where id = auth.uid()),
    'unit', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kode', kode, 'nama', nama, 'kategori', kategori, 'status', status, 'hm', hm_terakhir(id)) order by kode), '[]'::jsonb) from unit where status <> 'nonaktif'),
    'karyawan', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kode', kode, 'nama', nama, 'jabatan', jabatan) order by nama), '[]'::jsonb) from karyawan where aktif),
    'site', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kode', kode, 'nama', nama, 'lat', lat, 'lng', lng, 'radius_m', radius_m) order by nama), '[]'::jsonb) from site where aktif),
    'rute', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select distinct site_id, loading, dumping from tarif_rute where aktif) x),
    'barang', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'kode', b.kode, 'nama', b.nama, 'kategori', b.kategori, 'satuan', b.satuan,
                 'saldo', (select coalesce(sum(m.sisa), 0) from barang_masuk m where m.barang_id = b.id and m.status = 'aktif')) order by b.nama), '[]'::jsonb) from barang b where b.aktif),
    'stok_bbm', (select coalesce(sum(sisa), 0) from bbm_masuk where status = 'aktif'),
    'pemasok', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kode', kode, 'nama', nama, 'termin', termin_hari) order by nama), '[]'::jsonb) from pemasok where aktif),
    'pelanggan', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kode', kode, 'nama', nama, 'termin', termin_hari) order by nama), '[]'::jsonb) from pelanggan where aktif),
    'komponen', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nama', nama) order by nama), '[]'::jsonb) from komponen_perawatan where aktif),
    'kategori_kas', (select coalesce(jsonb_agg(jsonb_build_object('arah', arah, 'nama', nama, 'aktivitas', aktivitas) order by arah, nama), '[]'::jsonb) from kategori_kas where aktif),
    'akun', (select coalesce(jsonb_agg(jsonb_build_object('kode', kode, 'nama', nama, 'kelompok', kelompok) order by kode), '[]'::jsonb) from akun where aktif),
    'metode', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kode', kode, 'nama', nama, 'dasar', dasar, 'pakai_jarak', pakai_jarak) order by id), '[]'::jsonb) from metode_tagihan where aktif)
  );
end $$;

-- laporan yang gagal tersinkron dari perangkat (untuk ditinjau Admin)
create or replace function lapor_gagal_sinkron(p_rpc text, p_payload jsonb, p_galat text) returns void language sql security definer set search_path = public as $$
  insert into antrian_sinkron(rpc, payload, galat) values (p_rpc, p_payload, p_galat)
$$;
-- ---------- 7. LAPORAN dan DASHBOARD (dihitung di database, hasil jsonb) ----------
create or replace function kol(spec text) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(jsonb_build_object('k', split_part(x, ':', 1), 'l', split_part(x, ':', 2), 't', split_part(x, ':', 3)) order by n), '[]'::jsonb)
    from unnest(string_to_array(spec, '|')) with ordinality as u(x, n)
$$;

-- khusus dipanggil fungsi laporan lain (tidak diberikan ke klien)
create or replace function tabel_json(p_judul text, p_kolom jsonb, p_sql text) returns jsonb language plpgsql security definer set search_path = public as $$
declare hasil jsonb;
begin
  execute 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from (' || p_sql || ') q' into hasil;
  return jsonb_build_object('judul', p_judul, 'kolom', p_kolom, 'baris', hasil);
end $$;

-- ---------- laba rugi dan neraca ----------
create or replace function lap_laba_rugi(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  with s as (
    select a.kode, a.nama, a.kelompok,
           case when a.kelompok = 'Pendapatan' then coalesce(sum(j.kredit - j.debit), 0) else coalesce(sum(j.debit - j.kredit), 0) end as jml
      from akun a left join v_jurnal j on j.kode_akun = a.kode and j.tanggal between p_d1 and p_d2
     where a.kelompok in ('Pendapatan','Beban') group by a.kode, a.nama, a.kelompok),
  t as (select coalesce(sum(jml) filter (where kelompok = 'Pendapatan'), 0) as pend, coalesce(sum(jml) filter (where kelompok = 'Beban'), 0) as beban from s)
  select jsonb_agg(jsonb_build_object('u', u, 'j', j, '_g', g) order by o1, o2, o3) into r from (
    select 1 as o1, 0 as o2, ''::text as o3, 'PENDAPATAN'::text as u, null::numeric as j, 'h'::text as g
    union all select 1, 1, kode, kode || '  ' || nama, jml, null from s where kelompok = 'Pendapatan' and jml <> 0
    union all select 1, 2, '', 'Total Pendapatan', pend, 't' from t
    union all select 2, 0, '', 'BEBAN', null, 'h'
    union all select 2, 1, kode, kode || '  ' || nama, jml, null from s where kelompok = 'Beban' and jml <> 0
    union all select 2, 2, '', 'Total Beban', beban, 't' from t
    union all select 3, 0, '', 'LABA (RUGI) BERSIH', pend - beban, 't' from t) x;
  return jsonb_build_object('judul', 'Laporan Laba Rugi', 'kolom', kol('u:Uraian:t|j:Jumlah (Rp):n'), 'baris', coalesce(r, '[]'::jsonb));
end $$;

create or replace function lap_neraca(p_tgl date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  with s as (
    select a.kode, a.nama, a.kelompok,
           case when a.kelompok = 'Aset' then coalesce(sum(j.debit - j.kredit), 0)
                when a.kelompok in ('Liabilitas','Ekuitas') then coalesce(sum(j.kredit - j.debit), 0)
                when a.kelompok = 'Pendapatan' then coalesce(sum(j.kredit - j.debit), 0)
                else coalesce(sum(j.debit - j.kredit), 0) end as jml
      from akun a left join v_jurnal j on j.kode_akun = a.kode and j.tanggal <= p_tgl group by a.kode, a.nama, a.kelompok),
  t as (select coalesce(sum(jml) filter (where kelompok = 'Aset'), 0) as aset, coalesce(sum(jml) filter (where kelompok = 'Liabilitas'), 0) as liab,
               coalesce(sum(jml) filter (where kelompok = 'Ekuitas'), 0) as ekuitas,
               coalesce(sum(jml) filter (where kelompok = 'Pendapatan'), 0) - coalesce(sum(jml) filter (where kelompok = 'Beban'), 0) as laba from s)
  select jsonb_agg(jsonb_build_object('u', u, 'j', j, '_g', g) order by o1, o2, o3) into r from (
    select 1 as o1, 0 as o2, ''::text as o3, 'ASET'::text as u, null::numeric as j, 'h'::text as g
    union all select 1, 1, kode, kode || '  ' || nama, jml, null from s where kelompok = 'Aset' and jml <> 0
    union all select 1, 2, '', 'Total Aset', aset, 't' from t
    union all select 2, 0, '', 'LIABILITAS', null, 'h'
    union all select 2, 1, kode, kode || '  ' || nama, jml, null from s where kelompok = 'Liabilitas' and jml <> 0
    union all select 2, 2, '', 'Total Liabilitas', liab, 't' from t
    union all select 3, 0, '', 'EKUITAS', null, 'h'
    union all select 3, 1, kode, kode || '  ' || nama, jml, null from s where kelompok = 'Ekuitas' and jml <> 0
    union all select 3, 2, 'z', 'Laba (rugi) berjalan', laba, null from t
    union all select 3, 3, '', 'Total Ekuitas', ekuitas + laba, 't' from t
    union all select 4, 0, '', 'TOTAL LIABILITAS + EKUITAS', liab + ekuitas + laba, 't' from t
    union all select 4, 1, '', 'Selisih (harus 0)', aset - (liab + ekuitas + laba), null from t) x;
  return jsonb_build_object('judul', 'Neraca', 'kolom', kol('u:Uraian:t|j:Jumlah (Rp):n'), 'baris', coalesce(r, '[]'::jsonb));
end $$;

create or replace function lap_jurnal(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Jurnal Umum', kol('tanggal:Tanggal:d|sumber:Sumber:t|uraian:Uraian:t|kode_akun:Kode akun:t|nama:Nama akun:t|debit:Debit:n|kredit:Kredit:n'),
    format('select j.tanggal, j.sumber, j.uraian, j.kode_akun, a.nama, j.debit, j.kredit from v_jurnal j join akun a on a.kode = j.kode_akun where j.tanggal between %L and %L order by j.tanggal, j.sumber, j.ref_id, j.debit desc', p_d1, p_d2));
end $$;

create or replace function lap_buku_besar(p_kode text, p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Buku Besar ' || p_kode, kol('tanggal:Tanggal:d|sumber:Sumber:t|uraian:Uraian:t|debit:Debit:n|kredit:Kredit:n|saldo:Saldo:n'),
    format('select tanggal, sumber, uraian, debit, kredit, sum(debit - kredit) over (order by tanggal, sumber, ref_id, uraian rows unbounded preceding) as saldo
              from v_jurnal where kode_akun = %L and tanggal <= %L order by tanggal, sumber, ref_id, uraian', p_kode, p_d2));
end $$;

-- ---------- buku kas dan arus kas ----------
create or replace function lap_buku_kas(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Buku Kas', kol('tanggal:Tanggal:d|sub_kategori:Sub kategori:t|aktivitas:Aktivitas:t|rekening:Rekening:t|uraian:Uraian:t|referensi:Referensi:t|masuk:Kas masuk:n|keluar:Kas keluar:n|saldo:Saldo:n'),
    format('select * from (select tanggal, sub_kategori, aktivitas, rekening, uraian, referensi, case when arah = ''masuk'' then jumlah end as masuk, case when arah = ''keluar'' then jumlah end as keluar,
              sum(case when arah = ''masuk'' then jumlah else -jumlah end) over (order by tanggal, id rows unbounded preceding) as saldo, id
              from buku_kas where status = ''aktif'' and tanggal <= %L) z where tanggal >= %L order by tanggal, id', p_d2, p_d1));
end $$;

create or replace function dash_kas(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare awal numeric; masuk numeric; keluar numeric; akt jsonb; rek jsonb; bln jsonb; kontra numeric;
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  select coalesce(sum(case when arah = 'masuk' then jumlah else -jumlah end), 0) into awal from buku_kas
   where status = 'aktif' and (tanggal < p_d1 or (sub_kategori = 'Saldo Awal' and tanggal <= p_d2));
  select coalesce(sum(jumlah) filter (where arah = 'masuk'), 0), coalesce(sum(jumlah) filter (where arah = 'keluar'), 0) into masuk, keluar from buku_kas
   where status = 'aktif' and tanggal between p_d1 and p_d2 and sub_kategori <> 'Saldo Awal';
  select coalesce(jsonb_agg(jsonb_build_object('nama', a.aktivitas, 'masuk', a.masuk, 'keluar', a.keluar,
           'sub', (select coalesce(jsonb_agg(jsonb_build_object('nama', s.sub_kategori, 'masuk', s.masuk, 'keluar', s.keluar) order by s.masuk + s.keluar desc), '[]'::jsonb)
                     from (select sub_kategori, coalesce(sum(jumlah) filter (where arah = 'masuk'), 0) as masuk, coalesce(sum(jumlah) filter (where arah = 'keluar'), 0) as keluar
                             from buku_kas where status = 'aktif' and tanggal between p_d1 and p_d2 and sub_kategori <> 'Saldo Awal' and aktivitas = a.aktivitas group by sub_kategori) s)
         ) order by a.aktivitas), '[]'::jsonb) into akt
    from (select aktivitas, coalesce(sum(jumlah) filter (where arah = 'masuk'), 0) as masuk, coalesce(sum(jumlah) filter (where arah = 'keluar'), 0) as keluar
            from buku_kas where status = 'aktif' and tanggal between p_d1 and p_d2 and sub_kategori <> 'Saldo Awal' group by aktivitas) a;
  select coalesce(jsonb_agg(jsonb_build_object('nama', r.rekening,
           'awal', (select coalesce(sum(case when k.arah = 'masuk' then k.jumlah else -k.jumlah end), 0) from buku_kas k where k.status = 'aktif' and k.rekening = r.rekening and (k.tanggal < p_d1 or (k.sub_kategori = 'Saldo Awal' and k.tanggal <= p_d2))),
           'masuk', (select coalesce(sum(k.jumlah), 0) from buku_kas k where k.status = 'aktif' and k.rekening = r.rekening and k.arah = 'masuk' and k.tanggal between p_d1 and p_d2 and k.sub_kategori <> 'Saldo Awal'),
           'keluar', (select coalesce(sum(k.jumlah), 0) from buku_kas k where k.status = 'aktif' and k.rekening = r.rekening and k.arah = 'keluar' and k.tanggal between p_d1 and p_d2)) order by r.rekening), '[]'::jsonb) into rek
    from (values ('kas'), ('bank')) as r(rekening);
  select coalesce(jsonb_agg(jsonb_build_object('b', to_char(g.b, 'YYYY-MM'),
           'masuk', (select coalesce(sum(k.jumlah), 0) from buku_kas k where k.status = 'aktif' and k.arah = 'masuk' and k.sub_kategori <> 'Saldo Awal' and date_trunc('month', k.tanggal) = g.b),
           'keluar', (select coalesce(sum(k.jumlah), 0) from buku_kas k where k.status = 'aktif' and k.arah = 'keluar' and date_trunc('month', k.tanggal) = g.b)) order by g.b), '[]'::jsonb) into bln
    from generate_series(date_trunc('month', p_d1), date_trunc('month', p_d2), interval '1 month') as g(b);
  select coalesce(sum(kb.nominal), 0) into kontra from kontra_bon kb where kb.status = 'berlaku' and kb.tanggal_berlaku between p_d1 and p_d2;
  return jsonb_build_object('d1', p_d1, 'd2', p_d2, 'saldo_awal', awal, 'masuk', masuk, 'keluar', keluar, 'saldo_akhir', awal + masuk - keluar,
                            'aktivitas', akt, 'rekening', rek, 'bulan', bln, 'kontra', kontra);
end $$;

-- ---------- dashboard keuangan dan rincian beban operasional ----------
create or replace function rincian_beban(p_d1 date, p_d2 date, p_boleh_gaji boolean) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare bbm numeric; suku numeric; ban numeric; jasa numeric; gaji numeric; total_beban numeric; lain numeric; tot numeric; items jsonb;
begin
  select coalesce(sum(nilai), 0) into bbm from bbm_pakai where status = 'aktif' and alokasi = 'unit' and tanggal between p_d1 and p_d2;
  select coalesce(sum(i.subtotal) filter (where i.jenis_item = 'suku_cadang'), 0), coalesce(sum(i.subtotal) filter (where i.jenis_item in ('ban','perawatan_rutin')), 0),
         coalesce(sum(i.subtotal) filter (where i.jenis_item = 'jasa_bengkel'), 0)
    into suku, ban, jasa from perbaikan_item i join perbaikan p on p.id = i.perbaikan_id where p.status = 'aktif' and p.tanggal between p_d1 and p_d2;
  select coalesce(sum(debit - kredit) filter (where kode_akun in ('5-1200','5-1210','5-1220','5-1230')), 0), coalesce(sum(j.debit - j.kredit), 0)
    into gaji, total_beban from v_jurnal j join akun a on a.kode = j.kode_akun where a.kelompok = 'Beban' and j.tanggal between p_d1 and p_d2;
  lain := greatest(0, total_beban - bbm - suku - ban - jasa - gaji);
  tot := bbm + suku + ban + jasa + gaji + lain;
  items := jsonb_build_array(
    jsonb_build_object('kunci', 'bbm', 'nama', 'Biaya Solar (BBM)', 'jumlah', bbm),
    jsonb_build_object('kunci', 'suku', 'nama', 'Suku Cadang (Spare Part)', 'jumlah', suku),
    jsonb_build_object('kunci', 'ban', 'nama', 'Perawatan & Ban', 'jumlah', ban),
    jsonb_build_object('kunci', 'gaji', 'nama', 'Gaji Pokok, Premi & Uang Makan Driver', 'jumlah', case when p_boleh_gaji then gaji else null end),
    jsonb_build_object('kunci', 'jasa', 'nama', 'Jasa Perbaikan & Perawatan Bengkel', 'jumlah', jasa),
    jsonb_build_object('kunci', 'lain', 'nama', 'Biaya Operasional Lapangan & Lainnya', 'jumlah', lain));
  return jsonb_build_object('total', tot, 'beban_jurnal', total_beban, 'item', items, 'mentah', jsonb_build_object('bbm', bbm, 'suku', suku, 'ban', ban, 'jasa', jasa, 'gaji', gaji, 'lain', lain));
end $$;

create or replace function dash_keuangan(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare pend numeric; beban numeric; ton numeric; bln jsonb; pel jsonb; rb jsonb;
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  select coalesce(sum(j.kredit - j.debit) filter (where a.kelompok = 'Pendapatan'), 0), coalesce(sum(j.debit - j.kredit) filter (where a.kelompok = 'Beban'), 0)
    into pend, beban from v_jurnal j join akun a on a.kode = j.kode_akun where j.tanggal between p_d1 and p_d2;
  select coalesce(sum(tonase), 0) into ton from produksi where status = 'aktif' and tanggal_timbangan between p_d1 and p_d2;
  select coalesce(jsonb_agg(jsonb_build_object('b', to_char(g.b, 'YYYY-MM'),
      'pendapatan', (select coalesce(sum(j.kredit - j.debit), 0) from v_jurnal j join akun a on a.kode = j.kode_akun where a.kelompok = 'Pendapatan' and date_trunc('month', j.tanggal) = g.b),
      'beban', (select coalesce(sum(j.debit - j.kredit), 0) from v_jurnal j join akun a on a.kode = j.kode_akun where a.kelompok = 'Beban' and date_trunc('month', j.tanggal) = g.b)) order by g.b), '[]'::jsonb) into bln
    from generate_series(date_trunc('month', p_d1), date_trunc('month', p_d2), interval '1 month') as g(b);
  select coalesce(jsonb_agg(jsonb_build_object('nama', x.nama, 'pendapatan', x.pend, 'tonase', x.ton) order by x.pend desc), '[]'::jsonb) into pel
    from (select pl.nama, coalesce(sum(p.nominal), 0) as pend, coalesce(sum(p.tonase), 0) as ton from produksi p join pelanggan pl on pl.id = p.pelanggan_id
           where p.status = 'aktif' and p.tanggal_timbangan between p_d1 and p_d2 group by pl.nama) x;
  rb := rincian_beban(p_d1, p_d2, true);
  return jsonb_build_object('d1', p_d1, 'd2', p_d2, 'pendapatan', pend, 'beban', beban, 'laba', pend - beban, 'margin', case when pend > 0 then round((pend - beban) / pend * 100, 2) else 0 end,
                            'tonase', ton, 'pendapatan_per_ton', case when ton > 0 then round(pend / ton, 0) else 0 end, 'bulan', bln, 'pelanggan', pel, 'rincian', rb);
end $$;

create or replace function dash_armada(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare unit_ jsonb; rb jsonb; ton numeric; tot numeric; boleh boolean;
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  boleh := adalah(array['admin','keuangan']);
  select coalesce(jsonb_agg(jsonb_build_object('unit', u.kode, 'kategori', u.kategori, 'liter', coalesce(b.liter, 0), 'bbm', coalesce(b.nilai, 0),
           'suku', coalesce(r.suku, 0), 'ban', coalesce(r.ban, 0), 'jasa', coalesce(r.jasa, 0), 'premi', coalesce(pr.premi, 0), 'tonase', coalesce(pr.ton, 0), 'ritase', coalesce(pr.rit, 0),
           'biaya', coalesce(b.nilai, 0) + coalesce(r.suku, 0) + coalesce(r.ban, 0) + coalesce(r.jasa, 0) + coalesce(pr.premi, 0)) order by u.kode), '[]'::jsonb) into unit_
    from unit u
    left join (select unit_id, sum(liter) as liter, sum(nilai) as nilai from bbm_pakai where status = 'aktif' and alokasi = 'unit' and tanggal between p_d1 and p_d2 group by unit_id) b on b.unit_id = u.id
    left join (select p.unit_id, sum(i.subtotal) filter (where i.jenis_item = 'suku_cadang') as suku, sum(i.subtotal) filter (where i.jenis_item in ('ban','perawatan_rutin')) as ban,
                      sum(i.subtotal) filter (where i.jenis_item = 'jasa_bengkel') as jasa
                 from perbaikan p join perbaikan_item i on i.perbaikan_id = p.id where p.status = 'aktif' and p.tanggal between p_d1 and p_d2 group by p.unit_id) r on r.unit_id = u.id
    left join (select unit_id, sum(premi) as premi, sum(tonase) as ton, sum(ritase) as rit from produksi where status = 'aktif' and tanggal_timbangan between p_d1 and p_d2 group by unit_id) pr on pr.unit_id = u.id;
  rb := rincian_beban(p_d1, p_d2, boleh);
  select coalesce(sum(tonase), 0) into ton from produksi where status = 'aktif' and tanggal_timbangan between p_d1 and p_d2;
  select coalesce(sum((x->>'jumlah')::numeric), 0) into tot from jsonb_array_elements(rb->'item') x where x->>'kunci' <> 'lain' and x->>'jumlah' is not null;
  return jsonb_build_object('d1', p_d1, 'd2', p_d2, 'gaji_tampil', boleh, 'unit', unit_, 'rincian', rb, 'total_biaya', tot, 'tonase', ton, 'biaya_per_ton', case when ton > 0 then round(tot / ton, 0) else 0 end);
end $$;

create or replace function dash_rute(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rute jsonb; hari jsonb; tot jsonb;
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  select coalesce(jsonb_agg(jsonb_build_object('rute', x.rute, 'trip', x.trip, 'ritase', x.rit, 'tonase', x.ton, 'nominal', x.nom) order by x.ton desc), '[]'::jsonb) into rute
    from (select s.nama || ': ' || p.loading || ' - ' || p.dumping as rute, count(*) as trip, sum(p.ritase) as rit, sum(p.tonase) as ton, sum(p.nominal) as nom
            from produksi p join site s on s.id = p.site_id where p.status = 'aktif' and p.tanggal_timbangan between p_d1 and p_d2 group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('tanggal', x.t, 'tonase', x.ton, 'ritase', x.rit) order by x.t), '[]'::jsonb) into hari
    from (select tanggal_timbangan as t, sum(tonase) as ton, sum(ritase) as rit from produksi where status = 'aktif' and tanggal_timbangan between p_d1 and p_d2 group by 1) x;
  select jsonb_build_object('trip', count(*), 'ritase', coalesce(sum(ritase), 0), 'tonase', coalesce(sum(tonase), 0), 'nominal', coalesce(sum(nominal), 0)) into tot
    from produksi where status = 'aktif' and tanggal_timbangan between p_d1 and p_d2;
  return jsonb_build_object('d1', p_d1, 'd2', p_d2, 'rute', rute, 'hari', hari, 'total', tot);
end $$;

create or replace function peringatan() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare dok jsonb; stok jsonb; servis jsonb; faktur jsonb; n_setuju integer; n_lembur integer; hadir integer; belum integer; tgl date := hari_ini();
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  select coalesce(jsonb_agg(jsonb_build_object('tipe', d.pemilik_tipe, 'nama', coalesce(u.kode, k.nama), 'dokumen', d.jenis, 'berlaku', d.berlaku_sampai, 'sisa_hari', d.berlaku_sampai - tgl,
           'level', case when d.berlaku_sampai < tgl then 'expired' when d.berlaku_sampai - tgl <= 7 then 'h7' else 'h30' end) order by d.berlaku_sampai), '[]'::jsonb) into dok
    from dokumen d left join unit u on d.pemilik_tipe = 'unit' and u.id = d.pemilik_id left join karyawan k on d.pemilik_tipe = 'karyawan' and k.id = d.pemilik_id
   where d.berlaku_sampai - tgl <= 30 and coalesce(u.status, 'aktif') <> 'nonaktif' and coalesce(k.aktif, true);
  select coalesce(jsonb_agg(jsonb_build_object('kode', b.kode, 'nama', b.nama, 'saldo', s.saldo, 'minimum', b.stok_min) order by b.nama), '[]'::jsonb) into stok
    from barang b cross join lateral (select coalesce(sum(m.sisa), 0) as saldo from barang_masuk m where m.barang_id = b.id and m.status = 'aktif') s
   where b.aktif and b.stok_min > 0 and s.saldo <= b.stok_min;
  select coalesce(jsonb_agg(jsonb_build_object('unit', unit_kode, 'komponen', komponen, 'sisa_hm', sisa_hm, 'status', status) order by sisa_hm), '[]'::jsonb) into servis
    from v_status_perawatan where status in ('terlambat','segera');
  select coalesce(jsonb_agg(jsonb_build_object('nomor', nomor, 'pelanggan', pelanggan, 'jatuh_tempo', jatuh_tempo, 'sisa', sisa, 'hari_telat', hari_telat) order by jatuh_tempo), '[]'::jsonb) into faktur
    from v_faktur_saldo where status = 'disetujui' and sisa > 0.005 and jatuh_tempo <= tgl + 7;
  select count(*) into n_setuju from persetujuan where status = 'menunggu';
  select count(*) into n_lembur from lembur where status = 'usulan';
  select count(*) into hadir from absensi where tanggal = tgl and status = 'hadir';
  select count(*) into belum from karyawan k where k.aktif and not exists (select 1 from absensi a where a.karyawan_id = k.id and a.tanggal = tgl);
  return jsonb_build_object('dokumen', dok, 'stok_minimum', stok, 'servis', servis, 'faktur', faktur, 'persetujuan_menunggu', n_setuju, 'lembur_menunggu', n_lembur,
                            'hadir_hari_ini', hadir, 'belum_absen', belum);
end $$;
-- ---------- laporan tabel (hasil seragam: judul, kolom, baris) ----------
create or replace function lap_aging(p_jenis text, p_tgl date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  if p_jenis = 'AR' then
    return tabel_json('Umur Piutang Usaha', kol('nama:Pelanggan:t|belum:Belum jatuh tempo:n|b1:1-30 hari:n|b2:31-60 hari:n|b3:61-90 hari:n|b4:> 90 hari:n|total:Total:n'),
      format('select coalesce(pelanggan, ''TOTAL'') as nama,
                sum(case when %1$L::date - jatuh_tempo <= 0 then sisa else 0 end) as belum, sum(case when %1$L::date - jatuh_tempo between 1 and 30 then sisa else 0 end) as b1,
                sum(case when %1$L::date - jatuh_tempo between 31 and 60 then sisa else 0 end) as b2, sum(case when %1$L::date - jatuh_tempo between 61 and 90 then sisa else 0 end) as b3,
                sum(case when %1$L::date - jatuh_tempo > 90 then sisa else 0 end) as b4, sum(sisa) as total, case when pelanggan is null then ''t'' end as "_g"
              from v_faktur_saldo where status = ''disetujui'' and sisa > 0.005 and tanggal <= %1$L group by rollup(pelanggan) order by pelanggan nulls last', p_tgl));
  else
    return tabel_json('Umur Utang Usaha', kol('nama:Pemasok:t|belum:Belum jatuh tempo:n|b1:1-30 hari:n|b2:31-60 hari:n|b3:61-90 hari:n|b4:> 90 hari:n|total:Total:n'),
      format('select coalesce(pemasok, ''TOTAL'') as nama,
                sum(case when %1$L::date - jatuh_tempo <= 0 then sisa else 0 end) as belum, sum(case when %1$L::date - jatuh_tempo between 1 and 30 then sisa else 0 end) as b1,
                sum(case when %1$L::date - jatuh_tempo between 31 and 60 then sisa else 0 end) as b2, sum(case when %1$L::date - jatuh_tempo between 61 and 90 then sisa else 0 end) as b3,
                sum(case when %1$L::date - jatuh_tempo > 90 then sisa else 0 end) as b4, sum(sisa) as total, case when pemasok is null then ''t'' end as "_g"
              from v_tagihan_saldo where status = ''aktif'' and sisa > 0.005 and tanggal <= %1$L group by rollup(pemasok) order by pemasok nulls last', p_tgl));
  end if;
end $$;

create or replace function lap_aset(p_tgl date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Daftar Aset dan Penyusutan', kol('kode:Kode:t|nama:Nama aset:t|kategori:Kategori:t|metode:Metode:t|harga:Harga perolehan:n|akum:Akumulasi:n|buku:Nilai buku:n|beban_bulan:Beban bulan ini:n'),
    format('select a.kode, a.nama, a.kategori, a.metode, a.harga, coalesce(s.akum, 0) as akum, a.harga - coalesce(s.akum, 0) as buku, coalesce(b.beban, 0) as beban_bulan
              from aset a
              left join (select aset_id, sum(beban) as akum from v_penyusutan where akhir_bulan <= %1$L group by aset_id) s on s.aset_id = a.id
              left join (select aset_id, sum(beban) as beban from v_penyusutan where awal_bulan = date_trunc(''month'', %1$L::date)::date group by aset_id) b on b.aset_id = a.id
             where a.status <> ''dihapus'' order by a.kode', p_tgl));
end $$;

create or replace function lap_stok() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  return tabel_json('Stok Gudang', kol('kode:Kode:t|nama:Barang:t|kategori:Kategori:t|satuan:Satuan:t|saldo:Saldo fisik:n|harga:Harga rata-rata:n|nilai:Nilai persediaan:n|minimum:Stok minimum:n|status:Status:t'),
    'select b.kode, b.nama, b.kategori, b.satuan, s.saldo, case when s.saldo > 0 then round(s.nilai / s.saldo, 2) else 0 end as harga, s.nilai, b.stok_min as minimum,
            case when b.stok_min > 0 and s.saldo <= b.stok_min then ''Menipis'' else ''Aman'' end as status
       from barang b cross join lateral (select coalesce(sum(m.sisa), 0) as saldo, coalesce(sum(m.sisa * m.harga), 0) as nilai from barang_masuk m where m.barang_id = b.id and m.status = ''aktif'') s
      where b.aktif
     union all
     select ''BBM-SOLAR'', ''Solar (BBM)'', ''BBM'', ''Liter'', coalesce(sum(sisa), 0), case when sum(sisa) > 0 then round(sum(sisa * harga_per_liter) / sum(sisa), 2) else 0 end,
            coalesce(sum(sisa * harga_per_liter), 0), 0, ''Aman'' from bbm_masuk where status = ''aktif''
      order by 1');
end $$;

create or replace function lap_faktur() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Daftar Faktur Penagihan', kol('id:ID:n|nomor:No faktur:t|tanggal:Tanggal:d|pelanggan:Pelanggan:t|jatuh_tempo:Jatuh tempo:d|dpp:DPP:n|ppn:PPN:n|pph:PPh:n|total_kotor:Tagihan kotor:n|kontra_berlaku:Kontra bon:n|dibayar_kas:Dibayar kas:n|sisa:Sisa netto:n|status:Status:t|hari_telat:Hari telat:n'),
    'select id, nomor, tanggal, pelanggan, jatuh_tempo, dpp, ppn, pph, total_kotor, kontra_berlaku, dibayar_kas, sisa, status, hari_telat from v_faktur_saldo order by tanggal desc, id desc limit 500');
end $$;

create or replace function lap_tagihan() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Daftar Tagihan Pemasok', kol('id:ID:n|nomor:No tagihan:t|tanggal:Tanggal:d|pemasok:Pemasok:t|uraian:Uraian:t|jumlah:Jumlah:n|dibayar_kas:Dibayar kas:n|dibayar_kontra:Kontra bon:n|sisa:Sisa:n|jatuh_tempo:Jatuh tempo:d|status:Status:t'),
    'select id, nomor, tanggal, pemasok, uraian, jumlah, dibayar_kas, dibayar_kontra, sisa, jatuh_tempo, status from v_tagihan_saldo order by tanggal desc, id desc limit 500');
end $$;

create or replace function detail_faktur(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return jsonb_build_object(
    'faktur', (select to_jsonb(v) from v_faktur_saldo v where v.id = p_id),
    'pelanggan', (select to_jsonb(p) from pelanggan p join faktur f on f.pelanggan_id = p.id where f.id = p_id),
    'baris', (select coalesce(jsonb_agg(to_jsonb(b) order by b.id), '[]'::jsonb) from faktur_baris b where b.faktur_id = p_id),
    'kontra', (select coalesce(jsonb_agg(jsonb_build_object('pemasok', s.nama, 'nominal', k.nominal, 'keterangan', k.keterangan, 'status', k.status, 'tagihan_id', k.tagihan_id) order by k.id), '[]'::jsonb)
                 from kontra_bon k join pemasok s on s.id = k.pemasok_id where k.faktur_id = p_id and k.status <> 'batal'),
    'kop', (select coalesce(jsonb_object_agg(kunci, nilai), '{}'::jsonb) from pengaturan where kunci in ('nama_perusahaan','alamat_perusahaan')));
end $$;

create or replace function lap_produksi(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  return tabel_json('Daftar Produksi', kol('id:ID:n|tanggal_timbangan:Tgl timbangan:d|shift_timbangan:Shift:t|unit:Unit:t|driver:Driver:t|no_spb:No SPB:t|rute:Rute:t|ritase:Rit:n|tonase:Tonase:n|tonase_terima:Tonase terima:n|nominal:Nominal:n|premi:Premi:n|faktur:Faktur:t|status:Status:t'),
    format('select p.id, p.tanggal_timbangan, p.shift_timbangan, u.kode as unit, k.nama as driver, p.no_spb, s.nama || '': '' || p.loading || '' - '' || p.dumping as rute, p.ritase, p.tonase, p.tonase_terima,
              case when adalah(array[''admin'',''keuangan'',''manajemen'']) then p.nominal end as nominal, p.premi, f.nomor as faktur, case when p.perlu_cek then ''Cek tarif'' else p.status end as status
              from produksi p join unit u on u.id = p.unit_id join karyawan k on k.id = p.karyawan_id join site s on s.id = p.site_id left join faktur f on f.id = p.faktur_id
             where p.tanggal_timbangan between %L and %L order by p.tanggal_timbangan desc, p.id desc limit 2000', p_d1, p_d2));
end $$;

create or replace function lap_payroll(p_mulai date, p_akhir date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan']);
  return tabel_json('Rekap Payroll', kol('id:ID:n|nama:Nama:t|jabatan:Jabatan:t|hari_hadir:Hari hadir:n|gaji_pokok:Gaji pokok:n|premi_ritase:Premi ritase:n|premi_tonase:Premi tonase:n|uang_makan:Uang makan:n|pendapatan_kotor:Pendapatan kotor:n|pendapatan_tidak_tetap:Pendapatan tidak tetap:n|potongan_kasbon:Potongan kasbon:n|potongan_tidak_tetap:Potongan tidak tetap (total):n|thp:Take home pay:n|status_bayar:Pembayaran:t'),
    format('select pr.id, k.nama, k.jabatan, pr.hari_hadir, pr.gaji_pokok, pr.premi_ritase, pr.premi_tonase, pr.uang_makan, pr.pendapatan_kotor, pr.pendapatan_tidak_tetap, pr.potongan_kasbon, pr.potongan_tidak_tetap, pr.thp, pr.status_bayar
              from payroll pr join karyawan k on k.id = pr.karyawan_id where pr.status = ''aktif'' and pr.periode_mulai = %L and pr.periode_akhir = %L order by k.nama', p_mulai, p_akhir));
end $$;

create or replace function slip_gaji(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare pr payroll;
begin
  select * into pr from payroll where id = p_id;
  if not found then raise exception 'Payroll tidak ditemukan.'; end if;
  if not (adalah(array['admin','keuangan']) or pr.karyawan_id = karyawan_saya()) then raise exception 'Akses ditolak.'; end if;
  return jsonb_build_object('payroll', to_jsonb(pr),
    'karyawan', (select jsonb_build_object('nama', nama, 'jabatan', jabatan, 'bank', bank, 'no_rekening', no_rekening) from karyawan where id = pr.karyawan_id),
    'penyesuaian', (select coalesce(jsonb_agg(jsonb_build_object('tanggal', tanggal, 'jenis', jenis, 'kategori', kategori, 'keterangan', keterangan, 'nominal', nominal) order by tanggal, id), '[]'::jsonb)
                      from penyesuaian_gaji where karyawan_id = pr.karyawan_id and status = 'aktif' and tanggal between pr.periode_mulai and pr.periode_akhir),
    'kop', (select coalesce(jsonb_object_agg(kunci, nilai), '{}'::jsonb) from pengaturan where kunci in ('nama_perusahaan','alamat_perusahaan')));
end $$;

create or replace function lap_absensi(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  return tabel_json('Rekap Absensi', kol('nama:Nama:t|jabatan:Jabatan:t|hadir:Hadir:n|izin:Izin:n|sakit:Sakit:n|alpa:Alpa:n|cuti:Cuti:n|kali_telat:Kali telat:n|telat_menit:Total telat (menit):n|luar_radius:Di luar radius:n|lembur_jam:Lembur disetujui (jam):n'),
    format('select k.nama, k.jabatan, count(a.id) filter (where a.status = ''hadir'') as hadir, count(a.id) filter (where a.status = ''izin'') as izin, count(a.id) filter (where a.status = ''sakit'') as sakit,
              count(a.id) filter (where a.status = ''alpa'') as alpa, count(a.id) filter (where a.status = ''cuti'') as cuti, count(a.id) filter (where a.telat_menit > 0) as kali_telat,
              coalesce(sum(a.telat_menit), 0) as telat_menit, count(a.id) filter (where a.di_luar_radius) as luar_radius,
              coalesce((select sum(l.jam) from lembur l where l.karyawan_id = k.id and l.status = ''disetujui'' and l.tanggal between %1$L and %2$L), 0) as lembur_jam
              from karyawan k left join absensi a on a.karyawan_id = k.id and a.tanggal between %1$L and %2$L where k.aktif group by k.id, k.nama, k.jabatan order by k.nama', p_d1, p_d2));
end $$;

create or replace function lap_konsumsi_bbm(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor']);
  return tabel_json('Konsumsi BBM per Unit', kol('unit:Unit:t|liter:Liter:n|hm_pakai:HM terpakai:n|liter_per_hm:Liter/HM:n|normal_liter_per_hm:Normal (historis) Liter/HM:n|tonase:Tonase:n|liter_per_ton:Liter/ton:n|status:Status:t'),
    format('with pakai as (select unit_id, sum(liter) as liter, min(hm_awal) as hm0, max(hm_akhir) as hm1 from bbm_pakai where status = ''aktif'' and alokasi = ''unit'' and tanggal between %1$L and %2$L group by unit_id),
                 ton as (select unit_id, sum(tonase) as ton from produksi where status = ''aktif'' and tanggal_timbangan between %1$L and %2$L group by unit_id),
                 hist as (select unit_id, sum(liter) / nullif(sum(hm_akhir - hm_awal), 0) as lph from bbm_pakai where status = ''aktif'' and alokasi = ''unit'' and tanggal < %1$L and hm_akhir > hm_awal group by unit_id)
            select u.kode as unit, p.liter, p.hm1 - p.hm0 as hm_pakai, round(p.liter / nullif(p.hm1 - p.hm0, 0), 2) as liter_per_hm, round(h.lph, 2) as normal_liter_per_hm,
                   coalesce(t.ton, 0) as tonase, round(p.liter / nullif(t.ton, 0), 3) as liter_per_ton,
                   case when h.lph is not null and p.liter / nullif(p.hm1 - p.hm0, 0) > h.lph * 1.2 then ''Boros (>120%% normal)'' else ''Wajar'' end as status
              from pakai p join unit u on u.id = p.unit_id left join ton t on t.unit_id = p.unit_id left join hist h on h.unit_id = p.unit_id order by u.kode', p_d1, p_d2));
end $$;

create or replace function lap_perawatan() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen','supervisor','operator']);
  return tabel_json('Status Perawatan Unit', kol('unit:Unit:t|komponen:Komponen:t|interval_hm:Interval (HM):n|hm_terakhir_ganti:HM terakhir ganti:n|hm_sekarang:HM sekarang:n|sisa_hm:Sisa HM:n|status:Status:t'),
    'select unit_kode as unit, komponen, interval_hm, hm_terakhir_ganti, hm_sekarang, sisa_hm, status from v_status_perawatan order by case status when ''terlambat'' then 1 when ''segera'' then 2 else 3 end, sisa_hm');
end $$;

create or replace function lap_selisih_tonase(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform wajib_peran(array['admin','keuangan','manajemen']);
  return tabel_json('Selisih Tonase Timbangan vs Terima Pelanggan', kol('pelanggan:Pelanggan:t|rute:Rute:t|trip:Trip:n|timbang:Tonase timbangan:n|terima:Tonase terima:n|selisih:Selisih (susut):n|persen:Susut %:n|nilai:Nilai selisih (Rp):n'),
    format('select pl.nama as pelanggan, s.nama || '': '' || p.loading || '' - '' || p.dumping as rute, count(*) as trip, sum(p.tonase) as timbang, sum(p.tonase_terima) as terima,
              sum(p.tonase - p.tonase_terima) as selisih, round(sum(p.tonase - p.tonase_terima) / nullif(sum(p.tonase), 0) * 100, 2) as persen,
              round(sum((p.tonase - p.tonase_terima) * case when m.pakai_jarak then p.jarak_km else 1 end * p.tarif), 2) as nilai
              from produksi p join pelanggan pl on pl.id = p.pelanggan_id join site s on s.id = p.site_id join metode_tagihan m on m.id = p.metode_id
             where p.status = ''aktif'' and p.tonase_terima is not null and p.tanggal_timbangan between %L and %L group by pl.nama, s.nama, p.loading, p.dumping order by pl.nama, rute', p_d1, p_d2));
end $$;

-- laporan pribadi (operator hanya melihat datanya sendiri)
create or replace function saya_laporan(p_d1 date, p_d2 date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare kid bigint := karyawan_saya();
begin
  if peran_saya() is null then raise exception 'Akun belum aktif.'; end if;
  if kid is null then raise exception 'Akun Anda belum ditautkan ke data karyawan. Hubungi Admin.'; end if;
  return jsonb_build_object(
    'absensi', (select coalesce(jsonb_agg(jsonb_build_object('tanggal', tanggal, 'status', status, 'masuk', masuk_waktu, 'pulang', pulang_waktu, 'telat_menit', telat_menit, 'jam_kerja', jam_kerja, 'di_luar_radius', di_luar_radius) order by tanggal desc), '[]'::jsonb)
                  from absensi where karyawan_id = kid and tanggal between p_d1 and p_d2),
    'produksi', (select coalesce(jsonb_agg(jsonb_build_object('tanggal', p.tanggal_timbangan, 'no_spb', p.no_spb, 'rute', p.loading || ' - ' || p.dumping, 'ritase', p.ritase, 'tonase', p.tonase, 'premi', p.premi) order by p.tanggal_timbangan desc, p.id desc), '[]'::jsonb)
                   from produksi p where p.karyawan_id = kid and p.status = 'aktif' and p.tanggal_timbangan between p_d1 and p_d2),
    'lembur', (select coalesce(jsonb_agg(jsonb_build_object('tanggal', tanggal, 'jam', jam, 'nominal', nominal, 'status', status) order by tanggal desc), '[]'::jsonb) from lembur where karyawan_id = kid and tanggal between p_d1 and p_d2),
    'kasbon_saldo', (select coalesce(saldo, 0) from v_saldo_kasbon where karyawan_id = kid),
    'slip', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'periode_mulai', periode_mulai, 'periode_akhir', periode_akhir, 'thp', thp, 'status_bayar', status_bayar) order by periode_akhir desc), '[]'::jsonb)
               from payroll where karyawan_id = kid and status = 'aktif'),
    'perawatan', (select coalesce(jsonb_agg(jsonb_build_object('unit', unit_kode, 'komponen', komponen, 'sisa_hm', sisa_hm, 'status', status) order by sisa_hm), '[]'::jsonb)
                    from v_status_perawatan where status in ('terlambat','segera') and unit_id in (select unit_id from produksi where karyawan_id = kid and tanggal_timbangan >= p_d2 - 60)));
end $$;
-- ---------- 8. KEAMANAN: RLS per peran, hak akses fungsi, penyimpanan foto, audit ----------
-- hak akses dasar
revoke all on all tables in schema public from anon;
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all sequences in schema public from anon;
grant usage, select on all sequences in schema public to authenticated;

-- view tidak boleh dibaca langsung klien (hanya lewat fungsi laporan yang memeriksa peran)
revoke all on v_status_perawatan, v_saldo_kasbon, v_penyusutan, v_faktur_saldo, v_tagihan_saldo, v_pasangan, v_jurnal from anon, authenticated;

-- RLS aktif di semua tabel
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- tabel master dan konfigurasi: Admin boleh semua (tulis langsung dari layar Setting)
do $$
declare t text;
begin
  foreach t in array array['site','unit','dokumen','karyawan','karyawan_gaji','pelanggan','pemasok','metode_tagihan','tarif_rute','barang','komponen_perawatan',
                           'interval_perawatan','aturan_absensi','aturan_persetujuan','kategori_kas','akun','pemetaan_akun','aset','pengaturan','profil_pengguna'] loop
    execute format('create policy admin_semua on %I for all to authenticated using (adalah(array[''admin''])) with check (adalah(array[''admin'']))', t);
  end loop;
end $$;

-- hak baca: tabel, peran yang boleh membaca semua baris, kondisi tambahan untuk baris miliknya sendiri
do $$
declare r record;
begin
  for r in select * from (values
    ('site',               'admin,keuangan,manajemen,supervisor', null),
    ('unit',               'admin,keuangan,manajemen,supervisor', null),
    ('dokumen',            'admin,keuangan,manajemen,supervisor', null),
    ('karyawan',           'admin,keuangan,manajemen,supervisor', 'id = karyawan_saya()'),
    ('karyawan_gaji',      'admin,keuangan', null),
    ('pelanggan',          'admin,keuangan,manajemen', null),
    ('pemasok',            'admin,keuangan,manajemen', null),
    ('metode_tagihan',     'admin,keuangan,manajemen', null),
    ('tarif_rute',         'admin,keuangan,manajemen', null),
    ('barang',             'admin,keuangan,manajemen,supervisor', null),
    ('komponen_perawatan', 'admin,keuangan,manajemen,supervisor,operator', null),
    ('interval_perawatan', 'admin,keuangan,manajemen,supervisor,operator', null),
    ('aturan_absensi',     'admin,keuangan,manajemen,supervisor,operator', null),
    ('aturan_persetujuan', 'admin,keuangan', null),
    ('kategori_kas',       'admin,keuangan,manajemen', null),
    ('akun',               'admin,keuangan,manajemen', null),
    ('pemetaan_akun',      'admin,keuangan,manajemen', null),
    ('aset',               'admin,keuangan,manajemen', null),
    ('pengaturan',         'admin,keuangan,manajemen,supervisor,operator', null),
    ('profil_pengguna',    'admin,keuangan', 'id = auth.uid()'),
    ('periode_kunci',      'admin,keuangan,manajemen,supervisor,operator', null),
    ('produksi',           'admin,keuangan,manajemen,supervisor', 'dibuat_oleh = auth.uid() or karyawan_id = karyawan_saya()'),
    ('bbm_pakai',          'admin,keuangan,manajemen,supervisor', 'dibuat_oleh = auth.uid()'),
    ('perbaikan',          'admin,keuangan,manajemen,supervisor', 'dibuat_oleh = auth.uid()'),
    ('barang_keluar',      'admin,keuangan,manajemen,supervisor', 'dibuat_oleh = auth.uid()'),
    ('servis',             'admin,keuangan,manajemen,supervisor', 'dibuat_oleh = auth.uid()'),
    ('bbm_masuk',          'admin,keuangan,manajemen', null),
    ('barang_masuk',       'admin,keuangan,manajemen', null),
    ('pembelian_langsung', 'admin,keuangan,manajemen', null),
    ('buku_kas',           'admin,keuangan,manajemen', null),
    ('jurnal',             'admin,keuangan,manajemen', null),
    ('faktur',             'admin,keuangan,manajemen', null),
    ('kontra_bon',         'admin,keuangan,manajemen', null),
    ('tagihan_pemasok',    'admin,keuangan,manajemen', null),
    ('kasbon',             'admin,keuangan', 'karyawan_id = karyawan_saya()'),
    ('penyesuaian_gaji',   'admin,keuangan', 'karyawan_id = karyawan_saya()'),
    ('payroll',            'admin,keuangan', 'karyawan_id = karyawan_saya()'),
    ('absensi',            'admin,keuangan,manajemen,supervisor', 'karyawan_id = karyawan_saya()'),
    ('lembur',             'admin,keuangan,manajemen,supervisor', 'karyawan_id = karyawan_saya()'),
    ('persetujuan',        'admin,keuangan', 'diajukan_oleh = auth.uid()'),
    ('lampiran',           'admin,keuangan,manajemen,supervisor', 'dibuat_oleh = auth.uid()'),
    ('antrian_sinkron',    'admin', null),
    ('log_audit',          'admin', null)
  ) as v(tabel, peran, own) loop
    execute format('create policy baca_%s on %I for select to authenticated using (adalah(string_to_array(%L, '','')) %s)',
                   r.tabel, r.tabel, r.peran, case when r.own is null then '' else 'or (' || r.own || ')' end);
  end loop;
end $$;

-- tabel anak mengikuti hak baca tabel induknya (RLS induk berlaku untuk pemanggil)
create policy baca_perbaikan_item on perbaikan_item for select to authenticated using (exists (select 1 from perbaikan p where p.id = perbaikan_id));
create policy baca_servis_item on servis_item for select to authenticated using (exists (select 1 from servis s where s.id = servis_id));
create policy baca_jurnal_baris on jurnal_baris for select to authenticated using (exists (select 1 from jurnal j where j.id = jurnal_id));
create policy baca_faktur_baris on faktur_baris for select to authenticated using (exists (select 1 from faktur f where f.id = faktur_id));
-- fifo_konsumsi: tanpa policy (hanya fungsi database yang menyentuhnya)

-- foto: pengguna aktif boleh mencatat lampiran miliknya
create policy tambah_lampiran on lampiran for insert to authenticated with check (peran_saya() is not null and dibuat_oleh = auth.uid());

-- hak eksekusi: fungsi pembantu kebijakan dan fungsi API
grant execute on function peran_saya(), karyawan_saya(), adalah(text[]) to authenticated;
grant execute on function
  opsi_lapangan(), simpan_produksi(jsonb), simpan_bbm_pakai(jsonb), simpan_perbaikan(jsonb), simpan_pengeluaran(jsonb), simpan_servis(jsonb), simpan_pembelian(jsonb),
  simpan_kas(jsonb), simpan_kasbon(jsonb), simpan_penyesuaian(jsonb), hitung_payroll(date, date), bayar_payroll(bigint[], date, text), simpan_jurnal_manual(jsonb),
  buat_faktur(jsonb), setujui_faktur(bigint), batal_faktur(bigint), catat_pelunasan(bigint, date, numeric, text), simpan_tagihan(jsonb),
  proses_persetujuan(bigint, boolean, text), batalkan_transaksi(text, bigint, text), absen(jsonb), catat_absensi_admin(jsonb), proses_lembur(bigint, boolean, text),
  kunci_periode(date), lapor_gagal_sinkron(text, jsonb, text),
  lap_laba_rugi(date, date), lap_neraca(date), lap_jurnal(date, date), lap_buku_besar(text, date, date), lap_buku_kas(date, date), lap_aging(text, date), lap_aset(date),
  lap_stok(), lap_faktur(), lap_tagihan(), detail_faktur(bigint), lap_produksi(date, date), lap_payroll(date, date), slip_gaji(bigint), lap_absensi(date, date),
  lap_konsumsi_bbm(date, date), lap_perawatan(), lap_selisih_tonase(date, date), saya_laporan(date, date),
  dash_kas(date, date), dash_keuangan(date, date), dash_armada(date, date), dash_rute(date, date), peringatan()
  to authenticated;

-- penyimpanan foto (privat). Folder per pengguna: <id pengguna>/<tabel>/<nama berkas>
insert into storage.buckets (id, name, public) values ('lampiran', 'lampiran', false) on conflict (id) do nothing;
create policy lampiran_unggah on storage.objects for insert to authenticated
  with check (bucket_id = 'lampiran' and (storage.foldername(name))[1] = auth.uid()::text and peran_saya() is not null);
create policy lampiran_baca on storage.objects for select to authenticated
  using (bucket_id = 'lampiran' and ((storage.foldername(name))[1] = auth.uid()::text or adalah(array['admin','keuangan','manajemen','supervisor'])));

-- jejak audit pada tabel penting
do $$
declare t text;
begin
  foreach t in array array['unit','karyawan','karyawan_gaji','pelanggan','pemasok','tarif_rute','metode_tagihan','barang','aturan_absensi','aturan_persetujuan','akun','pemetaan_akun','aset',
                           'pengaturan','profil_pengguna','produksi','bbm_masuk','bbm_pakai','barang_masuk','barang_keluar','pembelian_langsung','perbaikan','buku_kas','jurnal','faktur',
                           'tagihan_pemasok','payroll','penyesuaian_gaji','kasbon','absensi','lembur','persetujuan','periode_kunci'] loop
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function audit_trg()', t, t);
  end loop;
end $$;
-- ---------- 9. DATA AWAL (bisa diubah Admin dari layar Setting) ----------
insert into metode_tagihan(kode, nama, dasar, pakai_jarak, aktif) values
  ('TON_KM', 'Tonase x jarak x tarif', 'tonase', true, true),
  ('RIT', 'Per ritase (rit x tarif)', 'ritase', false, false),
  ('TON', 'Per tonase (tanpa jarak)', 'tonase', false, false),
  ('M3', 'Per volume (m3 x tarif)', 'volume', false, false),
  ('JAM', 'Sewa per jam alat (HM)', 'hm', false, false),
  ('HARI', 'Sewa per hari', 'hari', false, false),
  ('BULAN', 'Sewa per bulan', 'bulan', false, false),
  ('TETAP', 'Borongan / tarif tetap', 'tetap', false, false);

insert into akun(kode, nama, kelompok, sub_kelompok, saldo_normal) values
  ('1-1100', 'Kas', 'Aset', 'Aset Lancar', 'debit'),
  ('1-1200', 'Bank', 'Aset', 'Aset Lancar', 'debit'),
  ('1-1300', 'Piutang Usaha', 'Aset', 'Aset Lancar', 'debit'),
  ('1-1400', 'Persediaan BBM', 'Aset', 'Aset Lancar', 'debit'),
  ('1-1410', 'Persediaan Suku Cadang dan Material', 'Aset', 'Aset Lancar', 'debit'),
  ('1-1500', 'Piutang Karyawan (Kasbon)', 'Aset', 'Aset Lancar', 'debit'),
  ('1-1600', 'PPh Dibayar Dimuka', 'Aset', 'Aset Lancar', 'debit'),
  ('1-2100', 'Aset Tetap (Kendaraan dan Alat Berat)', 'Aset', 'Aset Tetap', 'debit'),
  ('1-2200', 'Akumulasi Penyusutan', 'Aset', 'Aset Tetap', 'kredit'),
  ('2-1100', 'Utang Usaha', 'Liabilitas', 'Liabilitas Jangka Pendek', 'kredit'),
  ('2-1200', 'Utang Gaji', 'Liabilitas', 'Liabilitas Jangka Pendek', 'kredit'),
  ('2-1400', 'Utang PPN Keluaran', 'Liabilitas', 'Liabilitas Jangka Pendek', 'kredit'),
  ('3-1100', 'Modal Disetor', 'Ekuitas', 'Ekuitas', 'kredit'),
  ('3-1200', 'Laba Ditahan / Saldo Awal', 'Ekuitas', 'Ekuitas', 'kredit'),
  ('3-1300', 'Prive', 'Ekuitas', 'Ekuitas', 'debit'),
  ('4-1100', 'Pendapatan Jasa Hauling', 'Pendapatan', 'Pendapatan Usaha', 'kredit'),
  ('4-1200', 'Pendapatan Sewa Alat', 'Pendapatan', 'Pendapatan Usaha', 'kredit'),
  ('4-1300', 'Pendapatan Borongan dan Lainnya', 'Pendapatan', 'Pendapatan Usaha', 'kredit'),
  ('4-2100', 'Pendapatan Lain-lain', 'Pendapatan', 'Pendapatan Lain', 'kredit'),
  ('5-1100', 'Beban BBM', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1200', 'Beban Gaji Pokok', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1210', 'Beban Premi Driver', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1220', 'Beban Uang Makan', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1230', 'Beban Bonus, Lembur, dan Insentif', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1500', 'Beban Perbaikan dan Pemeliharaan', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1520', 'Beban Operasional Lapangan dan Bengkel', 'Beban', 'Beban Operasional', 'debit'),
  ('5-1700', 'Beban Umum dan Administrasi', 'Beban', 'Beban Umum', 'debit'),
  ('5-1800', 'Beban Penyusutan', 'Beban', 'Beban Penyusutan', 'debit'),
  ('5-1950', 'Beban Lain-lain', 'Beban', 'Beban Lain', 'debit');

insert into pemetaan_akun(kunci, keterangan, akun_debit, akun_kredit) values
  ('PRODUKSI', 'Pendapatan hauling dari produksi (piutang, pendapatan)', '1-1300', '4-1100'),
  ('BBM_MASUK', 'Pembelian BBM ke tangki', '1-1400', '2-1100'),
  ('BBM_PAKAI', 'BBM dipakai unit armada', '5-1100', '1-1400'),
  ('BBM_PAKAI|Lapangan', 'BBM untuk lapangan/bengkel', '5-1520', '1-1400'),
  ('BBM_PAKAI|Umum', 'BBM untuk umum, mess, kantor', '5-1700', '1-1400'),
  ('BBM_PAKAI|Lain', 'BBM lain-lain / non-operasional', '5-1950', '1-1400'),
  ('STOK_MASUK', 'Pembelian barang ke gudang', '1-1410', '2-1100'),
  ('STOK_KELUAR|Lapangan', 'Pengeluaran stok untuk lapangan/bengkel', '5-1520', '1-1410'),
  ('STOK_KELUAR|Umum', 'Pengeluaran stok untuk umum, mess, kantor', '5-1700', '1-1410'),
  ('STOK_KELUAR|Lain', 'Pengeluaran stok lain-lain / non-operasional', '5-1950', '1-1410'),
  ('PERBAIKAN', 'Perbaikan unit, barang dibeli langsung', '5-1500', '2-1100'),
  ('PERBAIKAN|Stok', 'Perbaikan unit, barang dari gudang', '5-1500', '1-1410'),
  ('BEBAN_LANGSUNG|Lapangan', 'Beban langsung lapangan/bengkel', '5-1520', '2-1100'),
  ('BEBAN_LANGSUNG|Umum', 'Beban langsung umum, mess, kantor', '5-1700', '2-1100'),
  ('BEBAN_LANGSUNG|Lain', 'Beban langsung lain-lain', '5-1950', '2-1100'),
  ('PAYROLL_GAJI', 'Gaji pokok', '5-1200', '2-1200'),
  ('PAYROLL_PREMI', 'Premi driver', '5-1210', '2-1200'),
  ('PAYROLL_MAKAN', 'Uang makan', '5-1220', '2-1200'),
  ('PAYROLL_BONUS', 'Pendapatan tidak tetap (bonus, insentif, lembur)', '5-1230', '2-1200'),
  ('PAYROLL_KASBON', 'Potongan kasbon', '2-1200', '1-1500'),
  ('PAYROLL_POTONGAN', 'Potongan denda/klaim/lain menjadi pendapatan lain', '2-1200', '4-2100'),
  ('PENYUSUTAN', 'Penyusutan aset', '5-1800', '1-2200'),
  ('FAKTUR_PPN', 'PPN keluaran faktur disetujui', '1-1300', '2-1400'),
  ('FAKTUR_PPH', 'PPh dipotong pelanggan', '1-1600', '1-1300'),
  ('FAKTUR_KONTRA', 'Kontra bon memotong piutang dan utang', '2-1100', '1-1300'),
  ('FAKTUR_MANUAL', 'Pendapatan dari baris manual faktur (sewa, borongan)', '1-1300', '4-1200'),
  ('TAGIHAN', 'Tagihan pemasok yang dijurnalkan', '5-1950', '2-1100'),
  ('KAS_MASUK|Pembayaran Hauling', 'Penerimaan pelunasan faktur', '1-1100', '1-1300'),
  ('KAS_MASUK|Setoran Modal', 'Setoran modal pemilik', '1-1100', '3-1100'),
  ('KAS_MASUK|Saldo Awal', 'Saldo awal kas/bank', '1-1100', '3-1200'),
  ('KAS_MASUK|*', 'Kas masuk lain (cadangan)', '1-1100', '4-2100'),
  ('KAS_KELUAR|Pembelian Stok Gudang', 'Pembayaran pembelian stok', '2-1100', '1-1100'),
  ('KAS_KELUAR|Beban Langsung', 'Pembayaran beban langsung', '2-1100', '1-1100'),
  ('KAS_KELUAR|Pembayaran Vendor', 'Pelunasan utang vendor', '2-1100', '1-1100'),
  ('KAS_KELUAR|Gaji', 'Pembayaran gaji netto', '2-1200', '1-1100'),
  ('KAS_KELUAR|Kasbon', 'Pencairan kasbon karyawan', '1-1500', '1-1100'),
  ('KAS_KELUAR|Operasional', 'Operasional site/harian', '5-1520', '1-1100'),
  ('KAS_KELUAR|Prive/Pribadi', 'Pengambilan pribadi pemilik', '3-1300', '1-1100'),
  ('KAS_KELUAR|Pembelian Aset', 'Pembelian aset tetap', '1-2100', '1-1100'),
  ('KAS_KELUAR|Pajak', 'Pembayaran pajak', '1-1600', '1-1100'),
  ('KAS_KELUAR|*', 'Kas keluar lain (cadangan)', '5-1950', '1-1100');

insert into kategori_kas(arah, nama, aktivitas) values
  ('masuk', 'Pembayaran Hauling', 'Operasional'), ('masuk', 'Setoran Modal', 'Non-Operasional'), ('masuk', 'Saldo Awal', 'Non-Operasional'), ('masuk', 'Lain-lain', 'Non-Operasional'),
  ('keluar', 'Pembelian Stok Gudang', 'Operasional'), ('keluar', 'Beban Langsung', 'Operasional'), ('keluar', 'Pembayaran Vendor', 'Operasional'), ('keluar', 'Gaji', 'Operasional'),
  ('keluar', 'Kasbon', 'Operasional'), ('keluar', 'Operasional', 'Operasional'), ('keluar', 'Pajak', 'Operasional'), ('keluar', 'Pembelian Aset', 'Investasi'),
  ('keluar', 'Prive/Pribadi', 'Pribadi'), ('keluar', 'Lain-lain', 'Non-Operasional');

-- contoh pengaturan persetujuan (Admin boleh ubah): non-Admin yang menginput di atas batas perlu persetujuan
insert into aturan_persetujuan(jenis, aktif, batas_nominal, penyetuju, keterangan) values
  ('pembelian', true, 5000000, 'admin', 'Pembelian stok dan beban langsung. Batas contoh Rp 5.000.000.'),
  ('kas_keluar', true, 5000000, 'admin', 'Kas keluar manual. Batas contoh Rp 5.000.000.'),
  ('jurnal_manual', true, 0, 'admin', 'Semua jurnal manual dari non-Admin.'),
  ('pembayaran_payroll', true, 0, 'admin', 'Semua pembayaran payroll dari non-Admin.');

-- jam shift awal; potongan dan lembur diisi Admin di Setting > Aturan Absensi
insert into aturan_absensi(nama, shift, jam_masuk, jam_pulang) values
  ('Umum - Shift 1', '1', '06:00', '18:00'),
  ('Umum - Shift 2', '2', '18:00', '06:00');

insert into komponen_perawatan(nama) values
  ('Oli mesin'), ('Filter oli'), ('Filter solar'), ('Filter solar pra-penyaring'), ('Filter udara'),
  ('Oli transmisi'), ('Oli gardan'), ('Oli hidrolik'), ('Filter hidrolik'), ('Grease');

insert into pengaturan(kunci, nilai, keterangan) values
  ('nama_perusahaan', '', 'Nama perusahaan untuk kop laporan'),
  ('alamat_perusahaan', '', 'Alamat untuk kop laporan'),
  ('mulai_pembukuan', '', 'Tanggal awal pembukuan (yyyy-mm-dd). Kosong = semua transaksi masuk laporan.');
