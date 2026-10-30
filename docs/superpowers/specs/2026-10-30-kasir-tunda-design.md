# Desain — Tunda keranjang di Kasir

Tanggal: 2026-10-30 · Status: menunggu tinjauan
Branch: `feat/kasir-tunda` (dari `master`)

## Tujuan

Kasir bisa **menyimpan keranjang sementara** (pelanggan lupa dompet, masih
memilih barang), melayani pelanggan berikutnya, lalu **melanjutkan** keranjang
itu nanti, dari tablet mana pun di toko yang sama.

Berhasil bila:

1. Keranjang yang ditunda tidak hilang: barang, jumlah, diskon dan pajak
   kembali saat dilanjutkan, dengan harga produk saat itu.
2. Satu keranjang tertunda tidak pernah dilanjutkan di dua tablet sekaligus.
3. Stok, kas shift dan laporan **tidak berubah** karena keranjang tertunda;
   semuanya baru bergerak saat penjualan selesai, seperti sekarang.

Di luar cakupan: bayar nanti / piutang (kasbon). Itu fitur terpisah dengan
spec sendiri, karena mengubah penjualan, kas shift dan laporan.

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Penyimpanan | Tabel di server (`held_carts`, `held_cart_items`); bukan `localStorage` (tak terlihat tablet lain), bukan `sales` berstatus "ditunda" (semua laporan dan kas harus menyaringnya) |
| Siapa yang bisa melanjutkan | Semua kasir di toko itu |
| Tutup shift | Boleh, dengan peringatan; keranjang tertunda tetap tersimpan |
| Lanjutkan saat keranjang di layar berisi | Tukar: keranjang di layar ikut ditunda |
| Penanda | Catatan opsional; tanpa catatan, label otomatis "3 item · Rp 45.000 · 14:05" |
| Kedaluwarsa | Tidak ada; dihapus manual, daftar menampilkan umurnya |
| Stok | Tidak dipesan; dicek lagi saat dilanjutkan dan saat penjualan |
| Harga | Tidak disimpan; dihitung dari harga produk saat dilanjutkan |

## Data

`held_carts` (per toko, seperti `sales`; tanpa `organization_id`):

| Kolom | Isi |
| --- | --- |
| `store_id` | toko shift kasir yang menunda (bukan dari input) |
| `user_id` | kasir yang menunda |
| `shift_id` | shift saat ditunda (catatan saja; keranjang tidak terikat shift) |
| `note` | catatan opsional, maks. 60 karakter |
| `discount`, `tax` | seperti diketik kasir (decimal, boleh 0) |
| `inserted_at` | kapan ditunda (umur di daftar) |

`held_cart_items`: `held_cart_id` (hapus berantai), `product_id`, `quantity`
(> 0), `name` (salinan nama untuk daftar). Harga tidak disimpan.

## Aturan (context `Zahlungs.HeldCarts`)

Semua fungsi mengambil toko dari **shift terbuka** kasir, seperti
`Sales.create_sale/3`; tanpa shift → `{:error, :no_open_shift}`. Toko tidak
pernah diambil dari parameter.

- `hold(user, items, attrs)` — `items`: `[%{product_id, quantity}]`, tidak
  kosong; `attrs`: `note`, `discount`, `tax`. Menyimpan keranjang beserta
  nama produk. Keranjang kosong → `{:error, :empty_cart}`.
- `list(user)` — keranjang tertunda di toko shift itu, terbaru di atas, dengan
  barangnya, jumlah item, dan perkiraan total dari harga produk saat ini.
- `count(user)` — jumlahnya (untuk tombol dan peringatan tutup shift).
- `resume(user, id)` — dalam satu transaksi: kunci baris (`FOR UPDATE`),
  ambil, hapus. Keranjang toko lain atau yang sudah tidak ada →
  `{:error, :not_found}` (pesan: "Sudah dilanjutkan atau dihapus di kasir
  lain."). Hasil: barang dengan produk dan stok toko itu saat ini (lewat
  `Catalog`), diskon, pajak, dan berapa barang yang **disesuaikan**:
  - produk terhapus atau nonaktif → dibuang;
  - jumlah melebihi stok → dipotong ke stok; stok 0 → dibuang.
- `delete(user, id)` — kasir mana pun di toko itu; toko lain →
  `{:error, :not_found}`.

Keranjang tertunda tidak menyentuh `product_stocks`, `cashier_shifts`,
`cash_movements` maupun `sales`; tidak masuk laporan dan angka Home.

## Layar Kasir (`CashierLive`)

- **Tunda** di panel keranjang, aktif bila keranjang berisi. Membuka form
  kecil: catatan opsional + "Tunda". Setelah tersimpan keranjang dikosongkan
  (seperti `reset_cart/1`), flash "Keranjang ditunda."
- **Ditunda (N)** di atas daftar produk (N > 0). Membuka daftar: catatan atau
  label otomatis, umur ("5 menit lalu", "2 hari lalu"), tombol **Lanjutkan**
  dan **Hapus** (konfirmasi).
- **Lanjutkan**: bila keranjang di layar berisi, keranjang itu ditunda dulu
  (tanpa catatan), lalu yang dipilih dibuka. Barang yang disesuaikan
  diberitahukan: "2 barang disesuaikan dengan stok."
- **Tutup shift**: bila `count/1` > 0, dialog menampilkan "Ada N keranjang
  tertunda di toko ini. Keranjang tetap tersimpan." Shift tetap bisa ditutup.
- **Ponsel**: Tunda ada di panel keranjang yang naik dari bawah; "Ditunda (N)"
  di atas daftar produk.

## Tes

Context:

- tunda butuh shift terbuka; toko dari shift; keranjang kosong ditolak;
  catatan > 60 karakter ditolak;
- daftar hanya toko sendiri, terbaru di atas;
- lanjutkan mengembalikan barang, diskon, pajak, lalu menghapusnya; kedua kali
  → `:not_found`;
- dua proses melanjutkan bersamaan: tepat satu berhasil;
- produk dihapus / nonaktif dibuang, jumlah dipotong ke stok, stok 0 dibuang;
- keranjang toko lain tidak bisa dilanjutkan atau dihapus;
- menunda tidak mengubah stok maupun `Shifts.expected_cash/1`.

Layar (lewat `ZahlungsWeb.LiveDriver`):

- Tunda mengosongkan keranjang dan menambah "Ditunda (1)";
- Lanjutkan mengisi keranjang dengan harga produk saat ini;
- Lanjutkan saat keranjang berisi menukar keduanya;
- Hapus menghilangkannya dari daftar;
- peringatan di dialog tutup shift.
