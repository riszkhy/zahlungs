# Desain — Rekonsiliasi Transaksi Layanan ke SBI

Tanggal: 2026-11-12 · Status: menunggu tinjauan
Branch: `feat/rekonsiliasi-layanan` (dari `master`)
Dibangun di atas: `docs/superpowers/specs/2026-10-21-layanan-ppob-sbi-design.md`
(yang menaruh "Rekonsiliasi massal lewat `/api/history`" di luar cakupan).

## Tujuan

Admin organisasi bisa mencocokkan layanan api satu akun deposit dengan riwayat
transaksi Smart Biller Indonesia (SBI) untuk satu tanggal, melihat mana yang
tidak cocok, dan membetulkannya dari laporan itu.

Hari ini yang ada hanya pencocokan **saldo** (`Deposits.reconcile/4`): bila saldo
selisih, admin tidak tahu transaksi mana penyebabnya.

Berhasil bila:

1. Setiap layanan api yang terkirim pada tanggal itu dan setiap transaksi SBI pada
   tanggal itu masuk tepat satu golongan.
2. Perbaikan tidak membuka jalur kedua untuk status: semuanya lewat cek status ke
   SBI dan `Services.apply_result/2`, sehingga kas shift, refund, peninjauan, dan
   komisi tetap mengikuti aturan yang ada.
3. Tidak ada pembayaran yang terkirim dari halaman ini.
4. Laporan yang tidak lengkap tidak pernah ditampilkan.
5. Hanya admin organisasi itu yang bisa membuka laporan dan menekan tombolnya.

Di luar cakupan: pencocokan otomatis terjadwal, menyimpan hasil laporan, rentang
lebih dari satu hari, akun manual, penyedia selain SBI, membuat transaksi Zahlungs
dari baris "Hanya di SBI", dan ekspor.

## Keputusan yang sudah diambil

| Topik | Keputusan |
|---|---|
| Tujuan | Cocokkan lalu perbaiki dari laporan |
| Cara memperbaiki | Lewat jalur yang ada: cek status ke SBI, lalu `apply_result` |
| Sumber data | Riwayat SBI hanya untuk menemukan yang tidak cocok; status diambil ulang lewat `status` |
| Penyimpanan | Tidak ada tabel baru; laporan dihitung saat diminta |
| Rentang | Satu tanggal per laporan |

## Riwayat SBI

Dari dokumentasi Postman SBI (folder **API SIGN**, permintaan **HISTORY**):

- `POST <base_url>/api/history`, header `rqid`, isi JSON `mmid` (Member ID),
  `date` (`YYYY-MM-DD`), `page`, `per_page` (paling banyak 1000), `status`
  (kosong = semua; 1 berhasil, 11 gagal).
- Jawaban: `data.data` berisi baris dengan `ref_1`, `ref_2`, `product_code`,
  `product_name`, `customer_id`, `status`, `status_label`, `created_at`, `price`,
  `admin`, `total_price`, `total_payment`, `msg`, dan `detail`; `data.meta` berisi
  `current_page`, `last_page`, `total`.

Zahlungs meminta `per_page` 1000 dan `status` kosong, halaman demi halaman sampai
`last_page`, paling banyak 20 halaman. Lebih dari itu dianggap galat, bukan laporan
yang terpotong.

### Membaca satu baris

`Sbi.Reply.history_row/1` (murni) mengubah satu baris menjadi:

```elixir
%{ref: "Z...", status: :success | :failed | :refunded | :pending,
  inquiry?: boolean, cost: Decimal.t() | nil, product_code: binary | nil,
  customer_id: binary | nil, at: NaiveDateTime.t() | nil}
```

Aturannya sama dengan `Reply.transaction/1`, tidak ditulis ulang:

- Status 1 berhasil, 11 gagal, selain itu diproses.
- RC di `msg` menentukan: RC:31 refund, RC:94/08/02 diproses, RC konfigurasi
  diproses.
- Baris cek tagihan dikenali dari `msg` ("INQ …" atau "… CEK TAGIHAN …"), menjadi
  `inquiry?: true`.
- Modal dari `total_payment`, atau `HRG:` di `msg`.
- Angka berupa teks dibaca sebagai `Decimal`; yang tidak terbaca menjadi `nil`.

`at` dari `created_at` (waktu SBI, dianggap WIB) diubah ke UTC dengan offset
bawaan, hanya untuk ditampilkan.

## Pencocokan

### Data yang dibandingkan

Untuk akun deposit `A` (mode `api`) dan tanggal `D`:

- **Riwayat SBI hari D:** semua halaman.
- **Layanan Zahlungs:** layanan dengan `deposit_account_id = A`, `channel = "api"`,
  dan `inserted_at` pada tanggal D menurut zona bawaan (WIB, `LocalTime` tanpa
  cabang, karena satu akun bisa dipakai cabang di zona berbeda). Ditambah layanan
  akun A dari tanggal lain yang `ref_id`-nya ada di riwayat SBI hari D.
- **Riwayat SBI hari D+1:** diambil hanya bila ada layanan Zahlungs hari D yang
  terkirim tetapi belum ketemu, khusus untuk mencarinya. Baris D+1 lainnya tidak
  dilaporkan.

Baris cek tagihan (`inquiry?: true`) dikeluarkan sebelum dicocokkan: tidak dihitung
dan tidak dilaporkan. Bila satu ref punya lebih dari satu baris bukan cek tagihan,
yang dipakai adalah yang `created_at`-nya paling akhir.

Layanan yang belum pernah terkirim (`sent_at` kosong) tidak dicocokkan dan tidak
dilaporkan.

### Golongan

Setiap pasangan atau baris tunggal masuk tepat satu golongan:

| Golongan | Syarat | Tombol |
|---|---|---|
| Cocok (`matched`) | Status final sama (berhasil–berhasil, gagal–gagal atau refund) dan, bila berhasil, modal sama atau potongan SBI kosong; atau keduanya masih diproses | — |
| Ikuti SBI (`follow`) | Di Zahlungs `processing`, di SBI berhasil, gagal, atau refund | **Ikuti SBI** |
| Bertentangan (`conflict`) | Di Zahlungs berhasil, di SBI gagal atau refund; atau di Zahlungs gagal, di SBI berhasil | **Tinjau** |
| Belum final di SBI (`pending_there`) | Di Zahlungs final, di SBI masih diproses | **Cek status** |
| Selisih modal (`cost_diff`) | Keduanya berhasil, modal Zahlungs ≠ potongan SBI | — |
| Hanya di Zahlungs (`ours_only`) | Terkirim, tidak ada di riwayat SBI hari D maupun D+1 | **Cek status** |
| Hanya di SBI (`theirs_only`) | Baris SBI hari D yang ref-nya tidak cocok dengan layanan akun A mana pun | — |

Layanan yang sedang ditinjau (`review_reason` terisi) tetap digolongkan seperti di
atas, dengan tanda "Sedang ditinjau", dan tanpa tombol: keputusannya di halaman
akun deposit.

### Ringkasan

Jumlah baris per golongan, jumlah selisih modal (potongan SBI − modal Zahlungs,
pada `cost_diff`), dan jumlah potongan baris `theirs_only` yang berhasil.

## Perbaikan

`Services.recheck_row(admin, row)`, untuk layanan `row.ours`:

- Hanya untuk admin. Peran dibaca dari database, bukan dari socket.
- Layanan harus `channel = "api"`, sudah terkirim, dan milik cabang organisasi
  admin. Layanan organisasi lain menjadi `Ecto.NoResultsError` (404).
- Status apa pun: bertanya ke penyedia lewat `Deposits.connection/1` dan
  `adapter.status/2`, lalu `apply_result/2`, sama seperti `ask_status/1`.
  - Layanan `processing` diselesaikan.
  - Layanan final yang bertentangan hanya mendapat `review_reason`.
- **Tidak pernah mengirim.** Layanan yang belum terkirim menghasilkan
  `{:error, :not_sent}`; di sini tidak memanggil `send_payment`.
- Mengembalikan `{:ok, row}` (golongan baru dari layanan terbaru dan `row.theirs`)
  atau `{:error, :not_admin | :not_api | :not_sent}`.

"Ikuti SBI", "Tinjau", dan "Cek status" memanggil fungsi yang sama. Setelahnya,
golongan baris itu dihitung ulang dari layanan yang baru dan baris SBI yang sudah
ada, tanpa mengambil ulang riwayat.

## Galat

- Akun manual, atau penyedia tanpa `history/3`: `{:error, :unsupported}`, dengan
  pesan "Rekonsiliasi hanya untuk akun api SBI." Penyedia palsu (`fake`) tidak
  punya `history/3`.
- Satu halaman gagal (timeout, HTTP 5xx, bukan JSON, jawaban galat SBI, lebih dari
  20 halaman): seluruh laporan `{:error, :unavailable}`, pesan "Riwayat SBI belum
  bisa diambil, coba lagi." Tidak ada laporan setengah jadi.
- Kredensial tidak terbaca: `{:error, :credentials}`, pesan "Kredensial penyedia
  tidak bisa dibaca. Isi ulang di halaman akun deposit."
- Tanggal tidak valid atau setelah hari ini (WIB): ditolak sebelum memanggil SBI.
- Cek status yang tidak dijawab SBI: hasilnya `pending`, baris tetap di
  golongannya; pesan "SBI belum menjawab, coba lagi."

## Arsitektur

- **`Services.Provider`:** callback opsional `history(credentials, date, page)`
  `:: {:ok, %{rows: [map], last_page: pos_integer}} | {:error, :timeout | :unavailable}`.
  Kredensial yang tidak terbaca sudah ditolak oleh `Deposits.connection/1`.
- **`Services.Provider.Sbi.history/3`:** `POST history` lewat `Sbi.Client` yang
  sudah ada, isi `%{"mmid" => member_id, "date" => iso_date, "page" => page,
  "per_page" => 1000, "status" => ""}`, header `rqid` = password akun, tanpa
  `sign`. Baris dibaca oleh `Reply.history_row/1`.
- **`Services.Reconciliation`** (dipanggil lewat `Services`, seperti `Commissions`):
  - `compare(ours, day, next_day) :: %{rows: [row], summary: summary}`,
    `classify(ours, theirs) :: row`, dan `summarize(rows) :: summary`, murni.
  - `run(admin, account, date, today)`: memeriksa admin dan akun, mengambil semua
    halaman (dan D+1 bila perlu), membaca layanan, lalu `compare/3`.
- **`Services.reconcile(admin, account, date)`**,
  **`Services.recheck_row(admin, row)`**, dan
  **`Services.reconciliation_summary(rows)`**: pintu masuk dari web.
- **`ZahlungsWeb.DepositLive.Reconcile`**, rute
  `live "/admin/deposits/:id/reconcile", DepositLive.Reconcile, :index` di
  `live_session` admin, ditambah tombol "Rekonsiliasi" di halaman akun deposit
  (hanya akun api).

Bentuk `row`:

```elixir
%{kind: :matched | :follow | :conflict | :pending_there | :cost_diff | :ours_only | :theirs_only,
  ref: binary,
  ours: %Transaction{} | nil,    # kolom yang ditampilkan saja dipakai halaman
  theirs: history_row | nil,
  in_review?: boolean}
```

## Halaman

- Form tanggal (bawaan kemarin, WIB) dan tombol **Cocokkan**. Riwayat diambil
  hanya saat tombol ditekan, tidak saat halaman dibuka.
- Ringkasan: jumlah per golongan, total selisih modal, total "Hanya di SBI".
- Daftar: yang tidak cocok lebih dulu (urutan golongan seperti tabel, lalu waktu),
  yang cocok di bagian yang bisa dibuka. Tiap baris: waktu, kode transaksi atau
  ref, produk, nomor pelanggan, status di Zahlungs dan di SBI, modal dan potongan
  SBI, tanda "Sedang ditinjau", dan tombolnya.
- Tombol menampilkan hasil sebagai flash dan memperbarui baris itu saja.
- Kartu, bukan tabel; tidak melebar di 375 px.
- Handler menerima id sebagai angka maupun teks.

## Keamanan dan privasi

- Rute di `live_session` admin (plug dan `on_mount`), dan `reconcile`/`recheck_row`
  memeriksa ulang peran admin dari database.
- Akun diambil lewat `Deposits.get_account!/1`, yang dijaga `Zahlungs.Repo`
  (organisasi admin). Layanan selalu disaring dengan `deposit_account_id` akun itu.
- Data yang tampil adalah milik organisasi itu sendiri (nomor pelanggan dan kode
  produk), sama seperti halaman Riwayat layanan. Jawaban mentah SBI tidak
  ditampilkan.
- Tes tidak memanggil SBI: `Sbi.StubClient`. Semua nilai di tes dan dokumen
  rekaan; database dev berisi transaksi pelanggan sungguhan dan nilainya tidak
  disalin ke mana pun.

## Asumsi yang dipastikan saat uji pertama dengan SBI asli

| Asumsi | Bila salah |
|---|---|
| `history` memakai header `rqid` = password, tanpa `sign` | Laporan gagal diambil; ubah header |
| `date` riwayat SBI adalah tanggal WIB | Baris dekat tengah malam salah golongan; uang tidak berubah |
| `total_payment` pada riwayat sama artinya dengan pada `status` | Selisih modal palsu; ganti field |
| `ref_1` pada riwayat sama dengan `ref_1` yang dikirim Zahlungs | Semua baris "Hanya di …"; baca ref dari field lain |

Langkah pengujiannya ditambahkan ke daftar periksa di `docs/DEPLOYMENT.md`.

## Pengujian

`test/zahlungs/services/provider/sbi_reply_test.exs` dan `sbi_test.exs` (sudah ada):

- `history_row/1`: status 1/2/11, RC:31 refund, RC:94 diproses, baris INQ dan
  "CEK TAGIHAN", `total_payment` teks, angka yang tidak terbaca menjadi `nil`.

`test/zahlungs/services/reconciliation_test.exs`:

- `compare/2` (tanpa database): setiap golongan; ref dengan baris cek tagihan dan
  baris bayar; dua baris bayar untuk satu ref (yang terakhir dipakai); layanan
  belum terkirim tidak muncul; layanan dari tanggal lain yang ketemu lewat ref;
  layanan yang ditinjau mendapat tanda tanpa mengubah golongan; ringkasan.
- `reconcile/3` dengan `Sbi.StubClient`: tiga halaman dibaca semua; satu halaman
  gagal membatalkan laporan; lebih dari 20 halaman ditolak; D+1 diambil hanya bila
  ada yang belum ketemu; layanan organisasi lain dan akun lain tidak ikut; akun
  manual dan penyedia palsu `:unsupported`; kasir ditolak; isi permintaan berisi
  `mmid`, `date`, `page`, `per_page`, header `rqid`, tanpa `sign`.
- `recheck_row/2`: layanan diproses diselesaikan; berhasil di sini, gagal di SBI masuk
  Peninjauan tanpa mengubah status; layanan belum terkirim `:not_sent` dan tidak
  ada permintaan `topup`/`payment`; kasir `:not_admin`; layanan organisasi lain
  404; layanan manual `:not_api`.

`test/zahlungs_web/live/deposit_live/reconcile_test.exs`:

- Akses dengan `get/2`: tamu, kasir ditolak; admin masuk.
- `LiveDriver`: membuka halaman tidak memanggil SBI; "Cocokkan" menampilkan
  ringkasan dan golongan; galat menampilkan pesan tanpa daftar; tanggal setelah
  hari ini ditolak; tombol memperbarui satu baris; id sebagai angka dan teks.

## Dokumen

`CLAUDE.md` (bagian PPOB through SBI), `docs/IA.md`, dan `docs/DEPLOYMENT.md`
(langkah uji pertama untuk asumsi di atas).
