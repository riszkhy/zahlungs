# Desain — Kasir tahan putus koneksi (opsi A)

Tanggal: 2026-10-15 · Status: menunggu tinjauan

## Tujuan

Kasir tidak dirugikan saat koneksi ke server putus sebentar (beberapa detik
sampai beberapa menit), saat halaman tidak sengaja dimuat ulang, atau saat
tablet dinyalakan ulang di tengah transaksi.

Berhasil bila:

1. Putus koneksi atau muat ulang **tidak menghilangkan keranjang**: barang,
   jumlah, diskon, pajak, uang diterima dan metode bayar kembali seperti
   semula.
2. Kasir **langsung tahu** sedang offline, dan tombol bayar tampak terkunci
   selama itu.
3. **Satu keranjang tidak pernah tercatat sebagai dua penjualan**, walau
   "Complete Sale" ditekan lagi setelah koneksi kembali.
4. Semua aturan di server tetap utuh: stok tidak bisa terjual melebihi
   persediaan, penjualan butuh shift terbuka, diskon/pajak divalidasi server.

Di luar cakupan (opsi B, direncanakan terpisah): menambah barang atau
mencatat penjualan **selama** offline. Selama koneksi putus, layar kasir hanya
menunggu.

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Cakupan | Opsi A sekarang; opsi B (kasir tunai offline) menyusul terpisah |
| Tempat cadangan keranjang | Salinan di browser (`localStorage`), server tetap pemegang kebenaran |
| Pencegah transaksi ganda | Kunci unik per keranjang, disimpan di `sales.client_ref` |
| Opsi D (koneksi cadangan) | Dianjurkan ke pemilik toko lewat `docs/DEPLOYMENT.md`, bukan perangkat lunak |

## Masalah di kode sekarang

- Keranjang hanya hidup di proses LiveView `ZahlungsWeb.CashierLive`
  (`assigns.cart`). Setelah koneksi putus, browser tersambung ke **proses
  baru** yang `mount/3`-nya memulai dengan keranjang kosong.
- Tidak ada penanda koneksi putus. Klik selama offline tidak terkirim, tapi
  tombol tampak normal.
- `Sales.create_sale/3` tidak bisa mengenali pengiriman ulang dari keranjang
  yang sama. Bila jawaban "berhasil" hilang di jalan dan kasir menekan lagi,
  tercatat dua penjualan (stok terpotong dua kali).

## Alur

```
Kasir mengubah keranjang
  → server menghitung ulang (seperti sekarang)
  → server push "cart_saved" {salinan}         → hook CartKeeper → localStorage

Koneksi putus
  → LiveView menandai halaman (class phx-client-error)
  → pita "Koneksi terputus", tombol bayar/tambah tampak terkunci

Koneksi kembali / halaman dimuat ulang
  → proses LiveView baru, keranjang kosong
  → hook CartKeeper (mounted/reconnected) push "restore_cart" {salinan}
  → server:
      kunci sudah tercatat?   → tampilkan penjualannya ("sudah tercatat"), hapus salinan
      shift berbeda/tak ada?  → abaikan, hapus salinan
      selain itu              → susun ulang keranjang dari database, beri tahu perubahannya

"Complete Sale"
  → create_sale(user, cart, %{... client_ref: kunci})
      kunci belum dipakai → penjualan baru (seperti sekarang)
      kunci sudah dipakai → {:error, {:already_recorded, sale}}, tidak ada perubahan
```

## Komponen

### 1. Salinan keranjang (server → tablet)

Setiap event yang mengubah keranjang atau pembayaran (`scan`, `add`, `inc`,
`dec`, `remove`, `payment`, `set_amount_paid`, `set_payment_method`,
`quick_cash`) diakhiri dengan push event `cart_saved`. Isinya:

```json
{
  "v": 1,
  "user_id": 12,
  "shift_id": 345,
  "key": "8f0c…-uuid",
  "items": [[101, 2, "5000"], [205, 1, "12500"]],
  "discount": "",
  "tax": "",
  "amount_paid": "50000",
  "payment_method": "cash"
}
```

- Tiap item: ID barang, jumlah, dan harga satuan yang dilihat kasir. Harga itu
  **hanya** dipakai untuk mendeteksi bahwa harga berubah selama putus; yang
  ditagih selalu harga dari database. Tidak ada nama barang atau harga beli di
  salinan.
- Saat penjualan tercatat, saat "Transaksi baru" ditekan, atau saat keranjang
  menjadi kosong, server push `cart_saved` dengan `items: []`, dan hook
  **menghapus** slotnya.
- `mount/3` tidak push apa pun, dan push `cart_saved` baru dimulai setelah
  `restore_cart` diterima (lihat komponen 3).

### 2. Hook `CartKeeper` (`assets/js/app.js`)

Satu elemen tersembunyi di layar kasir dengan `phx-hook="CartKeeper"` dan
`data-user-id`.

- Slot: `zahlungs:cart:<user_id>`, jadi tablet yang dipakai bergantian oleh
  beberapa kasir tidak tercampur.
- `handleEvent("cart_saved")`: simpan, atau hapus slot bila `items` kosong.
- `mounted()` dan `reconnected()`: selalu `pushEvent("restore_cart", {cart:
  salinan})`, dengan `cart: null` bila slot kosong.
- Hook `CurrencyInput` tidak lagi mengirim `set_amount_paid` saat terpasang
  (hanya saat kasir mengetik). Kalau tetap mengirim, nilai kosongnya tiba
  setelah `restore_cart` dan menghapus uang diterima yang baru dipulihkan.
- Semua akses `localStorage` dibungkus `try/catch`. Bila penyimpanan tidak
  tersedia (mode privat, penyimpanan penuh), layar kasir berjalan seperti
  sekarang, hanya tanpa pemulihan.

### 3. Pemulihan (`CashierLive.handle_event("restore_cart", …)`)

Salinan dari tablet adalah **data yang tidak dipercaya**: hanya ID, jumlah dan
angka yang dibaca, dan semuanya diperiksa ulang. Salinan yang bentuknya tidak
sesuai (bukan daftar, ID atau jumlah bukan bilangan bulat positif, harga bukan
angka) diabaikan seluruhnya.

Hook selalu mengirim `restore_cart` saat terpasang, dengan `null` bila slot
kosong. Sampai pesan itu diterima, server **tidak** mengirim `cart_saved`,
supaya keranjang kosong milik proses baru tidak menghapus salinan sebelum
sempat dipulihkan.

Urutan:

1. Abaikan bila belum ada shift terbuka, keranjang di server sudah berisi
   (layar yang masih tersambung tidak boleh tertimpa), `user_id` bukan kasir
   ini, atau `v` tidak dikenal.
2. Bila `key` adalah UUID yang **sudah tercatat** di toko shift ini
   (`Sales.get_sale_by_client_ref/2`): tampilkan penjualan itu sebagai struk
   terakhir dengan pesan *"Penjualan INV… sudah tercatat. Jangan terima
   pembayaran lagi."*, lalu push `cart_saved` kosong. Ini menangani kasus
   "jawaban berhasil hilang di jalan", termasuk bila barang terakhir sudah
   habis oleh penjualan itu sendiri.
3. Bila `shift_id` bukan shift yang sedang buka: abaikan dan push `cart_saved`
   kosong.
4. Selain itu, susun ulang keranjang lewat `Catalog` dengan `@sale_scope`
   (toko shift):
   - harga dari database;
   - barang nonaktif, terhapus, tidak ditemukan atau stoknya 0 dibuang;
   - jumlah dipotong ke stok yang ada (aturan yang sama dengan `update_qty`);
   - diskon, pajak, uang diterima dan metode bayar diambil apa adanya lalu
     dihitung lewat `assign_totals/1` (validasi yang sama seperti sekarang);
     metode bayar yang tidak dikenal menjadi `cash`;
   - kunci dipakai bila berupa UUID yang valid, selain itu dibuatkan baru;
   - uang diterima didorong ke input lewat `set_amount_paid_input` (input itu
     dikuasai hook `CurrencyInput`).
5. Pesan: *"Keranjang dipulihkan."*, ditambah daftar perubahan bila ada
   (*"Harga Molto berubah"*, *"Rinso dihapus: stok habis"*, *"Jumlah Pantene
   dikurangi ke 3 (sisa stok)"*).
6. Push `cart_saved` dengan hasil susunan ulang, supaya salinan di tablet
   ikut bersih.

### 4. Penanda offline

- **Semua halaman LiveView**: pita kecil *"Koneksi terputus — menyambung
  ulang…"* yang hanya tampil saat elemen LiveView ber-class
  `phx-client-error` atau `phx-server-error`. Dibuat dengan CSS biasa di
  `assets/css/app.css`, tanpa JS tambahan dan tanpa mengubah konfigurasi
  Tailwind.
- **Layar kasir**: pesan yang lebih spesifik, *"Keranjang aman di tablet ini.
  Tunggu tersambung sebelum menerima pembayaran."* Tombol **Complete Sale**,
  uang cepat, petak barang dan tombol jumlah tampak terkunci (redup, tidak
  bisa diklik) selama offline.

### 5. Kunci keranjang dan `create_sale`

**Migrasi** (satu, kecil):

- `sales.client_ref` — `string(36)`, boleh kosong.
- Indeks unik `(store_id, client_ref)`. MySQL mengizinkan banyak `NULL` di
  indeks unik, jadi penjualan lama dan penjualan tanpa kunci tidak terganggu.

**`Zahlungs.Sales`**:

- `create_sale/3`: `payment` menerima `:client_ref` opsional (UUID).
  - Pemeriksaan **di dalam transaksi**, tepat setelah shift dikunci
    (`Shifts.lock_current_shift/1`) dan sebelum penjualan disisipkan: bila
    sudah ada penjualan dengan `(store_id, client_ref)` itu, transaksi
    berhenti dengan `{:error, {:already_recorded, sale}}`. Stok tidak
    disentuh.
  - Dua klik yang hampir bersamaan dari kasir yang sama antre di kunci baris
    shift; yang kedua menemukan penjualan yang pertama. Indeks unik adalah
    pengaman terakhir: pelanggaran indeks itu juga dikembalikan sebagai
    `{:already_recorded, sale}`.
  - Tanpa `client_ref`, perilaku tidak berubah sama sekali.
- `get_sale_by_client_ref(scope, key)` — penjualan dengan kunci itu di toko
  scope, atau `nil`. Untuk pemulihan (komponen 3).
- Hasil "sudah tercatat" sengaja berupa `{:error, ...}`, bukan `{:ok, sale}`,
  supaya pemanggil tidak salah menganggapnya penjualan baru.

**`CashierLive`**:

- `reset_cart/1` membuat kunci baru (`Ecto.UUID.generate/0`). Kunci hanya
  berganti setelah penjualan tercatat, "Transaksi baru", atau pemulihan yang
  menolak kunci dari tablet.
- `checkout` mengirim kunci sebagai `client_ref`. Hasil
  `{:error, {:already_recorded, sale}}` diperlakukan seperti selesai: struk
  ditampilkan, keranjang dikosongkan, dengan pesan *"sudah tercatat
  sebelumnya. Jangan terima pembayaran lagi."*

## Penanganan kesalahan dan batas yang disengaja

| Keadaan | Perilaku |
| --- | --- |
| `localStorage` tidak tersedia | Kasir berjalan seperti sekarang, tanpa pemulihan |
| Salinan rusak / format tak dikenal | Diabaikan dan dihapus |
| Shift ditutup dari perangkat lain selama offline | Salinan diabaikan; layar menampilkan keadaan shift yang sebenarnya |
| Harga berubah selama offline | Harga baru dipakai, kasir diberi tahu |
| Barang terakhir habis dijual kasir lain | Barang dibuang dari keranjang, kasir diberi tahu |
| Dua tab untuk kasir yang sama | Salinan terakhir yang menang |
| Kasir lain memakai tablet yang sama | Slot per kasir; tidak saling terlihat |
| Logout | Salinan tetap di tablet, dipulihkan saat kasir itu login lagi di shift yang sama |
| Retur / batal / tutup shift | Tidak berubah; tetap butuh koneksi |

## Pengujian

**Konteks `Sales`** (`test/zahlungs/sales_test.exs`):

- kunci yang sama dua kali → satu penjualan, stok terpotong sekali, panggilan
  kedua `{:error, {:already_recorded, sale}}` dengan penjualan yang pertama;
- kunci berbeda → dua penjualan;
- tanpa kunci → perilaku lama (test yang ada tetap lulus);
- kunci yang sama di toko lain → tidak bentrok;
- `get_sale_by_client_ref/2` hanya menemukan penjualan di toko scope.

**Layar kasir** (`test/zahlungs_web/live/cashier_live_test.exs`, lewat
`ZahlungsWeb.LiveDriver`):

- event yang mengubah keranjang mengirim `cart_saved` berisi ID, jumlah dan
  harga yang dilihat; tidak ada yang dikirim sebelum `restore_cart` diterima;
- penjualan tercatat dan "Transaksi baru" mengirim `cart_saved` kosong dan
  membuat kunci baru;
- `restore_cart` memakai harga terbaru, membuang barang nonaktif dan
  stok-habis, memotong jumlah ke stok, dan melaporkan perubahannya;
- `restore_cart` diabaikan untuk shift lain, kasir lain, keranjang yang sudah
  berisi, atau data rusak;
- `restore_cart` dengan kunci yang sudah tercatat menampilkan penjualan itu
  dan tidak membuat penjualan baru;
- checkout dua kali dengan kunci yang sama (setelah pemulihan) → satu
  penjualan.

**Di browser** (repo belum punya alat test JavaScript):

- `liveSocket.disconnect()` lalu `liveSocket.connect()` di konsol di tengah
  transaksi: pita offline tampil, tombol terkunci, keranjang kembali utuh;
- muat ulang halaman di tengah transaksi: keranjang kembali;
- ubah harga barang dari tab admin selama "offline": pemulihan memakai harga
  baru dan memberi tahu;
- Complete Sale lalu putus sebelum struk tampil (latency simulator
  `liveSocket.enableLatencySim`): setelah tersambung, pesan "sudah tercatat",
  tidak ada penjualan kedua.

## Pekerjaan dan dampak

- Branch `feat/kasir-tahan-putus`, dipotong dari `master` di `13de279`
  (sudah berisi SaaS multi-pemilik lewat PR #1, sesuai skema database dev).
- Satu migrasi (`sales.client_ref` + indeks); dijalankan di database dev
  bersama.
- Tidak ada dependency baru.
- Dokumen: invarian baru di `CLAUDE.md` (*"Satu keranjang = paling banyak
  satu penjualan"*), dan bagian koneksi cadangan (opsi D: modem 4G / hotspot)
  di `docs/DEPLOYMENT.md`.

## Bekal untuk opsi B

Kunci keranjang dan pemeriksaan "sudah tercatat" adalah fondasi yang sama
yang dibutuhkan kasir offline: penjualan yang dicatat di tablet nanti dikirim
dengan `client_ref`-nya, dan pengiriman ulang otomatis aman.
