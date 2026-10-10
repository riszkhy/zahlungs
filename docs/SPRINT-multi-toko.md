# Sprint Plan — Multi-toko (satu pemilik, beberapa cabang, server pusat online)

## Ringkasan model

Satu pemilik mengelola beberapa **toko (cabang)** dari satu aplikasi yang
berjalan di **satu server pusat** dan diakses tiap toko lewat internet.

| Dikelola terpusat (global)                  | Terpisah per toko                         |
| ------------------------------------------- | ----------------------------------------- |
| User, kategori, supplier                    | Stok                                      |
| Produk: nama, SKU, barcode, harga, titipan  | Shift (laci kas) + gerakan kas            |
|                                             | Penjualan + item + struk                  |

> **Aturan inti:** toko sebuah penjualan **selalu diturunkan dari shift**, dan
> toko sebuah shift diturunkan dari **toko aktif** user. Layar kasir tidak pernah
> mengirim `store_id`.

Ini melanjutkan pola yang sudah ada: `Sales.create_sale/3` mencari dan mengunci
sendiri shift terbuka milik kasir, jadi penjualan otomatis tahu tokonya.

## Keputusan

| # | Pertanyaan                         | Keputusan                                                        | Status       |
| - | ---------------------------------- | ---------------------------------------------------------------- | ------------ |
| 1 | Cabang atau multi-tenant?          | Satu pemilik, beberapa cabang                                    | **Diputuskan** |
| 4 | Server pusat atau per toko?        | Server pusat online (toko tidak bisa jualan saat internet putus) | **Diputuskan** |
| 2 | Harga sama di semua toko?          | Sama; harga per toko ditunda (MT.6)                              | Asumsi       |
| 3 | Kasir terikat ke satu toko?        | Ya, satu toko; admin bisa memindahkan                            | Asumsi       |
| 5 | Transfer stok antar toko?          | Ditunda (MT.6); sementara lewat penyesuaian stok manual          | Asumsi       |
| 6 | Ada toko di zona waktu berbeda?    | Disiapkan (`utc_offset_hours` per toko), default WIB             | Asumsi       |
| 7 | Perlu role kepala toko?            | Belum; hanya `admin` (lintas toko) dan `cashier` (satu toko)     | Asumsi       |
| 8 | Lokasi login: dicatat atau dibatasi? | Hanya dicatat; login tidak pernah ditolak karena lokasi        | **Diputuskan** |

Baris berstatus *Asumsi* bisa diubah sebelum MT.1 dimulai tanpa biaya; setelah
itu nomor 2 dan 3 mengubah skema.

## Status implementasi (branch `feat/multi-toko`)

Sudah dikerjakan: MT.1, MT.2 (kecuali MT.2.6), MT.3, MT.4, MT.5.1, MT.5b.
Hal yang berbeda dari rencana di bawah:

- **MT.1.2** — admin dibiarkan tanpa toko (`users.store_id` kosong); hanya
  kasir yang dipindahkan ke Toko Utama.
- **MT.2.6** — kolom `products.stock` belum dihapus (rilis berikutnya).
- **MT.4.2** — batas hari mengikuti zona waktu toko bila satu toko dipilih;
  tampilan "Semua toko" memakai zona default, bukan join per toko. Tepat selama
  semua toko berada di zona waktu yang sama.
- **MT.5.2–5.5** — HTTPS, mailer, backup, dan prosedur offline adalah urusan
  deployment; didokumentasikan di `DEPLOYMENT.md`, tidak ada kodenya. Mailer
  sungguhan masih menunggu dependency SMTP.
- **MT.5b.2 / MT.5b.4** — skrip lokasi di halaman login dan tombol "pakai lokasi
  saya" tidak punya test otomatis (proyek belum punya test runner JavaScript).
- Shift yang masih terbuka di toko yang dinonaktifkan tidak bisa ditutup dari
  layar kasir; tutup shift dulu sebelum menonaktifkan toko.

## Peran dan toko aktif

- **Admin (pemilik):** lintas toko. Memilih **toko aktif** lewat pemilih di
  navbar (disimpan di session). Boleh membuka shift dan berjualan di toko aktif.
- **Kasir:** terikat ke `users.store_id`; tidak ada pemilih toko. Hanya melihat
  stok, penjualan, dan shift **tokonya sendiri**.
- **Scope:** `%Zahlungs.Scope{user, store}` dibentuk sekali di
  `UserAuth.fetch_current_user` / `on_mount` dan tersedia sebagai
  `@current_scope`. Semua fungsi context yang menyentuh data per toko menerima
  scope sebagai argumen pertama — lupa menyaring menjadi error kompilasi/test,
  bukan kebocoran diam-diam.

---

## MT.0 — Persiapan (kecil)

- **MT.0.1** Perbarui `PRD-POS.md` (multi-cabang masuk cakupan) dan `IA.md`
  (kolom "toko" di matriks akses).
- **MT.0.2** Konfirmasi keputusan 2, 3, 5, 6, 7 di tabel atas.

## MT.1 — Fondasi: toko + scope (sedang, tanpa perubahan perilaku)

- **MT.1.1** Migrasi tabel `stores`: `name` (not null), `code` (unik, pendek,
  untuk awalan invoice), `address`, `phone`, `utc_offset_hours` (default 7),
  `latitude`, `longitude` (nullable; untuk menghitung jarak di MT.5b),
  `active`, timestamps.
- **MT.1.2** Migrasi: `users.store_id` (nullable — admin boleh kosong),
  `cashier_shifts.store_id`, `sales.store_id` (FK, not null setelah backfill).
  Index `(store_id, inserted_at)` di `sales`, `(store_id, status)` di shift.
- **MT.1.3** Backfill: buat satu toko bawaan **"Toko Utama"**; semua kasir,
  shift, dan penjualan yang ada masuk ke toko itu.
- **MT.1.4** Context baru `Zahlungs.Stores` (`list_stores/0`, `get_store!/1`,
  `create_store/1`, `update_store/2`, `set_store_active/2`) + schema `Store`.
- **MT.1.5** `Zahlungs.Scope` + pembentukannya di `UserAuth` (plug dan
  `on_mount`). Kasir tanpa toko atau dengan toko nonaktif ditolak login dengan
  pesan jelas.
- **MT.1.6** `Shifts.open_shift(scope, opening_cash)` mengisi `store_id`;
  `Sales.create_sale/3` menyalin `store_id` dari shift yang dikunci.
- **MT.1.7** Semua query baca di `Sales` dan `Shifts` disaring per toko lewat
  scope: `list_sales`, `count_sales`, `get_sale!`, `list_shifts`, `get_shift!`,
  `sales_summary_today`. `get_*!` untuk toko lain → `Ecto.NoResultsError` (404),
  termasuk `/sales/:id/receipt`.

Selesai MT.1: dengan satu toko, aplikasi berperilaku persis seperti sekarang dan
bisa di-deploy.

## MT.2 — Stok per toko (besar, paling berisiko)

- **MT.2.1** Migrasi tabel `product_stocks`: `store_id`, `product_id`, `stock`
  (default 0), unique index `(store_id, product_id)`. Backfill dari
  `products.stock` ke Toko Utama.
- **MT.2.2** Pengurangan stok saat penjualan pindah ke
  `UPDATE product_stocks SET stock = stock - qty WHERE store_id = ? AND
  product_id = ? AND stock >= qty`. Baris yang belum ada dianggap stok 0.
- **MT.2.3** Return/void mengembalikan stok ke **toko penjualannya**
  (`sale.store_id`), bukan toko user yang memproses.
- **MT.2.4** `Catalog`: `list_products`, `count_products` (filter `in_stock`),
  `get_product_by_code`, `list_low_stock_products`, `stock_report`, dan
  `consignment_stock_on_hand` membaca stok toko dari scope.
- **MT.2.5** Form produk: kolom stok menjadi "stok di toko aktif"; produk baru
  mulai dengan stok 0 di toko lain.
- **MT.2.6** Migrasi terpisah (rilis berikutnya): hapus kolom `products.stock`
  setelah tidak ada lagi kode yang membacanya.

## MT.3 — Tampilan (sedang)

- **MT.3.1** `StoreLive.Index` + `FormComponent` di `/admin/stores` (admin).
- **MT.3.2** Pemilih toko aktif di navbar untuk admin; nama toko tampil untuk
  kasir.
- **MT.3.3** `/admin/users`: pilih toko saat membuat/mengubah kasir.
- **MT.3.4** Struk dan `sale_receipt`: kop memakai nama, alamat, dan telepon
  toko (sekarang tertulis tetap "Zahlungs POS").
- **MT.3.5** Kode invoice diberi awalan kode toko (`JKT1-INV…`); index unik
  global tetap.

## MT.4 — Laporan dan konsinyasi (sedang)

- **MT.4.1** Semua laporan (`sales_report`, `top_products`, `sales_by_*`,
  `stock_report`) menerima toko dari scope; admin mendapat pilihan
  **"Semua toko"** dan rincian per toko.
- **MT.4.2** Zona waktu per toko: fungsi `Zahlungs.LocalTime` menerima offset
  toko. Laporan gabungan menghitung batas hari per toko (join ke
  `stores.utc_offset_hours`).
- **MT.4.3** Konsinyasi: sisa stok titipan per toko; `consignment_statement`
  bisa disaring per toko, dengan sisa utang ke supplier tetap dijumlahkan lintas
  toko sebagai default (supplier dibayar per supplier, bukan per toko).
- **MT.4.4** Home: ringkasan hari ini dan stok rendah untuk toko aktif.

## MT.5 — Kesiapan server pusat online (sedang)

Aplikasi sekarang dirancang untuk satu lokasi; begitu terbuka ke internet:

- **MT.5.1** Pembatasan percobaan login (brute force) — saat ini tidak ada.
- **MT.5.2** Wajib HTTPS di belakang reverse proxy (`FORCE_SSL=true`); kamera
  barcode di HP otomatis berfungsi karena domain publik sudah HTTPS.
- **MT.5.3** Mailer sungguhan untuk reset password (lihat `DEPLOYMENT.md`);
  tanpa itu admin harus me-reset password kasir di toko lain secara manual.
- **MT.5.4** Backup database terjadwal dan `POOL_SIZE` disesuaikan dengan jumlah
  kasir yang aktif bersamaan.
- **MT.5.5** Prosedur saat internet toko putus (catat manual, input ulang) —
  didokumentasikan, bukan dibangun.

## MT.5b — Pencatatan lokasi (lat/long) saat login (kecil)

Tujuan: tahu **dari mana** tiap login dilakukan. Ini murni pencatatan — login
tidak pernah ditolak atau diperlambat karena lokasi.

**Batasan yang perlu dipahami.** Lokasi berasal dari browser (Geolocation API):
butuh HTTPS dan izin pengguna, akurasinya bisa meleset ratusan meter di PC tanpa
GPS, dan bisa dipalsukan oleh orang yang paham teknis. Anggap sebagai jejak
audit, bukan bukti.

- **MT.5b.1** Migrasi tabel `user_logins` (log, tidak pernah diubah):
  `user_id`, `store_id`, `latitude`, `longitude`, `accuracy_m` (ketiganya
  nullable), `distance_m` (jarak ke toko, bila toko punya koordinat), `ip`,
  `user_agent`, `inserted_at`. Index `(user_id, inserted_at)` dan
  `(store_id, inserted_at)`.
- **MT.5b.2** Form login: skrip kecil meminta posisi lewat
  `navigator.geolocation` lalu mengisi field tersembunyi `latitude`,
  `longitude`, `accuracy` sebelum submit. Bila izin ditolak, tidak tersedia,
  atau terlalu lama (batas beberapa detik), form tetap terkirim **tanpa**
  lokasi dan login berjalan seperti biasa.
- **MT.5b.3** `Accounts.record_login/3` menyimpan satu baris untuk setiap login
  yang berhasil; nilai lat/long divalidasi rentangnya (−90..90, −180..180) dan
  dibuang bila tidak masuk akal. `Zahlungs.Geo.distance_m/2` (haversine, fungsi
  murni) mengisi `distance_m`. Kegagalan mencatat tidak boleh menggagalkan
  login.
- **MT.5b.4** Admin: isi koordinat toko di form toko (MT.3.1, termasuk tombol
  "pakai lokasi saya sekarang"), dan halaman riwayat login per user/toko
  (waktu, toko, jarak dari toko, tautan ke peta).
- **MT.5b.5** Privasi: lokasi adalah data pribadi karyawan. Tampilkan
  pemberitahuan singkat di halaman login, dan tetapkan masa simpan log (usul:
  90 hari, dibersihkan otomatis).

Sengaja **tidak** dibangun: pembatasan radius, penolakan login di luar toko,
dan pengecekan ulang saat buka shift. Bila nanti dibutuhkan, log ini sudah
menyediakan datanya.

## MT.6 — Opsional (setelah dipakai)

- Transfer stok antar toko (`stock_transfers`: asal, tujuan, item, status).
- Harga berbeda per toko (`product_prices` sebagai override harga global).
- Role kepala toko (admin terbatas satu toko).
- Kasir bertugas di beberapa toko (`store_users`, pilih toko saat buka shift).

---

## Invarian yang harus dijaga

- `sale.store_id == shift.store_id`, dan `shift.store_id` berasal dari scope.
- Tidak ada fungsi context yang menerima `store_id` dari params web.
- Stok tidak pernah negatif per `(toko, produk)`; pengurangannya tetap satu
  `UPDATE` berpenjaga di dalam transaksi penjualan.
- Kasir toko A tidak bisa membaca atau mengubah penjualan, shift, atau stok
  toko B lewat URL maupun event LiveView.

## Tests

- **Kebocoran antar toko** (prioritas): untuk tiap fungsi baca/ubah di `Sales`,
  `Shifts`, dan stok — user toko A terhadap data toko B harus gagal/kosong.
  Termasuk `/sales/:id`, `/sales/:id/receipt`, `/shifts/:id`, void, dan return.
- Stok: jual di toko A tidak mengurangi stok toko B; oversell per toko ditolak;
  return mengembalikan ke toko asal.
- Backfill: data lama utuh di Toko Utama; total penjualan dan stok sebelum =
  sesudah migrasi.
- Laporan: per toko vs "semua toko" konsisten (jumlah per toko = total).
- LiveView (lewat `ZahlungsWeb.LiveDriver`): pemilih toko admin, kasir tanpa
  toko ditolak, kop struk per toko.
- Lokasi login: jarak haversine terhadap titik yang diketahui; login dengan dan
  tanpa lokasi sama-sama berhasil dan masing-masing menghasilkan satu baris
  `user_logins`; koordinat di luar rentang dibuang; login yang gagal password
  tidak dicatat.

## Urutan rilis

| Rilis | Isi          | Terlihat pengguna?                         |
| ----- | ------------ | ------------------------------------------ |
| 1     | MT.1         | Tidak (masih satu toko)                    |
| 2     | MT.2         | Tidak                                      |
| 3     | MT.3 + MT.4  | Ya — toko kedua bisa dibuat dan dipakai    |
| 4     | MT.5         | Wajib sebelum toko kedua go-live di internet |
| 5     | MT.5b        | Ya — riwayat login untuk admin; tidak wajib untuk go-live |

Rilis 1 dan 2 mengubah skema pada data nyata: jalankan di salinan database dulu
dan ambil backup sebelum migrasi produksi.

## Di luar cakupan (sengaja)

- **Mode offline + sinkronisasi** per toko — masalah yang jauh lebih besar;
  keputusan nomor 4 menerima bahwa toko berhenti berjualan saat internet putus.
- **Multi-tenant** (beberapa bisnis terpisah dalam satu instalasi).
- Multi-laci dalam satu toko per kasir (`register_id`) — tetap 1 kasir = 1 laci.
- Gudang pusat dan pembelian (PO) terpusat.
