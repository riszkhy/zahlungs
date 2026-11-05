# Desain — Monitoring Toko untuk Operator Platform

Tanggal: 2026-11-05 · Status: menunggu tinjauan
Branch: `feat/monitoring-toko` (dari `master`)

## Tujuan

Operator platform (`superadmin`) punya satu halaman untuk melihat keadaan semua
organisasi yang terdaftar di Zahlungs, supaya bisa menghubungi toko sebelum
berhenti memakai aplikasi, menagih tepat waktu, dan membantu ketika layanan
bermasalah. Halaman ini menjawab empat pertanyaan:

1. Toko mana yang masih aktif dan mana yang sudah sepi?
2. Seberapa besar usahanya?
3. Siapa yang perlu ditagih?
4. Di mana ada masalah layanan?

Berhasil bila:

1. Angka satu organisasi tidak pernah tercampur dengan organisasi lain.
2. Omzet dan saldo memakai aturan yang sama dengan laporan dan halaman deposit
   milik toko, bukan aturan kedua yang bisa berbeda.
3. Yang paling perlu ditangani selalu berada di urutan atas.
4. Halaman ini tidak menampilkan isi transaksi atau data pelanggan toko, dan
   hanya superadmin yang bisa membukanya.

Di luar cakupan: notifikasi atau peringatan otomatis, grafik, export, batas
"saldo menipis" yang bisa diatur, tabel ringkasan harian, tombol tindakan di
halaman ini, masuk sebagai pemilik toko, dan kesehatan server.

## Keputusan yang sudah diambil

| Topik | Keputusan |
|---|---|
| Tingkat tampilan | Per organisasi, bisa dibuka untuk rincian per cabang |
| Angka usaha | Total saja: omzet dan jumlah transaksi |
| Sifat halaman | Hanya membaca; persetujuan dan tagihan tetap di `/platform/organizations` |
| Cara menghitung | Saat halaman dibuka, dari tabel yang sudah ada |
| Saldo menipis | Hanya saldo perkiraan minus, karena belum ada aturan batasnya |

## Definisi

Semua waktu disimpan dalam UTC. "Sekarang" diberikan sebagai argumen `now`
supaya batas-batasnya bisa diuji.

### Keaktifan

Dihitung dari transaksi terakhir: penjualan atau layanan mana pun, apa pun
statusnya, karena penjualan yang kemudian dibatalkan tetap menandakan toko
sedang dipakai. Selisihnya dihitung dalam jam, bukan hari kalender, jadi tidak
bergantung pada zona waktu cabang. Tepat di batas masuk ke golongan yang lebih
aktif.

| Keaktifan | Syarat |
|---|---|
| Aktif (`active`) | Paling lama 7 × 24 jam lalu |
| Sepi (`quiet`) | Lebih dari 7 × 24 jam, paling lama 30 × 24 jam lalu |
| Tidur (`asleep`) | Lebih dari 30 × 24 jam lalu |
| Belum pernah (`never`) | Belum ada transaksi sama sekali |

- Keaktifan organisasi memakai transaksi terakhir dari semua cabangnya.
- Cabang nonaktif (`stores.active = false`) tampil berlabel "Nonaktif" tanpa
  lencana keaktifan, dan tidak dihitung dalam keterangan "1 dari 3 cabang sepi".
  Angkanya tetap ikut dalam total organisasi.
- Login terakhir hanya keterangan dan tidak memengaruhi keaktifan.

### Angka usaha

Periode 7 atau 30 hari terakhir (bawaan 30), yaitu `now − N × 24 jam` sampai
`now`.

- **Omzet barang:** jumlah `sales.total` dan banyaknya penjualan berstatus
  `completed`. Aturannya sama dengan `Sales.sales_report/3`. Jendela waktunya
  berbeda: laporan toko memakai hari lokal, halaman ini memakai jam mundur.
- **Layanan:** jumlah `service_transactions.price` dan banyaknya layanan
  berstatus `success`.

Barang dan layanan selalu ditampilkan terpisah, seperti di laporan toko.

### Tagihan

Hanya untuk organisasi berstatus `active`; status lain tidak punya lencana
tagihan. Tanggal hari ini memakai `LocalTime.today()` tanpa cabang, sama seperti
halaman Organisasi.

| Lencana | Syarat |
|---|---|
| Belum dicatat (`unrecorded`) | `paid_until` kosong |
| Lewat (`overdue`) | `paid_until` sebelum hari ini |
| Segera (`due_soon`) | `paid_until` dari hari ini sampai 7 hari ke depan |
| tanpa lencana (`ok`) | `paid_until` lebih dari 7 hari ke depan |

### Masalah layanan

Dihitung per cabang, lalu dijumlahkan ke organisasinya:

- **Tertahan:** `channel = "api"`, `status = "processing"`, dan sudah menunggu
  sejak dicatat selama batas `Services.awaiting_too_long?/2` (10 menit). Layanan
  manual tidak dihitung. Batasnya diambil dari satu tempat di `Services`, tidak
  ditulis ulang.
- **Perlu dikembalikan:** aturan yang sama dengan `Services.list_refunds_due/1`:
  `channel = "api"`, `status = "failed"`, `refunded_at` kosong, `review_reason`
  kosong.
- **Menunggu keputusan:** `review_reason` terisi.

Dihitung per organisasi:

- **Saldo minus:** akun deposit aktif yang saldo perkiraannya di bawah nol.
  Saldonya harus sama dengan `Deposits.estimated_balance/1`, yaitu jumlah
  `deposit_entries.amount` dikurangi jumlah `cost` layanan `processing` dan
  `success` pada akun itu. Tidak memanggil provider.

Sebuah organisasi "bermasalah" bila salah satu dari keempat angka ini lebih dari
nol.

## Arsitektur

Modul baru `lib/zahlungs/monitoring.ex`, `Zahlungs.Monitoring`. Ini satu-satunya
tempat pembacaan lintas organisasi untuk monitoring, dan hanya dipanggil dari
halaman `/platform`.

```elixir
Monitoring.overview(days, now \\ NaiveDateTime.utc_now())
# => %{rows: [row], summary: summary, at: now}

Monitoring.filter(rows, status: status, quick: quick, search: search)
# => rows yang cocok, urutannya tetap

Monitoring.activity(last_at, now)   # => :active | :quiet | :asleep | :never
Monitoring.billing(organization, today)
# => :unrecorded | :overdue | :due_soon | :ok | nil (organisasi tidak aktif)
```

Bentuk `row`:

```elixir
%{
  organization: %Organization{},
  owner_email: email | nil,
  activity: :active,
  billing: :overdue,
  last_transaction_at: naive | nil,
  last_login_at: naive | nil,
  open_shifts: 1,
  quiet_stores: 1,             # cabang aktif yang sepi, tidur, atau belum pernah
  active_stores: 3,
  sales_total: decimal, sales_count: 12,
  services_total: decimal, services_count: 4,
  stuck: 0, refunds_due: 1, in_review: 0, negative_deposits: 0,
  problem?: true,
  stores: [
    %{id:, name:, code:, active:, utc_offset_hours:, activity:, open_shifts:,
      last_transaction_at:, last_login_at:, sales_total:, sales_count:,
      services_total:, services_count:, stuck:, refunds_due:, in_review:}
  ],
  deposits: [%{id:, name:, balance:}]
}
```

`summary`:

```elixir
%{
  active_organizations: 10,
  sales_total: decimal,
  services_total: decimal,
  overdue: 2,
  with_problems: 1
}
```

Ringkasan selalu menghitung organisasi berstatus `active` pada periode terpilih,
tidak ikut saringan lain.

### Cara membaca data

`overview/2` menghitung semua organisasi sekali jalan:

1. `Organizations.list_organizations/0` untuk organisasi dan email pemiliknya.
2. Cabang semua organisasi: hanya kolom yang tertulis di `stores` pada bentuk
   `row`, ditambah `organization_id`.
3. Beberapa kueri agregat `GROUP BY store_id` dengan `store_id in ^ids`:
   transaksi terakhir, total periode, masalah layanan, shift buka.
4. Login terakhir: agregat `MAX(inserted_at)` per organisasi dan per cabang.
5. Akun deposit aktif dan saldo perkiraannya, dalam kueri agregat.

Jumlah kueri tetap, tidak bertambah mengikuti jumlah organisasi. Tabel penjualan
dan layanan sudah punya indeks `(store_id, inserted_at)`. Hasilnya digabung
dalam Elixir, dan organisasi tanpa data mendapat nol, bukan tidak muncul.

### Urutan

Satu peringkat per organisasi, yang lebih kecil di atas, lalu nama tanpa
membedakan huruf besar, lalu id:

| Peringkat | Syarat |
|---|---|
| 0 | Bermasalah |
| 1 | Tagihan lewat |
| 2 | Tidur |
| 3 | Sepi |
| 4 | Lainnya |

### Saringan

- **Status organisasi:** bawaan `active`; bisa semua status atau salah satunya.
  Nilai yang tidak dikenal dianggap semua status.
- **Tombol cepat**, satu yang aktif pada satu waktu: Semua; Sepi/Tidur (termasuk
  Belum pernah, karena sama-sama perlu dihubungi); Tagihan (Lewat, Segera, Belum
  dicatat); Masalah layanan.
- **Pencarian:** sebagian nama organisasi, tanpa membedakan huruf besar. Dicari
  dalam Elixir, jadi `%` dan `_` adalah teks biasa.

## Halaman

`ZahlungsWeb.PlatformLive.Monitoring`, rute `/platform/monitoring` di dalam
`live_session :require_platform_admin` yang sudah ada, sehingga plug dan
`on_mount` sama-sama berlaku. Menu "Monitoring" ditambahkan ke `platform_links/0`.
Halaman awal superadmin tetap `/platform/organizations`.

- **Atas:** kartu ringkasan (organisasi aktif, omzet barang, omzet layanan,
  tagihan lewat, organisasi bermasalah), saringan, dan keterangan "Angka per
  14.32. Muat ulang halaman untuk memperbarui."
- **Daftar:** kartu per organisasi, 25 per halaman dengan `.pagination`. Isinya
  nama, email pemilik, telepon, lencana, transaksi dan login terakhir, omzet,
  jumlah transaksi, shift buka, dan "1 dari 3 cabang sepi" bila ada.
- **Rincian:** tombol di kartu membuka daftar cabang dan akun deposit organisasi
  itu. Tidak ada kueri baru; datanya sudah ada di `row`.

Perhitungan berjalan saat halaman dibuka dan saat periode berganti. Status,
tombol cepat, pencarian, halaman, dan buka-tutup rincian hanya mengolah `rows`
yang sudah ada. Halaman tidak memperbarui diri sendiri.

Waktu di kartu organisasi memakai offset bawaan, sama seperti halaman Organisasi;
waktu di baris cabang memakai offset cabang itu. Semua kartu ditulis dengan
komponen yang tidak melebar di layar 375 px. Handler menerima id dan halaman
sebagai angka maupun teks. Periode selain 7 dan 30 dianggap 30.

## Keamanan dan privasi

- Modul ini memilih kolom secara eksplisit dan hanya mengambil agregat untuk
  transaksi. Yang tidak pernah dibaca: `credentials`, `provider_payload`,
  `provider_message`, `customer_ref`, `customer_name`, `customer_details`,
  `token_sn`, `bill_reference`, `meter_reading`, nama kasir, serta IP, posisi,
  dan browser dari `user_logins`.
- Yang berisi data toko tampil apa adanya hanya pada kolom yang sudah terlihat
  oleh operator di `/platform/organizations`, yaitu nama organisasi, email
  pemilik, dan telepon, ditambah nama dan kode cabang serta nama akun deposit.
- `billing_note` dan `review_note` tidak ditampilkan; tempatnya di halaman
  Organisasi.
- Setiap kueri pada tabel berkolom `organization_id` memakai `skip_org_id: true`.
  LiveView superadmin tidak punya organisasi, jadi kueri yang lupa akan gagal,
  bukan bocor ke organisasi yang salah.
- Tabel tanpa `organization_id` (penjualan, layanan, shift) selalu disaring
  dengan id cabang milik organisasi yang didaftar, tidak pernah tanpa saringan.
- Halaman ini tidak menulis ke database dan tidak memanggil provider.

Catatan untuk pemilik platform: operator kini melihat omzet tiap toko, sedangkan
halaman publik belum punya ketentuan atau kebijakan privasi yang menyebutkannya.
Sebaiknya pemilik toko diberi tahu sebelum fitur ini dipakai di produksi. Spec
ini tidak mengubah halaman publik.

## Pengujian

Tes tidak menebak total seluruh database karena dev dan tes bisa berbagi satu
database. Baris dicari lewat organisasi buatan tes sendiri, dan semua nilainya
rekaan. Ringkasan diuji sebagai selisih sebelum dan sesudah data tes dibuat.

`test/zahlungs/monitoring_test.exs`:

- **Keaktifan:** tepat 7 × 24 jam → aktif; satu detik lebih → sepi; tepat
  30 × 24 jam → sepi; satu detik lebih → tidur; tanpa transaksi → belum pernah.
  Penjualan yang dibatalkan tetap dihitung sebagai transaksi terakhir.
- **Tagihan:** kosong, kemarin, hari ini, 7 hari lagi, 8 hari lagi, dan
  organisasi yang tidak aktif.
- **Omzet:** penjualan `returned` dan `void` tidak masuk; penjualan tepat di
  awal jendela masuk; layanan selain `success` tidak masuk; hasilnya sama dengan
  `Sales.sales_report/3` pada data yang sama.
- **Masalah:** tiap jenis dihitung sekali; layanan api 9 menit belum tertahan
  dan 10 menit tertahan; layanan manual tidak tertahan; gagal yang sudah
  dikembalikan tidak dihitung; gagal dalam review masuk "Menunggu keputusan",
  bukan "Perlu dikembalikan".
- **Saldo:** sama dengan `Deposits.estimated_balance/1`; hanya saldo di bawah nol
  dihitung, saldo nol tidak; akun nonaktif tidak dihitung.
- **Dua organisasi:** dibuat dengan `organization_fixture/1` + `in_org/2`; angka,
  cabang, dan akun deposit tidak tercampur.
- **Cabang:** nonaktif tanpa keaktifan dan tidak dihitung sepi, tetapi angkanya
  masuk total; organisasi tanpa cabang muncul dengan nol.
- **Urutan dan saringan:** urutan peringkat; pencarian dengan `%` dan `_` sebagai
  teks.
- **Tanpa organisasi:** `overview/2` berjalan tanpa `Repo.put_org_id/1`, seperti
  saat dipanggil dari LiveView superadmin.

`test/zahlungs_web/live/platform_live/monitoring_test.exs`:

- **Akses** dengan `get/2`: tamu, kasir, dan admin ditolak; superadmin masuk.
- **Perilaku** dengan `LiveDriver`: ganti periode, saringan, pencarian, halaman,
  buka-tutup rincian; id sebagai angka dan teks; periode tidak dikenal.
- **Isi halaman:** nomor pelanggan, jawaban provider, kredensial, nama kasir, dan
  IP login buatan tes tidak muncul di HTML, juga setelah rincian dibuka.

## Dokumen

`CLAUDE.md`, `docs/IA.md`, dan `docs/SAAS-multi-pemilik.md` diperbarui dengan
halaman dan aturan baru ini.
