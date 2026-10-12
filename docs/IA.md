# Information Architecture (IA) — Zahlungs POS

Dokumen ini memetakan struktur informasi aplikasi: peran pengguna, peta situs,
navigasi, hierarki halaman, dan alur utama. Sumber kebenaran: `router.ex`,
`layouts.ex`, dan modul LiveView per halaman.

## 1. Peran (Roles)

| Peran       | Deskripsi                                                        |
| ----------- | ---------------------------------------------------------------- |
| **Guest**   | Belum login. Hanya bisa login / reset password (akun dibuat admin).|
| **Cashier** | Operasional harian: transaksi, shift, riwayat.                    |
| **Admin**   | Semua akses Cashier + master data, user, supplier, dan laporan.   |

Aturan akses berlapis (router):

- `redirect_if_user_is_authenticated` — halaman auth hanya untuk guest.
- `require_authenticated_user` + `:ensure_authenticated` — halaman operasional.
- `require_admin_user` + `:ensure_admin` — halaman back-office/admin.

## 2. Peta Situs (Sitemap)

```
/                               → redirect ke /home (landing)
│
├── Auth (guest only)
│   ├── /users/log_in           Login
│   ├── /users/reset_password   Minta reset password (email)
│   └── /users/reset_password/:token
│
├── Operasional (login: cashier + admin)
│   ├── /home                   Dashboard ringkas (penjualan hari ini, stok rendah)
│   ├── /cashier                Layar kasir (POS)
│   │     ├─ Gate: buka shift (modal awal) sebelum transaksi
│   │     ├─ Banner shift: Catat kas · Close shift
│   │     ├─ Cari produk / scan barcode (keyboard & kamera HP)
│   │     ├─ Keranjang → metode bayar (Tunai; lainnya disabled) → Complete Sale
│   │     └─ Modal struk: Print receipt · Koreksi/batalkan · New Transaction
│   ├── /catalog                Katalog produk (browse, cari, filter, paginasi)
│   ├── /sales                  Riwayat transaksi (filter tanggal, paginasi)
│   │     └── /sales/:id        Detail + struk · Batalkan (koreksi) · Return (admin)
│   │           └── /sales/:id/receipt   Struk versi cetak
│   ├── /shifts                 Riwayat shift (cashier: milik sendiri; admin: semua)
│   │     └── /shifts/:id       Detail: rekonsiliasi, transaksi, gerakan kas
│   └── /users/settings         Profil: ubah nama, email, password
│
└── Back-office (admin only)
    ├── /products               Manajemen produk (+ /new, /:id/edit — modal form)
    ├── /categories             Manajemen kategori (+ /new, /:id/edit)
    ├── /admin/users            Manajemen user (list, buat, ubah role,
    │                           reset password)
    ├── /admin/stores           Manajemen toko/cabang (ubah, aktif/nonaktif)
    ├── /admin/stores/register  Daftar cabang: wizard 2 langkah (data toko, kasir pertama opsional)
    ├── /admin/logins           Riwayat login + lokasi (filter toko & user)
    ├── /admin/suppliers        Manajemen supplier/consignor (+ /new, /:id/edit)
    ├── /reports/sales          Laporan penjualan (ringkasan, harian, per kasir,
    │                           per kategori, produk terlaris)
    ├── /reports/stock          Laporan stok (nilai persediaan, stok rendah/habis)
    ├── /reports/consignment    Settlement konsinyasi (payable/dibayar di rentang, sisa utang s.d. tanggal akhir
    │                           + sisa stok titipan per produk)
    └── /dashboard              Phoenix LiveDashboard (dev/test saja)
```

## 3. Navigasi Global (header hijau, responsive + hamburger)

Urutan link disesuaikan peran:

| Link        | Guest | Cashier | Admin | Tujuan                 |
| ----------- | :---: | :-----: | :---: | ---------------------- |
| Home        |   –   |    ✓    |   ✓   | `/home`                |
| Cashier     |   –   |    ✓    |   ✓   | `/cashier`             |
| Catalog     |   –   |    ✓    |   ✓   | `/catalog`             |
| Sales       |   –   |    ✓    |   ✓   | `/sales`               |
| Shifts      |   –   |    ✓    |   ✓   | `/shifts`              |
| Products    |   –   |    –    |   ✓   | `/products`            |
| Categories  |   –   |    –    |   ✓   | `/categories`          |
| Users       |   –   |    –    |   ✓   | `/admin/users`         |
| Stores      |   –   |    –    |   ✓   | `/admin/stores`        |
| Suppliers   |   –   |    –    |   ✓   | `/admin/suppliers`     |
| Reports     |   –   |    –    |   ✓   | `/reports/sales`       |
| Stock       |   –   |    –    |   ✓   | `/reports/stock`       |
| Consignment |   –   |    –    |   ✓   | `/reports/consignment` |
| Profile     |   –   |    ✓    |   ✓   | `/users/settings`      |
| Log in      |   ✓   |    –    |   –   | `/users/log_in`        |
| Log out     |   –   |    ✓    |   ✓   | DELETE `/users/log_out`|

## 4. Hierarki Konten per Halaman

### /home — Dashboard
1. Ringkasan penjualan hari ini (jumlah transaksi, total)
2. Daftar stok rendah

### /cashier — POS (inti aplikasi)
1. **Shift gate** — tanpa shift terbuka: form modal awal (format ribuan)
2. **Banner shift** — info shift + aksi *Catat kas* & *Close shift*
3. **Gerakan kas shift ini** — daftar in/out (setoran, pengeluaran, bayar konsinyasi)
4. **Pencarian produk** — teks / scan barcode (keyboard wedge & kamera HP);
   beep sukses/gagal
5. **Keranjang** — qty ± , hapus baris, subtotal per baris
6. **Pembayaran** — discount/tax, metode (Tunai aktif; QRIS/Kartu/Transfer
   disabled), amount paid (format ribuan), kembalian
7. **Modal struk** — ringkasan, print, koreksi/batalkan, transaksi baru
8. **Modal tutup shift** — opening + cash sales + cash in − cash out =
   expected; hitung fisik → variance (preview berwarna)

### /sales — Riwayat
- Tabel: code, tanggal, kasir, item, total, status (completed/returned/void)
- Detail: struk + status + alasan void; aksi *Batalkan (koreksi)* (pemilik/
  admin), *Return/Refund* (admin)

### /shifts — Riwayat shift
- Tabel: #, kasir (nama + email), buka/tutup, status, variance
- Detail: rekonsiliasi penuh (cash/non-cash, cash in/out, counted, variance),
  transaksi shift, gerakan kas

### /reports/consignment — Settlement titipan
1. Filter tanggal
2. Kartu: omzet titipan · harus dibayar & dibayar (rentang ini) · sisa utang s.d. tanggal akhir (kumulatif)
3. Tabel per supplier
4. Sisa stok titipan per produk (bisa dikembalikan)

### /admin/users
- Tabel: name, email, role, status, joined
- Aksi: make admin/cashier (bukan diri sendiri), reset password (bukan diri
  sendiri), buat user baru (modal)

### /products, /categories, /admin/suppliers
- Pola sama: tabel + modal create/edit + soft delete
- Form produk: SKU auto (3 konsonan kategori + counter), barcode (unik,
  boleh kosong, scan kamera), harga beli↔margin↔harga jual (dua arah,
  format ribuan), blok konsinyasi (checkbox + supplier, label harga titip)

## 5. Alur Utama (Task Flows)

```
Transaksi normal:
  login → /cashier → buka shift → scan/cari → keranjang → Tunai + amount
  → Complete Sale → struk (print) → New Transaction

Koreksi salah input:
  struk → "Koreksi / batalkan" → /sales/:id → Batalkan (koreksi) + alasan
  → stok balik, status void → input ulang di /cashier
  (shift sudah tutup → hanya admin)

Bayar supplier titipan dari laci:
  /cashier (shift terbuka) → Catat kas → tipe "Bayar konsinyasi" + supplier
  + jumlah → expected cash turun → tercatat "sudah dibayar" di
  /reports/consignment

Tutup kas harian (±4 shift/hari):
  Close shift → hitung fisik → variance → catatan → shift tersimpan
  → riwayat & audit di /shifts/:id

Kelola user (admin):
  /admin/users → New User / ubah role / Reset password (sesi lama user
  otomatis diakhiri)
```

## 6. Status & Terminologi

| Istilah          | Arti                                                      |
| ---------------- | --------------------------------------------------------- |
| `completed`      | Transaksi sah; masuk omzet, laporan, expected cash         |
| `returned`       | Barang dikembalikan pelanggan; stok balik, keluar omzet    |
| `void`           | Koreksi kesalahan input kasir; stok balik, keluar omzet    |
| Shift `open`     | Sesi kas berjalan; wajib ada sebelum transaksi             |
| Shift `closed`   | Sudah rekonsiliasi (expected vs counted → variance)        |
| Konsinyasi       | Titip jual; bayar supplier hanya untuk yang laku (Model A) |
| Harga titip      | `purchase_price` produk konsinyasi (dibayar ke supplier)   |
| Cash movement    | Uang laci masuk/keluar di tengah shift                     |

## 7. Dokumen Terkait

- `docs/PRD-POS.md` — kebutuhan produk
- `docs/SPRINT-PLAN.md` — rencana sprint awal
- `docs/CONCEPT-cashier-shift.md` — konsep shift kasir
- `docs/SPRINT-konsinyasi.md` — sprint konsinyasi (Model A)
- `docs/SPRINT-cash-movements.md` — sprint kas laci + bayar konsinyasi
- `docs/SPRINT-void-koreksi.md` — sprint void/koreksi invoice

## Multi-toko

- **Toko aktif.** Kasir terikat ke tokonya (nama toko tampil di navbar). Admin
  memilih toko lewat pemilih di navbar, termasuk **"Semua toko"**; pilihan
  disimpan di session.
- **Per toko:** stok, shift, gerakan kas, penjualan, struk. Katalog, kategori,
  supplier, dan user dikelola terpusat.
- **Kasir hanya melihat tokonya sendiri**: `/sales`, `/sales/:id`, struk,
  `/shifts/:id`, dan stok di `/catalog` serta `/cashier`. Data toko lain = 404.
- **"Semua toko" (admin):** laporan dan daftar digabung, laporan penjualan
  menambah rincian per toko, stok tampil sebagai jumlah semua toko. Tidak bisa
  membuka shift atau mengubah stok — pilih satu toko dulu.
- **Layar kasir** selalu memakai toko dari shift yang sedang terbuka, walaupun
  admin sudah memindahkan pemilih toko.
- **Login:** lokasi (lat/long) dari browser dicatat bila diizinkan; tidak
  pernah menolak login. Lima kali salah password untuk email yang sama menahan
  login 15 menit.

## Tampilan tablet (kasir)

- **Bar atas:** Cashier, Sales, Shifts, Catalog selalu satu ketukan; toko aktif;
  tombol **Menu** membuka laci berisi semua link, dikelompokkan *Kasir* / *Admin*
  / *Akun* (Profile, Log out).
- **/cashier, mendatar** (lebar >= 1024, atau >= 768 posisi landscape): produk
  di kiri, keranjang + pembayaran di kanan dan tetap terlihat saat digulir.
- **/cashier, tegak:** produk memenuhi layar; bilah bawah menampilkan jumlah
  item + total dan tombol **Bayar** yang membuka panel keranjang.
- **Kotak produk:** hingga 24 produk berstok tampil tanpa mencari; ketuk untuk
  menambah. Chip kategori dan kotak cari mempersempitnya.
- **Nominal cepat:** "Uang pas" dan pecahan (5/10/20/50/100 ribu) yang cukup
  menutup total.
- **/sales dan /shifts:** di bawah lebar 1024 tiap baris menjadi kartu yang bisa
  diketuk; di atasnya tetap tabel.
- **Tabel lain** digulir ke samping di dalam kotaknya bila lebih lebar dari layar.
- Target sentuh minimal 44 px; input 16 px pada layar sentuh.
