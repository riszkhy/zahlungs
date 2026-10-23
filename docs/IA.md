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
│   ├── /services               Layanan PPOB: catat pulsa/paket/token/tagihan (PLN, BPJS, PDAM…),
│   │     │                     lalu tandai berhasil (token/SN) atau gagal
│   │     └── /services/:id/receipt   Struk layanan versi cetak
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
    ├── /admin/services         Produk layanan PPOB: modal, margin Rp/% (+ /new, /:id/edit)
    ├── /admin/deposits         Akun deposit: perkiraan saldo, isi ulang, pencocokan
    │                           (+ /new, /:id, /:id/edit)
    ├── /reports/sales          Laporan penjualan (ringkasan, harian, per kasir,
    │                           per kategori, produk terlaris)
    ├── /reports/stock          Laporan stok (nilai persediaan, stok rendah/habis)
    ├── /reports/consignment    Settlement konsinyasi (payable/dibayar di rentang, sisa utang s.d. tanggal akhir
    │                           + sisa stok titipan per produk)
    ├── /reports/services       Laporan layanan (berhasil/gagal, nilai, modal, margin per kategori)
    └── /dashboard              Phoenix LiveDashboard (dev/test saja)
```

## 3. Navigasi Global (header hijau, responsive + hamburger)

Urutan link disesuaikan peran:

| Link        | Guest | Cashier | Admin | Tujuan                 |
| ----------- | :---: | :-----: | :---: | ---------------------- |
| Home        |   –   |    ✓    |   ✓   | `/home`                |
| Cashier     |   –   |    ✓    |   ✓   | `/cashier`             |
| Layanan     |   –   |    ✓    |   ✓   | `/services`            |
| Catalog     |   –   |    ✓    |   ✓   | `/catalog`             |
| Sales       |   –   |    ✓    |   ✓   | `/sales`               |
| Shifts      |   –   |    ✓    |   ✓   | `/shifts`              |
| Products    |   –   |    –    |   ✓   | `/products`            |
| Categories  |   –   |    –    |   ✓   | `/categories`          |
| Users       |   –   |    –    |   ✓   | `/admin/users`         |
| Stores      |   –   |    –    |   ✓   | `/admin/stores`        |
| Suppliers   |   –   |    –    |   ✓   | `/admin/suppliers`     |
| Produk layanan | – |    –    |   ✓   | `/admin/services`      |
| Deposit     |   –   |    –    |   ✓   | `/admin/deposits`      |
| Reports     |   –   |    –    |   ✓   | `/reports/sales`       |
| Stock       |   –   |    –    |   ✓   | `/reports/stock`       |
| Consignment |   –   |    –    |   ✓   | `/reports/consignment` |
| Laporan layanan | – |   –    |   ✓   | `/reports/services`    |
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

## SaaS (banyak pemilik)

- **/signup** (tamu): daftar bisnis baru -> organisasi berstatus menunggu,
  "Toko Utama", dan akun pemilik. **/signup/pending**: konfirmasi.
- **/platform/organizations** (hanya `superadmin`): daftar organisasi + pemilik,
  filter status, Setujui / Tolak / Tangguhkan / Aktifkan lagi, catatan, dan
  catatan tagihan manual.
- `superadmin` tidak punya menu kasir maupun admin toko; membuka halaman itu
  mengembalikannya ke `/platform/organizations`.
- Semua halaman lain hanya menampilkan data organisasi user yang login.

## Layanan PPOB (Fase 0, tanpa API)

- **/services** (kasir dan admin dengan shift terbuka, di toko yang punya akun
  deposit aktif): pilih produk, isi nomor tujuan, terima uang → status
  *diproses*; setelah diproses di aplikasi penyedia, tandai *berhasil* (token/SN)
  atau *gagal* (alasan, uang dikembalikan). Hanya yang mencatat atau admin yang
  boleh menandai.
- Shift tidak bisa ditutup selama masih ada layanan *diproses*.
- **/admin/services**, **/admin/deposits**, **/reports/services**: admin saja.
  Form toko memilih akun deposit yang dipakai toko itu.
- Layanan tidak masuk laporan penjualan barang maupun angka di Home.

## Layanan PPOB (Fase 1, lewat API penyedia)

Berlaku bila akun deposit toko bermode **API** (diatur di `/admin/deposits`).

- **Tagihan** (satu kategori/tab "Tagihan": PLN, BPJS, PDAM, Telkom, PGN):
  pilih produk → isi ID pelanggan → **Cek tagihan** (ke penyedia) → tampil nama,
  periode, jumlah bulan, tagihan, biaya admin, total → terima uang → **Bayar**.
  Mengubah ID pelanggan setelah cek membatalkan hasil cek; hasil cek berlaku 15
  menit.
- **Jumlah bulan**: untuk produk tagihan yang dicentang "Tanyakan jumlah bulan
  saat cek tagihan", kasir memilih **Jumlah bulan** (1-12) sebelum **Cek
  tagihan**; mengubahnya setelah cek membatalkan hasil cek. Produk tanpa centang
  tidak menanyakan (dianggap 1 bulan, atau sesuai jawaban penyedia). Pada akun
  manual, jumlah tagihan diketik kasir dan tidak ada pilihan bulan.
- **Pulsa, paket data, token PLN**: pilih produk, isi nomor, terima uang →
  **Bayar**. Zahlungs mengirim ke penyedia; tidak ada tombol Berhasil/Gagal.
- **Menunggu penyedia**: transaksi yang belum dijawab tampil di "Sedang
  diproses" dengan tombol **Cek status**. Jawaban penyedia (pengecekan otomatis
  tiap menit atau callback) memperbarui layar tanpa reload. Shift boleh ditutup
  meski masih ada yang menunggu.
- **Perlu dikembalikan**: layanan yang gagal di penyedia muncul di bagian ini
  sampai kasir menekan **Uang sudah dikembalikan**. Bila gagalnya setelah shift
  ditutup, pengembalian tunai dicatat sebagai kas keluar di shift yang sedang
  buka.
- **Struk tagihan** memuat nama pelanggan, periode, jumlah bulan dan referensi
  penyedia.
- **/admin/deposits** (akun API): penyedia, kredensial (tidak pernah
  ditampilkan lagi, hanya "tersimpan"), URL callback untuk didaftarkan ke
  penyedia, **Tes koneksi**, **Ambil saldo dari penyedia** (mengisi form
  pencocokan). **/admin/services**: kolom "Kode produk vendor".
- **`POST /api/ppob/callback/:token`**: dipanggil penyedia, bukan orang;
  tanpa login, diverifikasi dengan token akun dan tanda tangan penyedia.

## Layanan PPOB lewat Smart Biller Indonesia (SBI)

- **Token PLN** (akun API), per produk:
  - **Cek pelanggan dulu** (bawaan): pilih produk → isi nomor meter → **Cek
    pelanggan** → tampil nama dan tarif/daya → terima uang → **Bayar**. Tanpa cek
    pelanggan, token tidak bisa dibayar.
  - **Langsung** (centang "Cek pelanggan dulu" dimatikan di form produk): seperti
    pulsa, isi nomor meter → terima uang → **Bayar**.
- **Kartu tagihan**: tagihan, admin penyedia, tambahan toko (biaya tambahan
  per bulan yang diatur admin), total.
- **Perlu ditinjau**: bila SBI menjawab bertentangan dengan status transaksi
  (refund setelah berhasil, atau berhasil setelah gagal), status tidak berubah
  sendiri. Kasir melihat tanda "Perlu ditinjau" di riwayat; admin memutuskan di
  halaman akun deposit: **Batalkan dan kembalikan uang** (masuk Perlu
  dikembalikan), **Jadikan berhasil** (untuk yang gagal tapi ternyata terlayani;
  selama ditinjau, uangnya belum boleh dikembalikan) atau **Tetap berhasil /
  Tetap gagal**.
- **/admin/deposits** (penyedia SBI): Member ID, PIN, Password (tidak pernah
  ditampilkan lagi); URL callback `…/api/ppob/callback` untuk didaftarkan di
  SBI; Tes koneksi dan Ambil saldo memakai saldo SBI.
- **/admin/services**: **Cari di daftar SBI** di form produk (mengisi kode,
  nama, modal, kategori; semua item grup "PPOB" SBI disarankan sebagai
  kategori Tagihan, dengan admin dan komisi SBI); kolom **Biaya tambahan toko
  (akun API)** (per bulan) dan centang **Tanyakan jumlah bulan saat cek
  tagihan** untuk tagihan; **Kode cek pelanggan (akun
  API)** untuk token PLN (kosong = bawaan penyedia, SBI: `CPLNPRA`); tombol **Perbarui dari
  SBI** (ringkasan perubahan modal dan status, disimpan setelah disetujui);
  tanda **Gangguan / Kosong / Tidak ditemukan** (tidak bisa dijual lewat akun
  API) dan **Modal SBI naik**.
- **`POST /api/ppob/callback`** (tanpa token): callback SBI, dikenali dari
  `ref_1`, dipercaya hanya dengan header `rqid` (password akun) dari IP SBI.
