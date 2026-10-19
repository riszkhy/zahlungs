# Desain — Layanan PPOB, Fase 1 (lewat API penyedia)

Tanggal: 2026-10-19 · Status: disetujui untuk ditulis rencananya
Dibangun di atas: `docs/superpowers/specs/2026-10-16-layanan-ppob-fase-0-design.md`

## Tujuan

Zahlungs sendiri yang berbicara dengan penyedia PPOB (agregator): mengecek
tagihan PLN (*inquiry*), membayar (*payment*), dan menerima hasilnya, tanpa
kasir memakai aplikasi penyedia. Vendornya masih dinegosiasikan, jadi Fase 1
membangun **antarmuka penyedia yang tidak terikat vendor** dan **adapter
tiruan** untuk pengembangan dan test. Adapter vendor sungguhan ditulis setelah
vendor dan dokumentasi API-nya ada.

Berhasil bila:

- untuk tagihan PLN, kasir cukup mengetik ID pelanggan; nama, periode, lembar,
  tagihan, biaya admin dan total tampil dari penyedia sebelum uang diterima;
- untuk pulsa, paket data dan token PLN, hasil (dan token) datang dari
  penyedia, bukan ditandai kasir;
- tidak ada transaksi yang hilang jejaknya atau terbayar dua kali, walau
  koneksi putus, server restart, atau layar kasir tertutup di tengah jalan;
- toko yang belum pindah tetap bisa memakai cara manual Fase 0;
- kas shift dan perkiraan saldo deposit tetap benar, termasuk saat penyedia
  menjawab gagal setelah shift ditutup.

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Inquiry | Dilakukan Zahlungs lewat API (bukan disalin kasir) |
| Mulai | Rancang sekarang dengan adapter tiruan; adapter vendor menyusul |
| Mode | Per akun deposit: `manual` (alur Fase 0) atau `api` |
| Pending saat tutup shift | Shift boleh ditutup; pending ikut kas shift itu |
| Katalog | Admin mengisi kode produk vendor; modal tetap diisi admin |
| Biaya admin tagihan | Per lembar |
| Pendekatan | Catat dulu, kirim dari proses latar; callback + pengecek status berkala |
| Vendor | Satu vendor; multi-vendor nanti (arah sudah dicatat di spec Fase 0) |
| Dana | Akun dan saldo di penyedia milik tiap pemilik; Zahlungs tidak memegang dana |
| Uang pelanggan | Diterima sebelum pembayaran dikirim (seperti Fase 0) |

## Antarmuka penyedia

`Zahlungs.Services.Provider` adalah behaviour. Setiap adapter menerima
kredensial akun (sudah didekripsi) dan mengembalikan bentuk berikut.

- `inquiry(credentials, %{product_code, customer_ref})` →
  `{:ok, %{customer_name, period, sheets, bill_amount, inquiry_ref}}` atau
  `{:error, :not_found | :already_paid | :unavailable | {:rejected, pesan}}`.
- `pay(credentials, %{ref_id, product_code, customer_ref, inquiry_ref})` →
  `{:ok, result}` atau `{:error, :timeout | :unavailable}`.
- `status(credentials, ref_id)` → sama seperti `pay`.
- `verify_callback(credentials, params, headers)` →
  `{:ok, ref_id, result}` atau `{:error, :invalid_signature}`.
- `balance(credentials)` (opsional) → `{:ok, decimal}` atau `{:error, _}`.
- `ping(credentials)` → `:ok` atau `{:error, pesan}` (untuk "Tes koneksi").

`result` = `%{status: :success, token_sn, provider_ref}` |
`%{status: :failed, message}` | `%{status: :pending, provider_ref}`.

**Error jaringan atau timeout saat `pay` atau `status` berarti hasil belum
diketahui**, jadi diperlakukan sebagai pending, tidak pernah sebagai gagal.

**Adapter yang dikenal** didaftarkan di kode
(`Provider.adapters/0` → `%{"fake" => Provider.Fake}`). Akun menyimpan
kuncinya; nama modul tidak pernah diambil dari input.

**`Provider.Fake`** (dev dan test, tanpa jaringan) menentukan hasil dari digit
terakhir nomor tujuan: `0` gagal, `9` pending (status berikutnya: berhasil),
`8` pending (status berikutnya: gagal), `7` timeout saat `pay`, `6` inquiry
tidak ditemukan, `5` inquiry sudah lunas; selain itu berhasil. Inquiry tiruan
mengembalikan tagihan dan lembar yang bisa dihitung dari nomor.

## Data

Kolom uang `decimal(15, 2)`.

**`deposit_accounts`**: tambah `mode` (`manual` | `api`, default `manual`),
`provider` (kunci adapter, wajib untuk `api`), `credentials` (biner
terenkripsi), `callback_token` (acak 32 byte, unik, dibuat saat akun menjadi
`api`).

**`service_products`**: tambah `provider_code` (≤ 60). Produk tanpa kode tidak
bisa dijual lewat akun `api`.

**`service_transactions`**: tambah
- `channel` (`manual` | `api`): mode akun **saat dicatat**, supaya aturan
  tidak berubah bila mode akun diganti belakangan;
- `ref_id` (unik; dikirim ke penyedia, sama dengan `code`);
- `provider_ref`, `provider_message` (≤ 255), `last_checked_at`;
- `sheets` (lembar, default 1), `customer_name` (≤ 120), `period` (≤ 60);
- `service_inquiry_id` (tagihan lewat API);
- `failed_after_shift_close` (boolean);
- `refunded_at`, `refunded_by_id` (lihat Pengembalian).

**`service_inquiries`** (baru, milik toko, tanpa `organization_id`):
`store_id`, `user_id`, `service_product_id`, `deposit_account_id`,
`customer_ref`, `customer_name`, `period`, `sheets`, `bill_amount`,
`inquiry_ref`, `expires_at` (15 menit), `used_at`, timestamps.

## Harga tagihan per lembar

- harga = tagihan + margin, dengan margin rupiah = biaya admin × lembar, dan
  margin persen = persen dari total tagihan (seperti Fase 0);
- modal = tagihan + biaya penyedia × lembar.

Tanpa inquiry (Fase 0, mode manual) lembarnya 1, jadi hasil Fase 0 tidak
berubah. `Services.price_for/3` menerima lembar.

## Alur

### Tagihan PLN, akun `api`

1. Kasir memilih produk tagihan, mengetik ID pelanggan, menekan **Cek
   tagihan**. `Services.inquire/3` memanggil `inquiry` (batas tunggu 15 detik)
   dan menyimpan hasilnya di `service_inquiries`.
2. Layar menampilkan nama, periode, lembar, tagihan, biaya admin dan total.
   Penolakan ditampilkan dengan alasannya; tidak ada yang tercatat.
3. Kasir mengisi cara bayar dan uang diterima, lalu menekan **Bayar**.
   `Services.record/3` dengan `"inquiry_id"`: inquiry harus milik toko shift
   kasir, untuk produk yang sama, belum dipakai dan belum kedaluwarsa; nominal
   dan lembar diambil dari inquiry, bukan dari browser. Transaksi tercatat
   `processing` dengan `ref_id`, inquiry ditandai `used_at`, semuanya dalam
   satu transaksi database.
4. **Setelah commit**, pengiriman dijalankan di proses latar yang diawasi
   (`Task.Supervisor`), bukan di proses LiveView.

### Pulsa, paket data, token PLN, akun `api`

Tanpa inquiry: nomor dan pembayaran → `record/3` → kirim, sama seperti
langkah 3–4.

### Akun `manual`

Persis Fase 0, termasuk tagihan satu langkah dan tombol Berhasil/Gagal.

### Jawaban penyedia

`Services.apply_result/2` adalah satu-satunya jalan transaksi `api` menjadi
final. Ia mengunci baris dan hanya mengubah transaksi yang masih
`processing`.

- **Berhasil**: token/SN dan `provider_ref` disimpan.
- **Gagal**: pesan penyedia disimpan; transaksi masuk daftar **Perlu
  dikembalikan**. Bila shiftnya sudah ditutup: `failed_after_shift_close`
  diisi.
- **Pending**: tetap `processing`, `provider_ref` disimpan.

Jawaban datang dari tiga sumber, semuanya lewat `apply_result/2`:
1. balasan langsung `pay`;
2. callback penyedia;
3. pengecek status berkala.

Setiap perubahan disiarkan lewat PubSub per toko, sehingga layar Layanan
terbarui sendiri.

### Pengecek status

`Zahlungs.Services.StatusChecker` (GenServer dalam supervision tree) berjalan
setiap 60 detik. Ia mengambil transaksi `api` yang `processing` dan belum dicek
30 detik terakhir, termasuk yang tertinggal saat server mati, lalu memanggil
`status` dengan `ref_id` yang sama. **Pembayaran tidak pernah dikirim ulang**:
bila penyedia tidak mengenal `ref_id`, transaksi tetap pending dan diberi
pesan untuk admin. Dimatikan di test (`config :zahlungs, :service_status_checker, false`).

## Kas shift dan pengembalian

- `processing` dan `success` tetap dihitung di kas shift (seperti Fase 0).
- **Tutup shift**: hanya transaksi `channel = manual` yang masih `processing`
  menahan penutupan. Transaksi `api` yang pending tidak menahan; uangnya tetap
  di kas shift itu.
- **Gagal saat shift masih terbuka**: tidak dihitung di kas (uangnya akan
  dikembalikan dari laci), seperti Fase 0.
- **Gagal setelah shift ditutup** (`failed_after_shift_close`): **tetap
  dihitung** di shift yang sudah ditutup itu, karena angka shift tertutup final.
- **Perlu dikembalikan**: setiap transaksi `api` yang gagal dan belum
  `refunded_at` tampil di layar Layanan toko itu. Kasir yang sedang punya
  shift di toko itu menekan **Uang sudah dikembalikan**
  (`Services.confirm_refund/2`):
  - tunai dan `failed_after_shift_close`: pengeluaran kas `refund` dicatat di
    shift kasir yang terbuka, dalam satu transaksi dengan `refunded_at`;
  - tunai, gagal saat shift masih terbuka: hanya `refunded_at` (sudah tidak
    dihitung di kas);
  - non-tunai: hanya `refunded_at`; pesan mengingatkan agar dikembalikan lewat
    cara bayarnya.
- **Perkiraan saldo deposit**: tidak berubah dari Fase 0 (`processing` dan
  `success` memotong; `failed` tidak).

## Layar

### Layanan (kasir)

- Akun `api`, tagihan: kolom ID pelanggan, tombol **Cek tagihan**, kartu hasil
  inquiry (nama, periode, lembar, tagihan, biaya admin, total), lalu cara bayar
  dan **Bayar**. Inquiry kedaluwarsa atau sudah dipakai: pesan "Cek tagihan
  lagi".
- Akun `api`, transaksi pending: label **Menunggu penyedia** dan tombol **Cek
  status** (memanggil `status` sekarang). Tidak ada tombol Berhasil/Gagal.
- Daftar **Perlu dikembalikan** dengan tombol **Uang sudah dikembalikan**.
- Struk: nama pelanggan, periode dan lembar untuk tagihan; token/SN dari
  penyedia.

### Admin

- **Akun deposit**: mode, penyedia (dari daftar adapter), kredensial (hanya
  tulis; tampil "tersimpan"), URL callback untuk didaftarkan di vendor, dan
  **Tes koneksi**. Pencocokan: **Ambil saldo dari penyedia** bila adapter
  mendukung `balance`.
- **Produk layanan**: kolom **Kode produk vendor**.

## Keamanan

- **Kredensial** dienkripsi dengan `Plug.Crypto.MessageEncryptor`, kunci
  diturunkan dari `secret_key_base` (salt khusus). Tidak dikirim ke browser,
  tidak ditulis ke log, hanya didekripsi untuk adapter.
- **Callback** `POST /api/ppob/callback/:token`: akun dicari dari
  `callback_token` (lintas organisasi, `skip_org_id`); tanda tangan diperiksa
  adapter; `ref_id` harus milik akun itu; hanya `processing` → final. Balasan
  `200` setelah verifikasi (juga untuk callback ganda), `401` untuk tanda
  tangan salah, `404` untuk token tak dikenal.
- **Inquiry** hanya bisa dipakai di toko dan oleh produk yang membuatnya,
  sekali, sebelum kedaluwarsa.
- **Hak akses** seperti Fase 0; menandai manual hanya untuk `channel = manual`.

## HTTP

Adapter sungguhan memakai `:httpc` bawaan OTP dengan verifikasi TLS
(`verify_peer`, CA sistem). Tidak ada dependensi baru. Adapter tiruan tidak
memakai jaringan.

## Pengujian

TDD dengan `Provider.Fake`:

- inquiry: berhasil (lembar dan harga per lembar), tidak ditemukan, sudah
  lunas; inquiry kedaluwarsa, sudah dipakai, dari toko lain, produk lain;
- bayar: langsung berhasil, langsung gagal, pending → callback berhasil,
  pending → status gagal, timeout → pending;
- transaksi tertinggal (proses latar tidak berjalan) diselesaikan pengecek
  status; tidak ada `pay` kedua untuk `ref_id` yang sama;
- callback: tanda tangan salah, token tak dikenal, `ref_id` akun lain,
  callback ganda;
- kas: tutup shift dengan pending; gagal setelah tutup → angka shift tetap,
  Perlu dikembalikan → refund di shift berikutnya; non-tunai tanpa refund kas;
- mode `manual` tetap berperilaku seperti Fase 0; mengganti mode akun tidak
  mengubah transaksi lama;
- kredensial tidak muncul di HTML dan tersimpan terenkripsi;
- isolasi antar pemilik dan antar toko.

## Tidak termasuk Fase 1

- Adapter vendor sungguhan (menunggu vendor dan sandbox).
- Sinkron daftar harga dari vendor.
- Lebih dari satu vendor dan pengalihan otomatis.
- E-wallet, voucher game, tagihan selain PLN.
- Pembatalan/refund yang dimulai dari sisi penyedia.
