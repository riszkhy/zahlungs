# Desain — Promo potongan per produk/kategori (sub-proyek 1)

Tanggal: 2026-10-31 · Status: menunggu tinjauan
Branch: `feat/promo` (dari `master`)

## Tujuan

Admin bisa membuat **promo potongan** (persen atau rupiah) untuk produk atau
kategori tertentu, selama rentang tanggal, di semua cabang atau cabang
tertentu. Kasir tidak perlu mengetik apa pun: potongan muncul sendiri saat
barang masuk keranjang, dan struk serta laporan menunjukkan berapa yang dihemat
dan oleh promo apa.

Ini sub-proyek pertama dari program promo. Ia juga membangun **fondasi** yang
dipakai sub-proyek berikutnya: tabel promo, potongan yang tersimpan per baris
nota, dan mesin hitung promo di context. Urutan selanjutnya (spec terpisah):

2. Beli X gratis/potongan Y (termasuk harga paket/grosir).
3. Minimum belanja (potongan tingkat nota yang dibagi ke baris).
4. Kode voucher (dengan batas pemakaian).

Berhasil bila:

1. Potongan dihitung di server saat nota disimpan, dengan aturan yang sama
   seperti yang tampil di kasir; angka dari layar tidak pernah dipercaya.
2. Laporan omzet dan laba per produk/kategori memakai harga setelah promo, dan
   total potongan per promo terlihat.
3. Diskon manual kasir bisa dibatasi admin.

Di luar cakupan: beli X gratis Y, minimum belanja, voucher, promo jam/hari
tertentu, promo untuk Layanan (PPOB).

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Penyimpanan potongan | Per baris nota (`sale_items.discount` + promo), `unit_price` tetap harga normal |
| Promo bentrok | Satu promo per baris: potongan terbesar; seri → `id` promo terkecil |
| Barang konsinyasi | Tidak pernah kena promo |
| Diskon manual | Tetap ada; admin bisa membatasi kasir maks. N% dari subtotal; admin tanpa batas |
| Pengelola | Admin; promo berlaku di semua cabang atau cabang pilihan |
| Jadwal | Tanggal mulai–selesai (inklusif), tanggal lokal cabang |
| Pembulatan persen | Potongan dibulatkan ke bawah ke rupiah penuh |

## Data

### `promotions` (milik organisasi, ber-`organization_id`)

| Kolom | Isi |
| --- | --- |
| `name` | wajib, maks. 80 karakter |
| `kind` | `percent` atau `amount` |
| `value` | decimal(12,2) > 0; untuk `percent` ≤ 100 |
| `starts_on`, `ends_on` | date, wajib, `ends_on` ≥ `starts_on` |
| `all_stores` | bawaan true |
| `active` | bawaan true |

### `promotion_targets`

`promotion_id` (hapus berantai), `product_id` (nullable), `category_id`
(nullable); tepat satu dari keduanya terisi. Promo harus punya minimal satu
target.

### `promotion_stores`

`promotion_id` (hapus berantai), `store_id`. Dipakai bila `all_stores = false`;
minimal satu cabang. Cabang harus milik organisasi yang sama.

### `sale_items` (kolom baru)

| Kolom | Isi |
| --- | --- |
| `discount` | decimal(12,2), bawaan 0: potongan promo baris ini |
| `promotion_id` | nullable, `on_delete: :nilify_all` |
| `promotion_name` | salinan nama promo saat transaksi (nullable) |

`line_total` = `unit_price × quantity − discount` (≥ 0). Baris lama tetap
benar (discount 0).

### `organizations` (kolom baru)

`max_cashier_discount_percent` — decimal(5,2), nullable; null = tanpa batas
(perilaku sekarang). Hanya membatasi diskon manual nota oleh **kasir**.

## Aturan (context baru `Zahlungs.Promotions`)

- **Berlaku** pada tanggal `d` di cabang `s`: `active`, `starts_on ≤ d ≤
  ends_on`, dan (`all_stores` atau `s` ada di `promotion_stores`). `d` = tanggal
  lokal cabang (`LocalTime.today(store)`).
- **Cocok** untuk produk `p`: target `product_id = p.id` atau `category_id =
  p.category_id`, dan `p.consignment` false.
- **Potongan** satu baris (`unit_price`, `quantity`):
  - `percent`: `floor(unit_price × quantity × value / 100)` ke rupiah penuh;
  - `amount`: `value × quantity`;
  - keduanya dibatasi maks. `unit_price × quantity`.
- **Pemilihan:** dari promo yang cocok, potongan terbesar; seri → `id` terkecil.

Fungsi:

- `active_for(store, date)` — promo berlaku dengan target-nya (organisasi
  sekarang).
- `apply(lines, promotions)` — murni (tanpa DB). `lines`:
  `[%{product: %Product{}, quantity, unit_price}]`; hasil: setiap baris
  ditambah `discount`, `promotion_id`, `promotion_name` (0 / nil bila tidak ada).
- CRUD admin: `list_promotions/0` (dengan status: berjalan, terjadwal, selesai,
  nonaktif menurut tanggal lokal), `get_promotion!/1`, `create_promotion(user,
  attrs)`, `update_promotion(user, promotion, attrs)`, `set_active/3` — admin
  saja (`{:error, :unauthorized}`); attrs termasuk `product_ids`,
  `category_ids`, `store_ids`, semuanya dicek milik organisasi.
- `report(scope, from, to)` — per promo: nama, jumlah barang, total potongan,
  omzet setelah potongan (dari `sale_items` nota `completed` dalam rentang,
  toko scope / semua toko organisasi).

Batas diskon manual (`Organizations` / `Promotions`):
`set_cashier_discount_limit(user, percent | nil)` admin saja, 0–100;
`cashier_discount_limit(organization_id)`.

### Perubahan di `Sales.create_sale/3`

- Di dalam transaksi, setelah toko shift diketahui: `Promotions.active_for(store,
  LocalTime.today(store))` lalu `apply/2` pada baris keranjang; potongan,
  promo dan `line_total` bersih disimpan di `sale_items`. `subtotal` = Σ
  `line_total`. Validasi diskon manual (0 ≤ diskon ≤ subtotal) memakai subtotal
  bersih ini.
- Bila pelaku `role != "admin"` dan organisasi punya batas: diskon manual >
  `subtotal × batas / 100` → `{:error, :discount_over_limit}`.
- Piutang: utang = total setelah promo dan diskon. Stok, Tunda, retur, void
  tidak berubah.

## Layar

- **Kasir:** promo aktif dimuat untuk toko shift saat mount dan saat shift
  dibuka; keranjang dihitung ulang dengan `apply/2` setiap berubah. Baris
  berpromo: harga normal dicoret, label "Nama promo −10%" / "−Rp 2.000", potongan.
  Ringkasan: "Hemat promo Rp X". Diskon manual melebihi batas: pesan "Diskon
  maksimal N% dari subtotal." dan Complete Sale nonaktif.
- **Struk** (modal dan cetak): baris berpromo menampilkan nama promo dan
  potongan; total "Hemat promo".
- **Admin `/admin/promotions`:** daftar (nama, potongan, tanggal, cabang,
  status); form tambah/ubah (nama, jenis, nilai, mulai, selesai, semua cabang /
  pilih cabang, aktif, target produk — cari — dan/atau kategori); aktif/nonaktif;
  pengaturan "Batas diskon manual kasir (%)". Rute di `live_session` admin.
- **Laporan penjualan:** kartu "Potongan promo" dan tabel "Per promo".

## Tes

- `apply/2`: persen dibulatkan ke bawah; rupiah × qty dibatasi harga baris;
  terbesar menang, seri → id terkecil; produk lewat kategori; konsinyasi
  dilewati; tanpa promo → discount 0.
- `active_for/2`: tanggal mulai dan selesai inklusif memakai tanggal lokal
  cabang; nonaktif dan cabang lain tidak ikut; organisasi lain tidak terlihat.
- CRUD: kasir ditolak; target/cabang organisasi lain ditolak; tanpa target
  ditolak; `ends_on` < `starts_on` ditolak; persen > 100 ditolak.
- `create_sale`: menyimpan potongan, nama promo, `line_total` bersih; subtotal
  bersih; batas diskon kasir berlaku, admin tidak; piutang memakai total
  setelah promo; nota lama/produk tanpa promo tidak berubah.
- Laporan: potongan per promo dan kartu total.
- Layar (LiveDriver): keranjang menampilkan harga coret dan "Hemat promo";
  pesan batas diskon; admin membuat promo; kasir tidak bisa membuka
  `/admin/promotions` (`get/2`).
