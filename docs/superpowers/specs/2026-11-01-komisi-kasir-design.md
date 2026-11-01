# Desain — Komisi Kasir untuk Transaksi Layanan

Tanggal: 2026-11-01 · Status: menunggu tinjauan
Branch: `feat/komisi-kasir` (dari `master`)

## Tujuan

Kasir mendapat **komisi dari setiap transaksi layanan (PPOB) yang sukses**,
sebesar persen dari margin transaksi itu. Pemilik melihat berapa komisi tiap
kasir dalam satu periode untuk dibayarkan di luar aplikasi (mis. bersama
gaji); kasir melihat komisinya sendiri.

Berhasil bila:

1. Komisi satu periode per kasir sama persis dengan jumlah komisi transaksi
   rinciannya, dan tidak berubah ketika admin mengubah persen sesudahnya.
2. Transaksi yang tidak sukses (diproses, gagal, dikembalikan, dibatalkan
   lewat review) tidak pernah menghasilkan komisi, apa pun jalur yang
   mengubah statusnya.
3. Kasir tidak bisa melihat komisi kasir lain, dan admin tidak mendapat
   komisi.

Di luar cakupan: komisi penjualan barang, pencatatan pembayaran komisi (atau
kas keluar dari laci), persen per cabang atau per produk, export Excel komisi,
grafik.

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Transaksi | Hanya transaksi layanan (`service_transactions`), bukan penjualan barang |
| Bentuk | Persen dari margin (harga − modal) |
| Aturan | Satu persen per kategori: Pulsa, Paket data, Token PLN, Tagihan; belum diisi = 0% |
| Cabang | Satu tabel untuk seluruh organisasi |
| Penerima | Hanya pengguna berperan `cashier` saat transaksi dicatat |
| Status | Hanya `success` yang berkomisi |
| Riwayat | Persen disalin ke transaksi saat dicatat; perubahan aturan berlaku untuk transaksi berikutnya |
| Modal | Modal akhir transaksi (di akun API: biaya aktual vendor) |
| Pembulatan | Ke bawah ke rupiah penuh, per transaksi; margin minus = 0 |
| Pembayaran | Hanya laporan; dibayar di luar aplikasi |
| Siapa melihat | Admin: semua kasir; kasir: komisinya sendiri |
| Penyimpanan nominal | Tidak disimpan; dihitung saat dibaca dari status, harga, modal dan persen salinan |

Alasan nominal tidak disimpan: status transaksi API berubah di banyak jalur
(dispatcher, pengecek status, callback, `mark_success`/`mark_failed`,
`resolve_review/3`), dan modal bisa diganti biaya aktual vendor. Menghitung
dari status dan angka akhir membuat semua jalur itu benar tanpa disentuh.

## Data

Satu migrasi.

### `service_commission_rates` (milik organisasi, ber-`organization_id`, dijaga `Repo`)

| Kolom | Tipe | Catatan |
| --- | --- | --- |
| `organization_id` | FK | diisi `Organizations.put_organization/1` di changeset |
| `category` | string | salah satu `Services.categories/0` |
| `percent` | decimal(5,2) | 0–100, wajib |
| timestamps | | |

Indeks unik `(organization_id, category)`. Kategori yang tidak punya baris
bernilai 0%.

### `service_transactions` (kolom baru)

| Kolom | Tipe | Catatan |
| --- | --- | --- |
| `commission_percent` | decimal(5,2) | wajib, bawaan 0; transaksi lama mendapat 0 |

## Aturan (di `Zahlungs.Services`)

### Persen per kategori

- `commission_rates/0` → daftar `%{category, label, percent}` untuk semua
  kategori dalam urutan `categories/0`, 0 untuk yang belum ada barisnya.
- `save_commission_rates(%User{role: "admin"}, %{"pulsa" => "10", ...})` →
  `{:ok, rates}` atau `{:error, changeset_or_reason}`. Semua kategori dalam
  satu transaksi (upsert per kategori); satu nilai tidak sah (kosong
  dianggap 0, bukan angka, < 0, > 100, lebih dari 2 desimal) membatalkan
  semuanya. Selain admin → `{:error, :unauthorized}`. Kategori yang tidak
  dikenal diabaikan.
- `commission_percent(category)` → persen kategori itu (0 bila tidak ada).

### Saat dicatat (`record/3`)

Di dalam transaksi `record/3`, setelah shift dikunci:

- Peran pencatat dibaca ulang dari database (bukan dari struct `%User{}` yang
  dibawa LiveView). Bila `cashier` → `commission_percent` =
  `commission_percent(product.category)`; selain itu → 0.
- `commission_percent` tidak pernah diambil dari `attrs`/params (tidak ada di
  `cast`).

### Hitungan

```
komisi = FLOOR(GREATEST(price − cost, 0) × commission_percent / 100)   bila status = "success"
       = 0                                                               selain itu
```

- `commission(%Transaction{})` → `Decimal` rupiah penuh, dengan rumus di atas.
- Laporan memakai ekspresi SQL yang sama
  (`FLOOR(GREATEST(t.price - t.cost, 0) * t.commission_percent / 100)`,
  dijumlah per kasir), sehingga total = jumlah rincian.
- Akibat yang diinginkan: sukses → `failed` lewat review (`:refund`)
  menghilangkan komisi; gagal → `success` lewat review (`:success`)
  memberinya; biaya aktual vendor yang lebih tinggi mengecilkannya.
- Tagihan: margin = (biaya admin − biaya penyedia) × bulan, sudah tercermin di
  `price − cost` transaksi.

### Komisi shift

- `shift_commission(%Shift{})` → jumlah komisi transaksi sukses shift itu
  (yang dicatat pemilik shift; transaksi di shift selalu milik pemiliknya).

### Laporan

`commission_report(%Scope{}, date_from, date_to)` →

```
%{
  rows: [%{user_id, name, count, margin, commission}],   # urut nama
  count, margin, commission                               # total
}
```

- Periode menurut `inserted_at` transaksi, lewat `LocalTime.day_range/3`
  dengan toko scope (sama seperti `report/3`).
- Toko: `for_store(Transaction, scope)` (toko scope; "Semua cabang" = toko
  organisasi admin, `Stores.store_ids/0`).
- Hanya transaksi `success` dengan `commission_percent > 0`. `margin` = jumlah
  `GREATEST(price − cost, 0)` transaksi itu.
- Scope kasir: dibatasi `t.user_id == scope.user.id`, selalu.
- Pengguna nonaktif tetap muncul bila punya komisi di periode itu.

`commission_details(%Scope{}, user_id, date_from, date_to)` → daftar transaksi
sukses berkomisi seorang kasir (waktu lokal, kode, produk, kategori, margin,
persen, komisi), terbaru dulu. Scope kasir: `user_id` diabaikan, selalu
dirinya sendiri.

`report/3` (Laporan Layanan) menambah `commission` (total komisi transaksi
sukses periode itu) dan `net_margin` = `margin − commission`.

## Layar

### Admin — persen komisi (`/admin/services/commission`, `ServiceCommissionLive`)

- Rute di `live_session` admin. Tombol "Komisi kasir" di header Produk layanan.
- Satu form: baris per kategori (label + input persen, step 0.01, 0–100) dan
  tombol Simpan; keterangan "Komisi = persen × margin (harga − modal) transaksi
  sukses yang dicatat kasir. Perubahan berlaku untuk transaksi berikutnya."
- Simpan sukses → flash "Persen komisi disimpan."; gagal → pesan per baris, tidak
  ada yang tersimpan.

### Admin — laporan (`/reports/commissions`, `ReportLive.Commissions`)

- Rute di `live_session` admin; masuk menu Laporan sebagai "Komisi kasir".
- Filter tanggal dari–sampai (bawaan: tanggal 1 bulan ini sampai hari ini,
  tanggal lokal toko).
- Tabel per kasir (nama, transaksi, margin, komisi) + baris total. Klik nama
  → rincian transaksi kasir itu di bawah tabel (event dengan `user_id`,
  integer atau string).

### Kasir — komisi saya (`/commissions`, `CommissionLive`)

- Rute di `live_session` terautentikasi. Menu "Komisi saya" untuk kasir.
- Admin yang membukanya dialihkan ke `/reports/commissions`.
- Filter tanggal yang sama; total (transaksi, margin, komisi) dan rincian
  transaksinya sendiri.

### Layar Layanan (`ServiceLive.Index`)

- Untuk kasir dengan shift terbuka: baris "Komisi shift ini: Rp X"
  (`shift_commission/1`), dimuat ulang saat transaksi dicatat dan saat siaran
  `"services:store:<id>"` datang. Admin tidak melihatnya.
- Komisi tidak tampil di struk dan tidak masuk `Shifts.expected_cash/1`.

### Laporan Layanan (`/reports/services`)

- Kartu tambahan "Komisi kasir" dan "Margin bersih".

## Dokumen

- `docs/IA.md`: tiga rute baru dan siapa yang boleh melihatnya.
- `CLAUDE.md`: tabel `service_commission_rates`, kolom `commission_percent`,
  aturan komisi di bagian PPOB.

## Tes

Persen:
- kategori tanpa baris = 0%; simpan lalu baca kembali per kategori;
- satu nilai tidak sah (−1, 101, "abc", 3 desimal) → error, tidak ada yang
  berubah; kosong = 0;
- kasir → `{:error, :unauthorized}`;
- persen organisasi lain tidak terbaca (`in_org/2`).

Pencatatan:
- kasir → persen kategori produk tersalin; admin → 0;
- peran dibaca dari database: struct `%User{role: "cashier"}` milik pengguna
  yang sudah dijadikan admin → 0;
- `"commission_percent"` di attrs diabaikan;
- persen diubah sesudah transaksi dicatat → transaksi lama tetap persen lama.

Hitungan:
- sukses: 10% × margin 1.850 = 185; 12,5% × margin 1.999 = 249 (dibulatkan ke
  bawah);
- `processing` dan `failed` → 0; margin minus → 0;
- akun API: biaya aktual vendor lebih tinggi → komisi dari modal baru;
- review `:refund` atas sukses → 0; review `:success` atas gagal → berkomisi;
- tagihan 3 bulan → komisi dari margin 3 bulan.

Laporan:
- total per kasir = jumlah `commission/1` rinciannya;
- dua kasir, satu admin: admin tidak ada di baris;
- scope kasir hanya berisi dirinya; `commission_details` dengan `user_id`
  kasir lain tetap mengembalikan miliknya;
- "Semua cabang" tidak memuat transaksi organisasi lain;
- batas periode menurut waktu lokal toko;
- `report/3` memuat `commission` dan `net_margin`.

Halaman (`get/2` untuk akses, `LiveDriver` untuk perilaku):
- `/admin/services/commission` dan `/reports/commissions` → kasir dialihkan;
- `/commissions` → kasir 200, admin dialihkan ke `/reports/commissions`;
- form persen menyimpan dan menampilkan galat;
- laporan admin: ganti tanggal, klik kasir memunculkan rinciannya;
- layar Layanan kasir menampilkan "Komisi shift ini", admin tidak.
