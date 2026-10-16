# Desain — Layanan PPOB, Fase 0 (tanpa API)

Tanggal: 2026-10-16 · Status: disetujui untuk ditulis rencananya

## Tujuan

Toko bisa menjual **pulsa, paket data, token PLN, dan tagihan PLN** dan
mencatatnya di Zahlungs. Di Fase 0 kasir tetap mengerjakan isi ulangnya di
aplikasi penyedia (di luar Zahlungs); Zahlungs mencatat uangnya, hasilnya, dan
saldo deposit. Agregator masih dinegosiasikan, jadi belum ada API.

Berhasil bila:

- setiap transaksi layanan tercatat dengan nomor tujuannya dan hasilnya
  (berhasil atau gagal), dan struknya bisa memuat token/SN;
- kas laci di akhir shift tetap cocok, termasuk uang layanan;
- margin layanan terlihat terpisah dari penjualan barang;
- admin bisa mencocokkan **perkiraan saldo deposit** dengan saldo di aplikasi
  penyedia, sehingga penjualan yang tidak dicatat terlihat sebagai selisih.

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Integrasi | Tanpa API; kasir memproses di aplikasi penyedia |
| Layanan | Pulsa, paket data, token PLN, tagihan PLN |
| Uang pelanggan | Diterima **sebelum** transaksi diproses |
| Harga jual | Margin per produk, **rupiah atau persen** — hanya untuk layanan; produk barang tidak berubah |
| Keranjang | **Layar terpisah**; layanan tidak dicampur dengan barang dalam satu struk |
| Saldo deposit | Dicatat dan dicocokkan |
| Akun deposit | Bebas: admin membuat akun, tiap toko memilih satu akun |
| Alur kasir | Catat dulu (diproses), lalu tandai berhasil atau gagal |
| Penyimpanan | Konteks dan tabel sendiri; alur penjualan barang tidak disentuh |

## Aturan uang

### Harga

`margin(x)` = nilai rupiah, atau `x × persen / 100`. Hasil persen dibulatkan
**ke atas** ke rupiah penuh. Margin selalu ≥ 0.

| Kategori | Modal | Harga ke pelanggan |
| --- | --- | --- |
| Pulsa, paket data, token PLN | `modal` produk | `modal + margin(modal)` |
| Tagihan PLN | `tagihan + biaya penyedia` | `tagihan + margin(tagihan)` |

- Pulsa, paket data, dan token PLN bernominal tetap di katalog (mis. "Token
  PLN 50.000", modal 50.150, margin Rp 2.350 → harga 52.500).
- Tagihan PLN: `tagihan` diisi kasir per transaksi (> 0). `biaya penyedia`
  disimpan di kolom modal produk; margin di sini adalah **biaya admin** ke
  pelanggan (mis. Rp 3.000 tetap, atau persen dari tagihan).
- Yang diperoleh toko: `harga − modal`.
- Harga dan modal dihitung di konteks dari produk saat transaksi dicatat dan
  **disalin** ke transaksi; tidak pernah diambil dari browser. Mengubah
  produk tidak mengubah transaksi lama.

### Pembayaran

Cara bayar sama dengan penjualan barang: tunai, QRIS, kartu, transfer. Tunai:
uang diterima ≥ harga, kembalian = diterima − harga. Non-tunai: diterima =
harga, tanpa kembalian.

### Status transaksi

```
diproses ──► berhasil   (token/SN opsional)   final
        └──► gagal      (alasan wajib; uang dikembalikan ke pelanggan)   final
```

- Hanya transaksi `diproses` yang bisa ditandai. Penandaan mengunci baris
  (`FOR UPDATE`) dan memeriksa status di database, sehingga dua tab yang
  menekan Berhasil dan Gagal bersamaan tidak bisa sama-sama lolos.
- Membalik transaksi yang sudah berhasil tidak didukung di Fase 0
  (ditangani manual dengan pengeluaran kas).

### Kas shift

- Uang **tunai** dari layanan berstatus `diproses` dan `berhasil` masuk
  perkiraan kas laci. Yang `gagal` tidak (uangnya sudah dikembalikan).
- **Shift tidak bisa ditutup selama masih ada layanan `diproses` di shift
  itu.** Pemeriksaan dilakukan setelah baris shift dikunci. Mencatat layanan
  juga mengunci shift, jadi tidak ada layanan yang tercatat tepat saat shift
  ditutup.
- Karena itu tidak ada layanan yang berubah status setelah shiftnya ditutup.

### Deposit

- **Akun deposit** milik pemilik ("Pusat", "Konter cabang 2"). Tiap toko
  memilih satu akun aktif. **Toko tanpa akun deposit aktif belum bisa
  menjual layanan.** Akun tidak dihapus, hanya dinonaktifkan.
- Transaksi menyimpan akun deposit toko **saat dicatat**. Mengganti akun toko
  tidak memindahkan transaksi lama.
- **Catatan deposit:**
  - `isi ulang` (> 0). Sumbernya **kas laci**, yang juga menulis pengeluaran
    kas (kategori `deposit_topup`) di shift terbuka admin dalam satu
    transaksi database, atau **dari luar laci** (transfer dan sebagainya).
    Pilihan kas laci hanya tersedia bila admin sedang punya shift terbuka.
  - `koreksi` (≠ 0, alasan wajib).
- **Perkiraan saldo** akun = Σ isi ulang + Σ koreksi − Σ modal transaksi
  `diproses` dan `berhasil` di akun itu. Yang `diproses` dihitung karena
  penyedia sudah memotong saldo; yang `gagal` tidak, karena penyedia
  mengembalikannya.
- **Pencocokan:** admin memasukkan saldo dari aplikasi penyedia (≥ 0).
  Zahlungs menampilkan `selisih = saldo aplikasi − perkiraan`. Bila selisih
  ≠ 0, admin bisa menyimpannya sebagai koreksi (catatan otomatis "Pencocokan:
  saldo aplikasi Rp X" ditambah catatan admin bila ada). Setelah itu
  perkiraan sama dengan saldo aplikasi, dan pencocokan berikutnya hanya
  menunjukkan selisih baru.

## Data

Kolom uang `decimal(15, 2)`.

**`service_products`** (milik organisasi): `organization_id`, `name` (≤ 160),
`category` (`pulsa` | `paket_data` | `token_pln` | `tagihan_pln`),
`operator` (≤ 60, opsional), `cost` (≥ 0; untuk tagihan = biaya penyedia),
`margin_type` (`amount` | `percent`), `margin_value` (≥ 0), `active`,
`deleted_at`, timestamps. Untuk kategori bernominal tetap, `cost` > 0.

**`service_transactions`** (milik toko, tanpa `organization_id`): `store_id`,
`shift_id`, `user_id`, `service_product_id`, `deposit_account_id`, `code`
(`{kode toko}-LYN{yymmddHHMMSS}{4 hex}`, unik per toko), salinan `category`
dan `product_name`, `customer_ref`, `bill_amount` (hanya tagihan), `price`,
`cost`, `payment_method`, `amount_paid`, `change_due`, `status`
(`processing` | `success` | `failed`), `token_sn` (≤ 64), `failure_reason`
(≤ 255), `resolved_by_id`, `resolved_at`, timestamps.

- `customer_ref`: spasi, strip, titik, dan `+` dibuang; harus 6–20 angka.
- Indeks: unik `(store_id, code)`; `(shift_id, status)`;
  `(deposit_account_id, status)`.

**`deposit_accounts`** (milik organisasi): `organization_id`, `name` (≤ 80,
unik per organisasi), `active`, timestamps.

**`stores`**: tambah `deposit_account_id` (opsional).

**`deposit_entries`** (milik organisasi): `organization_id`,
`deposit_account_id`, `kind` (`topup` | `correction`), `amount`, `source`
(`drawer` | `outside`, hanya isi ulang), `note` (≤ 255, wajib untuk koreksi),
`cash_movement_id` (bila dari laci), `recorded_by_id`, timestamps.

**`cash_movements`**: kategori baru `deposit_topup` (keluar). Seperti
`refund`, kategori ini ditulis oleh konteks, tidak ditawarkan untuk input
manual.

## Layar

### Kasir — `/services` ("Layanan")

Tautan baru di bilah atas setelah Cashier dan di grup Kasir pada menu. Butuh
shift terbuka (bila belum ada, tampil ajakan membuka shift di Cashier) dan
akun deposit aktif di toko shift (bila belum ada, tampil pesan untuk admin).

1. Pilih kategori (chip), lalu produk (tile berisi nama dan harga). Untuk
   tagihan PLN muncul kolom **nominal tagihan**, dan harga dihitung langsung.
2. Isi **nomor tujuan**. Nomornya ditampilkan besar dan dikelompokkan
   ("0812 3456 7890") supaya pelanggan ikut memeriksa.
3. Pilih cara bayar; untuk tunai isi uang diterima, dan kembalian dihitung.
4. **Catat & terima uang** → transaksi `diproses`.
5. Daftar **"Sedang diproses"** (shift ini):
   - **Berhasil**: isi token/SN (opsional) → tautan struk.
   - **Gagal**: isi alasan → pesan "Kembalikan Rp X ke pelanggan".
6. Riwayat layanan shift ini (berhasil dan gagal) dengan tautan struk.

### Struk — `/services/:id/receipt`

Halaman cetak seperti struk barang: toko, kode, waktu (zona toko), produk,
nomor tujuan, **token/SN**, nominal tagihan (bila ada), harga, dibayar,
kembalian, status. Transaksi toko lain → 404.

### Tutup shift (layar Cashier)

- Ringkasan kas ditambah baris **"Layanan tunai"**.
- Bila masih ada yang `diproses`, penutupan ditolak: "Selesaikan dulu N
  layanan yang masih diproses", dengan tautan ke `/services`.

### Admin

- **`/admin/services`** — daftar dan form produk layanan. Pilih margin
  Rp atau %, dengan pratinjau harga langsung. Untuk tagihan PLN, labelnya
  "Biaya penyedia" dan "Biaya admin". Aktif/nonaktif; hapus lunak.
- **`/admin/deposits`** — daftar akun dengan perkiraan saldo; tambah atau
  ubah nama dan aktif; **Isi ulang** (sumber: kas laci shift saya / dari luar
  laci); **Cocokkan**; riwayat catatan per akun.
- **Form toko** — pilihan akun deposit (hanya akun aktif).
- **`/reports/services`** — per periode dan toko (pemilih toko di bilah
  atas): jumlah berhasil, nilai transaksi, modal, margin, rincian per
  kategori, dan jumlah gagal.

Laporan penjualan barang dan angka di Home **tidak berubah** dan tidak memuat
layanan. Laporan penjualan diberi catatan "Layanan ada di Laporan layanan".

## Hak akses

| Tindakan | Siapa |
| --- | --- |
| Mencatat layanan | Pengguna dengan shift terbuka, di toko shiftnya |
| Menandai berhasil / gagal | Yang mencatat, atau admin (diperiksa ulang di event handler dan konteks) |
| Produk layanan, akun deposit, isi ulang, koreksi, laporan layanan | Admin |
| Struk | Siapa pun yang login di toko itu |

## Keamanan data

- `service_products`, `deposit_accounts`, dan `deposit_entries` membawa
  `organization_id`, jadi dijaga `Zahlungs.Repo`.
- `service_transactions` milik toko: disaring dengan `Scope.store_id/1`, dan
  untuk "semua toko" dengan `Stores.store_ids/0`. Mengambil transaksi toko
  lain menghasilkan `Ecto.NoResultsError` (404).
- Toko transaksi adalah **toko shift kasir**, tidak pernah dari parameter.
- Akun deposit diambil dari toko shift, bukan dari parameter.

## Bentuk kode

- **`Zahlungs.Services`** — produk layanan (CRUD, `price_for/2`), transaksi
  (`record/3`, `mark_success/3`, `mark_failed/3`, daftar per shift,
  `get_transaction!/2`), dan laporan layanan.
- **`Zahlungs.Deposits`** — akun, catatan (isi ulang, koreksi), perkiraan
  saldo, pencocokan.
- **`Zahlungs.Shifts`** — `expected_cash/1` dan `shift_summary/1` ditambah kas
  layanan; `close_shift/3` mengembalikan `{:error, :services_processing}`
  bila masih ada yang diproses.
- Web: `ServiceLive.Index` (kasir), `ServiceProductLive.Index`,
  `DepositLive.Index`, `ReportLive.Services`, `ServiceReceiptController`.

## Pengujian

TDD. Konteks:

- harga (Rp, %, pembulatan ke atas, tagihan);
- transisi status, termasuk yang ditolak (menandai dua kali, menandai yang
  sudah final);
- hak menandai;
- kas shift: diproses dan berhasil dihitung, gagal tidak, non-tunai tidak;
- tutup shift ditolak selama ada yang diproses;
- toko tanpa akun deposit ditolak;
- perkiraan saldo, isi ulang dari laci (sekaligus pengeluaran kas) dan dari
  luar, koreksi, pencocokan;
- isolasi antar pemilik dan antar toko.

Layar: akses lewat `get/2`, perilaku lewat `ZahlungsWeb.LiveDriver`.
Mutation check pada aturan uang yang paling penting (kas shift, perkiraan
saldo, penolakan tutup shift).

## Tidak termasuk Fase 0

- API agregator, callback, sinkron daftar harga.
- Barang dan layanan dalam satu struk.
- Membalik transaksi yang sudah berhasil.
- Notifikasi saldo menipis, layanan di angka Home.
- E-wallet, voucher game, dan tagihan selain PLN.
- Isi ulang deposit oleh kasir (hanya admin).
