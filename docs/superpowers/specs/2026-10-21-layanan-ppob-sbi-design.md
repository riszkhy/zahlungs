# Desain — Layanan PPOB, adapter Smart Biller Indonesia (SBI)

Tanggal: 2026-10-21 · Status: menunggu tinjauan
Dibangun di atas: `docs/superpowers/specs/2026-10-19-layanan-ppob-fase-1-design.md`
(branch `feat/layanan-ppob-fase-1`)

Sumber vendor: `DOKUMEN TEKNIS SBI 2_12_25 (7).pdf` dan koleksi Postman publik
<https://documenter.getpostman.com/view/15055506/2sA3JRXdwS> (folder **API SIGN**),
daftar harga publik <https://bo.smartbiller.co.id/v1/public/h2h-umum/json> (dipindah SBI
pada 2026-10 dari `https://api.billerindonesia.com/V1/ppob/h2h_umum/pricelist`).

## Tujuan

Zahlungs menjual pulsa, paket data, token PLN dan tagihan PLN lewat SBI
sungguhan, menggantikan penyedia tiruan untuk akun deposit yang memilih SBI.
Layar kasir dan alur Fase 1 tetap; yang baru adalah adapter SBI, beberapa
salinan data di transaksi, katalog dari SBI, dan peninjauan untuk jawaban SBI
yang bertentangan.

Berhasil bila:

- transaksi sungguhan di SBI selesai benar — berhasil, gagal, atau pending lalu
  selesai sendiri lewat callback atau pengecek status — tanpa pernah terbayar
  dua kali;
- kas laci dan perkiraan saldo deposit tetap seimbang, dan pencocokan saldo
  dengan SBI tidak menyisakan selisih setelah uji coba;
- setiap transaksi menyimpan salinan lengkap (kode vendor, modal sebenarnya,
  jawaban SBI), sehingga riwayat tidak bergantung pada katalog SBI;
- semua pengujian otomatis berjalan tanpa memanggil SBI (SBI tidak punya
  sandbox).

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Webhook | Menyatu di Zahlungs; tidak ada service terpisah |
| URL callback | `POST /api/ppob/callback` (sudah didaftarkan di SBI), dikenali dari `ref_1`; route bertoken Fase 1 tetap ada |
| Mode API SBI | JSON + `sign` (mode yang direkomendasikan SBI) |
| Harga tagihan | Pelanggan membayar **total SBI + biaya tambahan toko × lembar** |
| Harga prabayar | Harga jual = modal isian + margin, stabil di layar; modal diisi dari pemilih/pembaruan SBI; **modal sebenarnya** dicatat per transaksi |
| Katalog SBI | Tidak disimpan di database; pemilih produk + tombol "Perbarui dari SBI" |
| Token PLN | Selalu **Cek pelanggan** dulu (nama, daya) sebelum Bayar |
| RC:31 setelah berhasil | **Perlu ditinjau**; admin memilih "Batalkan dan kembalikan uang" atau "Tetap berhasil" |
| Pendekatan | Adapter di belakang behaviour Fase 1; hasil diperkaya dengan kunci opsional |
| Sandbox | Tidak ada; uji coba dengan deposit kecil, bertahap |
| HTTP | `:httpc` bawaan OTP, TLS terverifikasi; tidak ada dependensi baru |

## Adapter SBI

Modul di `lib/zahlungs/services/provider/`:

- **`Provider.Sbi`** — implementasi behaviour: `credential_fields/0`,
  `inquiry/2`, `pay/2`, `status/2`, `verify_callback/3`, `ping/1`, `balance/1`,
  dan callback opsional baru `catalog/1`, `prices/2`, `callback_ref/1`.
- **`Provider.Sbi.Client`** — `post(action, body, headers, timeout)` ke
  `<base_url>/api/<action>` lewat `:httpc`, JSON, TLS dengan
  `:public_key.cacerts_get()` dan pemeriksaan nama host. Hanya HTTPS. Mengembalikan
  `{:ok, status_http, map}` atau `{:error, :timeout | :network | :bad_response}`.
  Modul client diambil dari config, sehingga test memakai client tiruan yang
  memutar jawaban contoh; test tidak pernah memanggil SBI.
- **`Provider.Sbi.Sign`** — `sign(mmid, product_code, customer_id, ref_1, pin, password)` =
  `base64url(sha1("R-ONE|mmid|product_code|customer_id|ref_1|pin|password"))`
  tanpa `=`, dikirim di header `sign`.
- **`Provider.Sbi.Reply`** — membaca jawaban: status `1/2/11`; RC dari `msg`
  (`GAGAL, RC:14`); SN dari `msg` (`SN:` sampai sebelum `REFID`); untuk tagihan
  nama (`detail.data_1` atau `Nama:`), jumlah bulan (`Jml bulan:`), periode
  (`Blth:`), tagihan (`price`), admin (`admin`), total (`total_payment`);
  modal sebenarnya (`total_payment`, atau `HRG:` di `msg`).

Config (`config :zahlungs, Zahlungs.Services.Provider.Sbi`):
`base_url` (default `https://apisbi.mesinr1.com/V1`), `client`,
`callback_ips` (default `["183.91.82.154"]`), `pricelist_url`
(default daftar harga publik). Adapter didaftarkan di
`config :zahlungs, :provider_adapters` dengan kunci `"sbi"`; label pilihan
"Smart Biller Indonesia (SBI)".

**Kredensial** (form akun deposit, terenkripsi, tidak pernah ditampilkan lagi):
`member_id` (Member ID / `mmid`), `pin` (PIN), `password` (Password).

**Pemetaan aksi:**

| Zahlungs | SBI | Catatan |
| --- | --- | --- |
| Cek tagihan PLN | `inquiry` | `ref_1` dari inquiry Zahlungs; jawaban `ref_2` |
| Bayar tagihan | `payment` | `ref_1` dan `ref_2` **sama** dengan inquiry |
| Cek pelanggan token PLN | `inquiry`, kode `CPLNPRA` | nama dan daya; tidak memotong saldo |
| Pulsa, paket data, token PLN | `topup` | `ref_1` transaksi sendiri |
| Cek status | `status` dengan `ref_1` | |
| Tes koneksi, Ambil saldo | `balance` | `data.saldo`; tidak memotong saldo |
| Pemilih produk | daftar harga publik | disimpan di memori 10 menit |
| Perbarui dari SBI | `price` per kode | priceplan akun kita; maksimal 5 permintaan sekaligus |

**Batas waktu:** inquiry dan cek pelanggan 15 detik (lewat → "Penyedia tidak
tersedia, coba lagi."); payment dan topup 45 detik (lewat → pending, lanjut
callback/pengecek); status dan saldo 15 detik.

## Perubahan antarmuka penyedia

Semua tambahan bersifat opsional; `Provider.Fake` dan `Provider.Broken` tetap
memenuhi behaviour (Fake diperbarui untuk kunci baru inquiry, lihat Harga).

- `inquiry(credentials, %{ref_id, product_code, customer_ref})` — **`ref_id`
  baru**: ref yang dikirim ke vendor. Hasil `{:ok, ...}` menambah
  `provider_admin`, `provider_total`, `details` (tarif/daya); `bill_amount`
  boleh `nil` (cek pelanggan token).
- `result` dari `pay`/`status`/callback menambah kunci opsional:
  `actual_cost` (Decimal, potongan vendor), `payload` (jawaban mentah sebagai
  teks), dan status baru `:refunded` (vendor membatalkan; lihat Peninjauan).
- `catalog(config)` → `{:ok, [%{code, name, category_hint, price, admin, commission, status}]}`
  (opsional; tanpa kredensial).
- `prices(credentials, codes)` → `{:ok, %{code => %{price, status}}}` (opsional).
- `callback_ref(params)` → `{:ok, ref_id}` atau `:error` (opsional; untuk route
  callback tanpa token).

## Perubahan data

Migrasi baru; semua kolom lama tetap.

**`service_inquiries`**: `ref_id` (string, unik), `provider_admin` (decimal),
`provider_total` (decimal), `details` (string), `kind` (`bill` | `customer`,
untuk cek pelanggan token).

**`service_products`**: `api_extra_fee` (decimal, default 0, "Biaya tambahan
toko (akun API)", per lembar, hanya untuk tagihan), `provider_price` (decimal),
`provider_status` (`normal` | `gangguan` | `kosong` | `tidak_ditemukan`),
`provider_checked_at` (datetime).

**`service_transactions`**: `provider_code` (salinan kode vendor),
`quoted_cost` (modal perkiraan saat dicatat), `provider_payload` (text, maks
4.000 karakter, tanpa kredensial), `review_reason` (string), `reviewed_at`,
`reviewed_by_id`.

**Format ref** (unik di semua organisasi, ≤ 26 karakter): transaksi
`Z<store_id><yymmddHHMMSS><6 hex>`, inquiry `Q<store_id><yymmddHHMMSS><6 hex>`;
dibuat ulang bila bentrok dengan indeks unik. Berlaku untuk transaksi dan
inquiry baru; transaksi lama tidak diubah.

## Aturan inti yang berubah

- **Ref inquiry dipakai ulang.** `Services.inquire/3` membuat `ref_id` inquiry
  dan mengirimnya. `record/3` untuk tagihan lewat API memberi transaksi
  `ref_id` = `ref_id` inquiry itu (dan `inquiry_ref` = `ref_2` dikirim saat
  bayar, seperti Fase 1). Token PLN tidak memakai ulang ref inquiry-nya.
- **Harga tagihan lewat API** (semua adapter, termasuk tiruan): harga =
  `provider_total` + `api_extra_fee` × lembar; modal perkiraan = `provider_total`.
  Tagihan di akun manual tetap aturan Fase 0. Fake mengembalikan
  `provider_admin` 0 dan `provider_total` = tagihan; fixture test Fase 1
  disesuaikan.
- **Modal sebenarnya.** `quoted_cost` = modal saat dicatat. Saat jawaban
  membawa `actual_cost`, `cost` diganti nilainya; `deposit_used/1` dan laporan
  memakai `cost`. Bila `actual_cost` > modal isian produk, `provider_price`
  produk diperbarui (memunculkan tanda "Modal SBI naik").
- **Salinan.** `record/3` menyalin `provider_code` produk ke transaksi;
  `provider_request/1` membaca kode dari transaksi, bukan produk.
- **Token PLN lewat API wajib cek pelanggan.** `record/3` menolak tanpa
  `inquiry_id` kind `customer` yang berlaku, belum dipakai, untuk produk dan
  toko yang sama (`{:error, :inquiry_expired}`); nama pelanggan dan detail
  disalin ke transaksi.
- **Produk bermasalah.** Produk yang `provider_status`-nya terisi dan bukan
  `normal` tidak bisa dijual lewat akun API (`{:error, :product_unavailable}`);
  `provider_status` kosong (belum pernah diperiksa) boleh dijual.
- **`payload`** disimpan di `provider_payload` pada setiap jawaban.

## Membaca jawaban SBI

Prinsip: bila ragu, **pending lalu cek status** — "gagal" berarti uang
dikembalikan ke pelanggan, padahal saldo SBI mungkin terpotong.

**Bayar, topup, status, callback:**

| Jawaban | Hasil |
| --- | --- |
| Timeout, putus, HTTP 5xx, bukan JSON | pending, "Belum ada jawaban penyedia" |
| `status: 1` | success; `token_sn` dari `msg`; `actual_cost` dari `total_payment` |
| `status: 2` atau RC:02 | pending |
| `status: 11` | failed; pesan dari `KET:`/`msg` |
| RC:94 (Duplicate Reff ID), RC:08 (timeout biller) | pending + cek status |
| RC 05, 12, 14–17, 21–27, 30, 405–407, 47, 53, 85–87, 89, 96–99 | failed |
| RC 91, 92, 93, 95 | failed, pesan "Periksa kredensial / IP server di SBI" |
| RC tidak dikenal tanpa `status` | pending + cek status |
| RC:31 | `:refunded` |

**Inquiry dan cek pelanggan:**

| Jawaban | Hasil |
| --- | --- |
| Berhasil | `{:ok, ...}` |
| RC 05, 14, 15 | `:not_found` → "ID pelanggan tidak ditemukan." |
| RC:88 | `:already_paid` → "Tagihan ini sudah lunas." |
| RC:83, RC:16 | `{:rejected, "Tagihan belum tersedia."}`, `{:rejected, "Nomor meter diblokir."}` |
| RC 84, 98, 99, 08, timeout, jaringan | `:unavailable` |
| Lainnya | `{:rejected, keterangan SBI}` |

## Peninjauan (jawaban yang bertentangan)

`apply_result/2` tetap satu-satunya jalan ke hasil, dengan tambahan:

- transaksi `processing` + `:refunded` → failed (seperti `status: 11`);
- transaksi `success` + `:refunded`, atau transaksi `failed` + `:success` →
  status **tidak berubah**, `review_reason` diisi ("SBI melaporkan refund" /
  "SBI melaporkan berhasil setelah transaksi gagal") dan disiarkan;
- jawaban yang sama dengan status final → diabaikan seperti Fase 1.

`Services.resolve_review(transaction, admin, :refund | :keep)` — admin saja,
mengunci baris:

- `:refund` (hanya untuk `success`): status menjadi failed dan masuk "Perlu
  dikembalikan"; aturan kas Fase 1 berlaku apa adanya (failed API yang belum
  dikembalikan tetap dihitung di shift-nya; dikonfirmasi dari shift lain →
  kas keluar di sana dan `failed_after_shift_close`); `cost` tidak lagi
  mengurangi perkiraan saldo deposit;
- `:keep`: status tetap, `review_reason` dikosongkan;
- keduanya mengisi `reviewed_at`, `reviewed_by_id`. Error:
  `:forbidden`, `:not_in_review`.

## Callback

**`POST /api/ppob/callback`** (baru, tanpa token):

1. adapter yang punya `callback_ref/1` mengambil ref dari isi (SBI: `ref_1`);
2. transaksi API dicari dengan ref itu di semua organisasi; adapter akun
   transaksi harus adapter yang membaca ref; tidak ketemu → **404**;
3. organisasi toko transaksi dimasuki; adapter memverifikasi dengan kredensial
   akun itu — SBI: header `rqid` sama dengan password (perbandingan
   waktu-konstan) **dan** IP pengirim ada di `callback_ips`; gagal → **401**;
4. hasil diteruskan ke `apply_result/2` → **200** `{"ok": true}`.

**`POST /api/ppob/callback/:token`** tetap seperti Fase 1.

**IP pengirim.** Controller menghitung IP klien: `conn.remote_ip`, kecuali
permintaan datang dari alamat di `config :zahlungs, :trusted_proxies` — maka
IP paling kanan di `X-Forwarded-For` yang bukan proxy terpercaya. Controller
menaruhnya di peta header dengan kunci `"x-zahlungs-client-ip"`, selalu
menimpa nilai yang datang dari luar. Behaviour `verify_callback/3` tidak
berubah.

Form akun deposit menampilkan URL callback sesuai adapter: SBI
`url(~p"/api/ppob/callback")`, lainnya URL bertoken.

## Katalog

- **Pemilih produk** (form Produk layanan, bila organisasi punya akun deposit
  API aktif yang adapternya punya `catalog/1`): kotak cari → daftar (kode,
  nama, harga, status; tagihan: admin dan komisi SBI) → memilih mengisi kode
  vendor, nama, modal, kategori (tebakan dari grup SBI: Pulsa Reguler → pulsa,
  `* Data` → paket_data, PLN Prabayar → token_pln, PPOB dengan kode `PLN` →
  tagihan_pln). Daftar disimpan di tabel ETS milik proses di pohon supervisi,
  berlaku 10 menit.
- **"Perbarui dari SBI"** (daftar Produk layanan): memilih akun deposit API
  (bila lebih dari satu) → `prices/2` untuk semua produk berkode vendor →
  ringkasan (modal lama → baru, harga jual baru dengan margin tetap, status)
  → **Simpan perubahan** menerapkan `cost`, `provider_price`,
  `provider_status`, `provider_checked_at`. Kode yang tidak dikenal SBI →
  `tidak_ditemukan`. Tagihan hanya diperbarui statusnya.
- Tanda **"Modal SBI naik"** di daftar produk bila `provider_price` > `cost`.

## Layar

- **Layanan (kasir):** token PLN di akun API — nomor meter → **Cek pelanggan** →
  kartu nama dan daya → uang diterima → **Bayar**; kartu tagihan menampilkan
  tagihan, admin SBI, tambahan toko, total; bagian **Perlu ditinjau** hanya
  pemberitahuan ("SBI melaporkan refund, admin akan meninjau").
- **Akun deposit (admin):** pilihan penyedia SBI; kredensial Member ID, PIN,
  Password; URL callback; Tes koneksi dan Ambil saldo (`balance`); bagian
  **Perlu ditinjau** dengan tombol "Batalkan dan kembalikan uang" dan "Tetap
  berhasil".
- **Produk layanan (admin):** pemilih SBI; kolom "Biaya tambahan toko (akun
  API)" untuk tagihan; tombol "Perbarui dari SBI"; tanda status dan "Modal SBI
  naik".
- **Struk:** token PLN dalam kelompok 4 digit, nama, daya; tagihan seperti
  Fase 1.

## Pengujian

Semua tanpa SBI, lewat client tiruan yang memutar jawaban contoh dari dokumen.

- **Adapter:** `sign` dibandingkan dengan nilai yang dihitung dari contoh;
  pembacaan SN, jumlah bulan, periode, modal dari contoh PDF dan Postman; setiap
  baris tabel pemetaan (termasuk RC:94, RC:08, RC:31, RC tidak dikenal, timeout,
  HTTP 500, bukan JSON); `callback_ref/1`; `verify_callback/3` (`rqid` salah, IP
  salah, IP dari `X-Forwarded-For` tanpa proxy terpercaya).
- **Inti:** ref inquiry dipakai ulang saat bayar; token PLN wajib cek
  pelanggan; harga tagihan = total + tambahan × lembar; `cost` diganti
  `actual_cost` dan perkiraan saldo deposit mengikutinya; `provider_code`
  tersalin dan dipakai walau produk diubah; produk gangguan ditolak; peninjauan
  (`:refunded` pada success, success pada failed, `:refund` menyeimbangkan kas
  termasuk setelah shift tutup, `:keep`, bukan admin ditolak).
- **Callback:** kedua route; ref milik organisasi lain hanya bisa disentuh
  dengan kredensial akun itu; ref tidak dikenal 404.
- **Layar (LiveDriver):** cek pelanggan token, kartu tagihan, pemilih katalog,
  Perbarui dari SBI, Perlu ditinjau.
- Test Fase 0/1 tetap lulus (fixture tagihan API disesuaikan dengan aturan
  harga baru).

## Uji coba dengan deposit kecil

Ditulis di `docs/DEPLOYMENT.md` sebagai daftar periksa:

1. Server di VPS dengan HTTPS dan IP tetap; IP didaftarkan ke SBI;
   `https://<domain>/api/ppob/callback` terdaftar di SBI.
2. Akun deposit SBI: isi kredensial → **Tes koneksi** → **Ambil saldo**.
3. Produk lewat pemilih SBI: pulsa nominal terkecil, token PLN 20.000, tagihan
   PLN.
4. **Cek tagihan** dan **Cek pelanggan** token (tidak memotong saldo).
5. Satu pulsa kecil → cocokkan SN, potongan, callback di log.
6. Satu token PLN 20.000 ke meter sendiri.
7. Satu tagihan PLN milik sendiri.
8. **Pencocokan saldo** Zahlungs dengan saldo SBI → selisih nol.

## Asumsi yang menunggu jawaban SBI

| Asumsi | Bila salah |
| --- | --- |
| `sign` untuk `status` dan `balance` memakai string kosong untuk `product_code`/`customer_id` (dan `ref_1` untuk saldo) | Tes koneksi gagal RC:93; ganti rumus di `Sbi.Sign` |
| `Jml bulan` dan `Blth` dibaca dari `msg` bila tidak ada di JSON; tak terbaca → 1 lembar, periode kosong | Biaya tambahan per lembar kurang untuk tagihan > 1 bulan; struk tanpa periode |
| Balasan callback cukup HTTP 200; SBI mengulang bila gagal | Callback dianggap gagal oleh SBI; pengecek status tetap menyelesaikan |
| RC:31 berarti saldo dikembalikan SBI | Peninjauan tetap meminta keputusan admin; tidak ada perubahan otomatis |
| Respons gagal (RC di tabel "failed") tidak memotong saldo | Pencocokan saldo akan menunjukkan selisih; pindahkan RC itu ke pending |
| `ref_1` boleh sampai 26 karakter | Pendekkan format ref |

## Di luar cakupan

- Produk PPOB lain (BPJS, PDAM, e-wallet, dll.).
- Sinkron harga otomatis terjadwal dan tabel katalog vendor.
- Lebih dari satu vendor sekaligus, pemilihan vendor termurah.
- Rekonsiliasi massal lewat `/api/history`.
- Penyamaran token callback di log request (tidak relevan untuk route tanpa
  token).
