# Desain — Piutang (kasbon) di Kasir

Tanggal: 2026-10-31 · Status: menunggu tinjauan
Branch: `feat/kasir-piutang` (dari `master`)

## Tujuan

Pelanggan yang dikenal toko bisa **membawa barang sekarang dan membayar
belakangan**, sekaligus atau dicicil (termin). Toko tahu setiap saat siapa
berutang berapa, nota mana yang belum lunas atau lewat jatuh tempo, dan riwayat
setiap pembayarannya.

Berhasil bila:

1. Utang seorang pelanggan tidak pernah melewati limit yang diberikan admin,
   juga bila dua tablet menjual ke pelanggan yang sama bersamaan.
2. Uang laci shift tetap cocok: uang muka dan pelunasan tunai masuk laci shift
   yang menerimanya; non-tunai tidak.
3. Setiap pelunasan tercatat (tidak pernah ditimpa) dan kartu piutang
   pelanggan menunjukkan saldo berjalan serta nota yang dilunasinya.

Di luar cakupan: jadwal cicilan per termin, bunga/denda keterlambatan,
pengingat WA/SMS, piutang untuk transaksi Layanan (PPOB), poin/member, impor
pelanggan.

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Pelanggan | Daftar pelanggan per organisasi (`customers`), bukan nama bebas per nota |
| Siapa yang memberi piutang | Kasir mana pun, selama utang pelanggan tidak melewati limitnya |
| Limit | Diisi admin per pelanggan; bawaan 0 = tidak boleh berutang. Pelanggan baru dari layar kasir selalu limit 0 |
| Uang muka | Boleh, tunai, 0 sampai kurang dari total; masuk laci shift nota |
| Pelunasan | Per pelanggan (bukan per nota), boleh sebagian; dialokasikan ke nota terlama dulu |
| Cara bayar pelunasan | Tunai (masuk laci) dan QRIS/kartu/transfer (dicatat, tidak masuk laci) |
| Cabang | Satu daftar pelanggan per organisasi; utang dari toko A boleh dilunasi di toko B (uang masuk laci B) |
| Omzet | Dihitung saat dijual, seperti penjualan biasa; uang yang belum diterima ada di laporan piutang |
| Jatuh tempo | Satu tanggal per nota; bawaan hari ini + 30 hari (tanggal lokal toko), bisa diubah, tidak boleh sebelum hari ini |
| Riwayat | Kartu piutang per pelanggan: nota dan pelunasan kronologis dengan saldo berjalan |
| Penyimpanan alokasi | Tidak disimpan; dihitung saat dibaca (nota terlama dulu) dari nota dan pelunasan |

## Data

### `customers` (milik organisasi, ber-`organization_id`, dijaga `Repo`)

| Kolom | Isi |
| --- | --- |
| `organization_id` | dari `Organizations.put_organization/1` di changeset |
| `name` | wajib, maks. 80 karakter, unik per organisasi (tanpa membedakan huruf besar/kecil) |
| `phone` | opsional, maks. 20 karakter |
| `note` | opsional, maks. 255 karakter |
| `credit_limit` | decimal(12,2) ≥ 0, bawaan 0; hanya admin yang mengubah |
| `active` | bawaan true; nonaktif = tidak bisa berutang lagi, tetap bisa melunasi |

### `sales` (kolom baru)

| Kolom | Isi |
| --- | --- |
| `customer_id` | null untuk penjualan biasa; wajib untuk `payment_method = "credit"` |
| `due_date` | date (lokal toko); wajib untuk `credit`, null selainnya |

`Sale.payment_methods/0` mendapat `"credit"`. Untuk nota piutang
`amount_paid` = uang muka tunai, `change_due` = 0. **Utang nota** =
`total − amount_paid`.

### `customer_payments` (per toko seperti `sales`, tanpa `organization_id`)

| Kolom | Isi |
| --- | --- |
| `customer_id` | pelanggan yang membayar |
| `store_id`, `shift_id`, `user_id` | shift terbuka kasir penerima, tokonya, kasirnya (bukan dari input) |
| `amount` | decimal(12,2) > 0 |
| `payment_method` | `cash` / `qris` / `card` / `transfer` |
| `note` | opsional, maks. 255 karakter |
| `cancelled_at`, `cancelled_by_id`, `cancel_reason` | diisi saat admin membatalkan |
| `inserted_at` | waktu diterima |

### `cash_movements`

Kategori baru `customer_refund` (keluar): kelebihan bayar pelanggan yang
diuangkan; dicatat oleh `Customers.refund_overpayment/3`, tidak diketik manual.

## Aturan (context baru `Zahlungs.Customers`)

**Nota piutang yang berlaku** = nota `credit` berstatus `completed` (yang
diretur atau di-void tidak lagi dihitung). **Pelunasan yang berlaku** =
`cancelled_at` kosong.

- **Saldo** `balance(customer)` = Σ utang nota berlaku − Σ pelunasan berlaku +
  Σ `customer_refund` (kelebihan yang sudah diuangkan ke pelanggan itu).
  Positif = utang; negatif = **lebih bayar**. Dihitung dari data, tidak
  disimpan.
- **Alokasi** (untuk tampilan): jumlah semua pelunasan berlaku dibagikan ke
  nota berlaku urut waktu dibuat (terlama dulu). Tiap nota: **Lunas**, atau
  **Sisa Rp X**; **lewat jatuh tempo** bila sisa > 0 dan `due_date` sebelum
  tanggal lokal hari ini (toko nota itu).
- Pelanggan dan pelunasan hanya dari organisasi sendiri; pelanggan organisasi
  lain → `Ecto.NoResultsError` / `{:error, :not_found}`.

Fungsi:

- `list_customers(opts)` (cari nama/HP, hanya aktif / semua, dengan saldo),
  `get_customer!/1`, `create_customer(user, attrs)` (kasir: `credit_limit`
  diabaikan, selalu 0; admin: boleh diisi), `update_customer(user, customer,
  attrs)` (admin saja; selain itu `{:error, :unauthorized}`),
  `set_active/3` (admin).
- `balance(customer)`, `available_credit(customer)` = `credit_limit −
  balance`.
- `lock_for_credit(customer_id, debt)` — dipanggil **di dalam transaksi
  penjualan**: kunci baris pelanggan (`FOR UPDATE`), hitung ulang saldo dari
  database, lalu `{:ok, customer}` bila aktif dan `balance + debt ≤
  credit_limit`; selain itu `{:error, :customer_inactive}` /
  `{:error, :over_credit_limit}`.
- `receive_payment(user, customer_id, attrs)` — butuh shift terbuka
  (`{:error, :no_open_shift}`); kunci pelanggan, hitung ulang saldo;
  `amount` > 0 dan ≤ saldo, selain itu `{:error, :over_balance}`; cara bayar
  harus valid. Toko = toko shift.
- `cancel_payment(user, payment_id, reason)` — admin saja; alasan wajib;
  kunci pelunasan dan shift penerimanya; shift harus masih terbuka, selain itu
  `{:error, :shift_closed}`; sudah dibatalkan → `{:error, :already_cancelled}`.
- `refund_overpayment(user, customer_id, amount)` — admin saja, butuh shift
  terbuka; `amount` > 0 dan ≤ lebih bayar; dicatat sebagai `customer_refund`
  kas keluar di shift admin, dengan `customer_id` pada catatannya (kolom baru
  `cash_movements.customer_id`, null untuk kategori lain).
- `ledger(customer)` — baris kronologis: nota (+utang, kode, toko, kasir,
  jatuh tempo, status/sisa), pelunasan (−, cara bayar, toko, kasir, nota yang
  dilunasi/dicicil; yang dibatalkan ikut tampil dicoret beserta alasannya, tidak
  memengaruhi saldo), pengembalian kelebihan (+); masing-masing dengan saldo
  berjalan.
- `receivables_report(scope, opts)` — per pelanggan dengan saldo > 0: saldo,
  nota terlama yang belum lunas, jumlah lewat jatuh tempo, pelunasan terakhir;
  filter `:overdue`; total piutang organisasi. `payments_report(scope, from,
  to)` — pelunasan berlaku per cara bayar dan per toko (toko dibatasi
  `Stores.store_ids/0` / toko scope).

### Perubahan di `Sales`

- `create_sale(user, cart, payment)` dengan `payment_method: "credit"`:
  butuh `customer_id` dan `due_date`; `amount_paid` = uang muka (kosong = 0),
  harus `< total` (uang muka ≥ total → `{:error, :down_payment_too_high}`;
  pakai bayar tunai biasa); `due_date` sebelum hari ini (lokal toko shift) →
  `{:error, :invalid_due_date}`. Di dalam transaksi yang sama dengan
  penguncian shift: `Customers.lock_for_credit(customer_id, total −
  amount_paid)`.
- `return_sale`: aturan peran tetap (admin). Untuk nota piutang yang dikembalikan
  ke pelanggan hanya **uang muka**: bila shift nota sudah tutup dan uang muka
  > 0, dicatat `refund` kas keluar sebesar uang muka di shift yang memproses.
- `void_sale`: aturan tetap (kasir selama shift nota terbuka, admin kapan
  saja).
- Retur/void nota yang sudah dicicil membuat saldo bisa negatif (lebih bayar).
  Lebih bayar otomatis mengurangi utang nota piutang berikutnya (lewat saldo)
  atau diuangkan admin dengan `refund_overpayment/3`.

### Perubahan di `Shifts`

- `expected_cash/1` = yang sekarang + uang muka nota piutang shift itu (nota
  berlaku) + pelunasan tunai berlaku yang diterima di shift itu.
  `customer_refund` sudah ikut sebagai kas keluar.
- `shift_summary/1` menambah: penjualan piutang (jumlah total nota, uang muka
  tunai) dan pelunasan piutang (tunai, non-tunai). Penjualan piutang **tidak**
  masuk "non-tunai" ringkasan.
- `close_shift` tidak berubah: piutang tidak menahan shift.

### Laporan penjualan

Nota piutang dihitung di omzet, diskon, pajak, HPP dan laba pada hari dijual,
seperti penjualan lain. Rincian per metode bayar mendapat baris **Piutang**.
Home tidak berubah.

## Layar

### Kasir (`CashierLive`)

- **Metode bayar Piutang** di panel bayar. Memilihnya menampilkan pencarian
  pelanggan (nama/HP, hanya aktif) dan **+ Pelanggan baru** (nama, HP; limit
  0 — pesan: "Limit piutang diatur admin."). Setelah pelanggan dipilih:
  utang sekarang, limit, sisa limit; isian **Uang muka (tunai)** (bawaan
  kosong = 0) dan **Jatuh tempo** (bawaan +30 hari). **Selesaikan** nonaktif
  bila utang nota ini > sisa limit ("Melebihi limit piutang Rp X."). Error
  dari context ditampilkan sebagai flash.
- **Piutang** (tombol di dekat "Ditunda"): cari pelanggan → kartu piutang
  ringkas (saldo, nota belum lunas dengan sisa dan jatuh tempo) → isian
  **Terima pelunasan**: jumlah (bawaan: saldo), cara bayar, catatan →
  **Terima**. Butuh shift terbuka. Setelah berhasil: flash dan tautan struk
  pelunasan.
- Ponsel: keduanya di panel yang sama dengan pola layar kasir sekarang.

### Struk

- Nota piutang: nama pelanggan, uang muka, "Sisa utang nota ini", jatuh tempo,
  total utang pelanggan setelah transaksi.
- Pelunasan (`/customer_payments/:id/receipt`, yang login, toko/organisasi
  sendiri): pelanggan, jumlah, cara bayar, saldo sebelum dan sesudah, nota yang
  menjadi lunas.

### Admin

- `/admin/customers`: daftar (cari, saldo, limit, aktif), tambah/ubah (nama,
  HP, catatan, limit), aktif/nonaktif.
- `/admin/customers/:id`: kartu piutang lengkap, **Batalkan** pelunasan (dengan
  alasan; hanya bila shift penerimanya masih terbuka), **Kembalikan kelebihan**
  bila saldo negatif. Kasir membuka kartu piutang dari layar kasir (tampilan
  ringkas di panel Piutang), bukan halaman admin.
- `/reports/receivables`: total piutang, daftar per pelanggan, filter "Lewat
  jatuh tempo", pelunasan per periode per cara bayar dan per toko.

Rute admin di `live_session` admin; handler memeriksa ulang peran untuk
batalkan pelunasan, kembalikan kelebihan, dan ubah limit.

## Tes

Context (`Customers`, `Sales`, `Shifts`):

- limit: utang tepat di limit boleh, satu rupiah di atasnya ditolak; limit 0
  ditolak; pelanggan nonaktif ditolak; struct pelanggan basi tidak memengaruhi
  (pemeriksaan dari database di dalam transaksi);
- kasir membuat pelanggan → limit 0 walau mengirim `credit_limit`; kasir tidak
  bisa mengubah limit;
- nota piutang: uang muka 0 boleh; uang muka ≥ total ditolak; `due_date`
  kemarin ditolak; tanpa pelanggan ditolak; uang muka masuk `expected_cash`;
  nota masuk `sales_report`;
- pelunasan: sebagian lalu lunas; melebihi saldo ditolak; tanpa shift ditolak;
  tunai masuk `expected_cash` shift penerima, non-tunai tidak; diterima di toko
  lain masuk laci toko itu;
- alokasi dan kartu piutang: pelunasan membagi ke nota terlama dulu; saldo
  berjalan benar; nota lewat jatuh tempo ditandai memakai tanggal lokal toko;
- batalkan pelunasan: admin saja; shift tutup ditolak; saldo dan
  `expected_cash` kembali; tampil dicoret di kartu;
- retur nota piutang yang sudah dicicil → lebih bayar; nota piutang berikutnya
  memakai lebih bayar itu; `refund_overpayment` mencatat kas keluar
  `customer_refund` dan mengembalikan saldo ke 0; retur setelah shift tutup
  mencatat `refund` sebesar uang muka saja;
- pelanggan organisasi lain tidak bisa dibaca, dijuali, maupun dilunasi.

Layar (lewat `ZahlungsWeb.LiveDriver`):

- pilih Piutang + pelanggan → menyelesaikan penjualan; melewati limit
  menampilkan pesan dan tidak menjual;
- tambah pelanggan baru dari kasir;
- terima pelunasan dari panel Piutang;
- admin: ubah limit, batalkan pelunasan, kembalikan kelebihan; kasir mendapat
  penolakan untuk halaman admin (`get/2`).
