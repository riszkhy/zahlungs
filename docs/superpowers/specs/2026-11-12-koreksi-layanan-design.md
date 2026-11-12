# Desain — Koreksi Status Layanan oleh Admin

Tanggal: 2026-11-12 · Status: menunggu tinjauan
Branch: `feat/koreksi-layanan` (dari `feat/rekonsiliasi-layanan`, yang belum
di-merge ke `master`)
Dibangun di atas: `docs/superpowers/specs/2026-11-12-rekonsiliasi-layanan-design.md`
dan Peninjauan di `docs/superpowers/specs/2026-10-21-layanan-ppob-sbi-design.md`.

## Tujuan

Admin organisasi bisa membetulkan status akhir sebuah transaksi layanan, baik api
maupun manual, tanpa menunggu SBI menjawab bertentangan. Kasus yang ditangani:

- Tercatat berhasil, padahal pelanggan tidak menerima pulsa atau token.
- Tercatat gagal, padahal sebenarnya terlayani.

Hari ini status final hanya berubah lewat Peninjauan (`resolve_review/3`), dan
Peninjauan hanya muncul bila jawaban penyedia bertentangan dengan status di Zahlungs.

Berhasil bila:

1. Koreksi memakai perpindahan yang sama dengan Peninjauan. Kas laci, refund,
   komisi, laporan, dan perkiraan saldo deposit mengikuti aturan yang sudah ada,
   tanpa aturan uang baru selain yang disebut di bagian "Uang yang menunggu
   dikembalikan".
2. Uang yang sudah dikembalikan ke pelanggan tidak pernah "ditagih ulang" lewat
   koreksi.
3. Hanya admin organisasi itu yang bisa mengoreksi. Alasan wajib diisi, dan siapa
   yang mengoreksi serta kapan selalu tercatat.
4. Klik ganda atau tab lain yang datanya usang tidak membuat koreksi dua kali.

Di luar cakupan:

- Log koreksi lengkap (satu baris per koreksi). Yang disimpan hanya koreksi terakhir.
- Koreksi modal atau SN tanpa mengubah status.
- Koreksi transaksi barang (`sales`).
- Memberi tahu atau menanyai SBI.
- Transaksi yang masih diproses. Untuk itu tetap dipakai tombol Tandai berhasil/gagal
  yang sudah ada.

## Keputusan yang sudah diambil

| Topik | Keputusan |
|---|---|
| Yang dikoreksi | Status final saja |
| Arah | Berhasil ↔ gagal, kecuali gagal yang uangnya sudah dikembalikan |
| Cakupan | Layanan api dan manual |
| Letak tombol | Riwayat layanan (`/services/history`) dan Rekonsiliasi |
| Pendekatan | Fungsi koreksi baru yang memakai perpindahan Peninjauan, ditambah tiga kolom jejak (A) |

## Uang yang menunggu dikembalikan

Ini temuan saat menulis spec, dan menajamkan "kecuali yang sudah refund" untuk
layanan manual.

- **Api.** Transaksi gagal menunggu di "Perlu dikembalikan" sampai kasir menekan
  konfirmasi (`confirm_refund/2`). Selama `refunded_at` kosong, uangnya masih di
  laci.
- **Manual.** Transaksi yang ditandai gagal (`mark_failed/3`) dianggap uangnya
  **langsung** dikembalikan saat itu juga. Tidak ada langkah konfirmasi,
  `refunded_at` tetap kosong, dan `shift_totals/1` sudah tidak menghitungnya.

Satu aturan untuk keduanya: transaksi **menunggu dikembalikan** bila
`status = "failed"`, `refunded_at` kosong, dan transaksinya api **atau** digagalkan
lewat koreksi (`corrected_at` terisi).

Akibatnya:

- **Layanan manual yang dikoreksi dari berhasil menjadi gagal** ikut menunggu di
  "Perlu dikembalikan", sama seperti api. Kasir menyerahkan uangnya lalu
  mengonfirmasi; sebelum itu uangnya tetap dihitung di laci.
- **Gagal menjadi berhasil** hanya boleh untuk transaksi yang menunggu
  dikembalikan. Layanan manual yang gagal lewat `mark_failed/3` sudah dikembalikan
  uangnya, jadi koreksi ini ditolak dengan `:refunded`.

Aturan ini ditulis sekali sebagai satu fungsi query (`awaiting_refund/1`) dan
dipakai di empat tempat yang sekarang menulis `channel == "api" and is_nil(refunded_at)`
sendiri-sendiri:

- `Services.shift_totals/1` (kas laci);
- daftar "Perlu dikembalikan" di layar Layanan;
- `confirm_refund/2`, yang tidak lagi menolak layanan manual yang menunggu;
- `Monitoring` (refund yang belum dikonfirmasi).

## Fungsi

`Services.correct_status(admin, transaction, to, reason, opts \\ [])`, dengan `to`
berupa `"failed"` atau `"success"` dan `opts[:token_sn]` opsional (hanya untuk
`"success"`).

Urutan kerjanya:

1. Peran admin dibaca dari database (`Accounts.get_user!/1`), bukan dari socket.
2. Transaksi diambil dengan `t.store_id in ^Stores.store_ids()`. Transaksi organisasi
   lain menjadi `Ecto.NoResultsError` (404).
3. Di dalam satu transaksi database, baris dikunci (`FOR UPDATE`) dan diperiksa
   ulang dari database, bukan dari struct yang dibawa layar.
4. Perpindahannya:
   - **Berhasil menjadi gagal:**
     - `status: "failed"`, `failure_reason: reason`, `resolved_at: now`;
     - `failed_after_shift_close` mengikuti `shift_closed?/1`, sama seperti
       `review(:refund)`;
     - `token_sn` dibiarkan.
   - **Gagal (menunggu dikembalikan) menjadi berhasil:**
     - `status: "success"`, `failure_reason: nil`, `provider_message: nil`,
       `failed_after_shift_close: false`, `resolved_at: now`;
     - `token_sn` diisi bila `opts[:token_sn]` tidak kosong.
   - Keduanya mengisi `corrected_at: now`, `corrected_by_id: admin.id`, dan
     `correction_reason: reason`.
5. Setelah commit, perubahan disiarkan seperti `resolve_review/3` (`broadcast/1`).

Hasilnya `{:ok, transaction}` atau `{:error, reason}`:

| Kondisi | Galat |
|---|---|
| Bukan admin | `:not_admin` |
| `processing` | `:not_final` |
| Status sudah sama dengan `to` | `:same_status` |
| Gagal yang tidak menunggu dikembalikan (sudah refund, atau manual yang gagal lewat `mark_failed`) | `:refunded` |
| `review_reason` terisi | `:in_review` |
| Alasan kosong setelah di-trim, atau lebih dari 200 karakter | `:reason_required` |
| SN lebih dari 64 karakter | `:invalid_token_sn` |

Penolakan tidak mengubah baris apa pun.

### Dampak yang mengikuti dengan sendirinya

- **Kas laci shift.** Berhasil menjadi gagal tetap dihitung di laci sampai refund
  dikonfirmasi. Bila shift asalnya sudah tutup, refund-nya menjadi pengeluaran kas
  `refund` di shift kasir yang menyerahkan uang (`failed_after_shift_close`).
  Gagal menjadi berhasil: uangnya sudah dihitung di laci, jadi tidak ada perubahan.
- **Komisi kasir.** Komisi hanya dihitung untuk transaksi berhasil, jadi ikut
  berubah, termasuk "Komisi shift ini" untuk shift yang sudah tutup.
- **Perkiraan saldo deposit.** Menghitung modal transaksi `processing` dan
  `success`, jadi ikut berubah. SBI tidak ditanya dan tidak diberi tahu. Kalau admin
  menggagalkan transaksi yang di SBI berhasil, perkiraan saldo akan selisih dengan
  saldo SBI, dan selisih itu terlihat saat pencocokan saldo.
- **Jawaban penyedia belakangan.** Jawaban yang bertentangan dengan status hasil
  koreksi (`apply_result/2`, `hold_contradiction`) membuat transaksi masuk Peninjauan
  seperti biasa. Statusnya tidak berubah sendiri.

## Data

Satu migrasi `add_correction_to_service_transactions`:

- `corrected_at` (`naive_datetime`, null);
- `corrected_by_id` (referensi `users`, `on_delete: :nilify_all`, null);
- `correction_reason` (`string`, 200, null).

Di schema `Transaction`: field dan `belongs_to :corrected_by`. Kolom-kolom ini
tidak pernah diisi dari params selain lewat `correct_status/5`.

## Tampilan

### Tombol

- **Koreksi status** muncul untuk admin di dua tempat:
  - kartu transaksi di Riwayat layanan (`ServiceLive.History`);
  - kartu baris Rekonsiliasi (`DepositLive.Reconcile`) yang punya transaksi Zahlungs.
- Tombol hanya muncul bila koreksi mungkin. `Services.correctable?/1` (murni)
  benar bila:
  - status berhasil, atau gagal dan menunggu dikembalikan; dan
  - `review_reason` kosong.
- Kasir tidak pernah melihat tombolnya, dan event-nya juga menolak kasir (lewat
  `:not_admin` di konteks).

### Popup

Polanya sama dengan popup bayar: tombol (`review_correction`) hanya membuka popup,
dan `confirm_correction` bekerja hanya selama popup terbuka. Fokus awal ada di
**Batal**.

- **Isi:** kode transaksi, produk, nomor pelanggan, harga, status sekarang, dan
  status tujuan. Tujuannya tidak dipilih, melainkan mengikuti status sekarang:
  - Berhasil: **Jadikan gagal**, dengan catatan "Uang {harga} menunggu dikembalikan
    ke pelanggan oleh kasir."
  - Gagal: **Jadikan berhasil**, dengan kolom **SN / token (opsional)**.
- **Kolom wajib:** **Alasan**, `maxlength` 200.
- **Tombol:** **Batal** dan **Simpan koreksi** (`phx-disable-with`).

### Pesan

| Hasil | Pesan |
|---|---|
| ok, gagal | Status dikoreksi menjadi Gagal. Uang menunggu dikembalikan kasir. |
| ok, berhasil | Status dikoreksi menjadi Berhasil. |
| `:in_review` | Transaksi ini sedang ditinjau. Putuskan di halaman akun deposit. |
| `:refunded` | Uangnya sudah dikembalikan, tidak bisa dijadikan berhasil. |
| `:same_status`, `:not_final` | Status transaksi sudah berubah. Muat ulang. |
| `:reason_required` | Alasan wajib diisi (maks. 200 karakter). |
| `:invalid_token_sn` | SN terlalu panjang (maks. 64 karakter). |

Pada galat alasan atau SN, popup tetap terbuka dan isiannya tidak hilang. Pada galat
lainnya, popup ditutup.

### Sesudah disimpan

- **Riwayat layanan:** kartu diperbarui dan menampilkan "Dikoreksi {nama admin},
  {waktu lokal toko}: {alasan}" bila `corrected_at` terisi. Layar lain ikut
  diperbarui lewat siaran yang sudah ada.
- **Rekonsiliasi:** baris digolongkan ulang dengan `Reconciliation.classify/2` dari
  transaksi yang baru dan baris SBI yang sudah ada. SBI tidak ditanya.
- Popup dan kartu memakai lebar penuh dan tidak melebar di 375 px. Handler menerima
  id dan indeks sebagai angka maupun teks.

## Keamanan

- Pemeriksaan admin ada di konteks (peran dari database), bukan hanya di tampilan.
  Kedua halaman tetap di `live_session` masing-masing; Riwayat layanan terbuka untuk
  semua pengguna yang login, jadi event koreksi juga bergantung pada pemeriksaan
  konteks.
- Transaksi disaring dengan cabang organisasi admin. Id dari params hanya dipakai
  untuk mencari di dalam saringan itu.
- Alasan dan SN ditampilkan sebagai teks (HEEx meng-escape-nya).

## Pengujian

`test/zahlungs/services/correction_test.exs`:

- **Api, berhasil menjadi gagal:**
  - Transaksi menunggu dikembalikan, dan `failure_reason`, `correction_reason`,
    `corrected_by_id`, `corrected_at` terisi.
  - Kas laci (`Shifts.expected_cash/1`) sama sebelum dan sesudah koreksi, lalu
    berkurang sebesar harga setelah `confirm_refund/2`.
- **Shift sudah tutup:** transaksi ditandai `failed_after_shift_close`; refund dari
  shift kasir lain menjadi pengeluaran `refund` di shift itu.
- **Manual, berhasil menjadi gagal:** muncul di daftar menunggu dikembalikan, dan
  `confirm_refund/2` menerimanya.
- **Manual yang gagal lewat `mark_failed`:** dijadikan berhasil menghasilkan
  `:refunded`.
- **Gagal menjadi berhasil:**
  - SN tersimpan, dan `failure_reason` serta `failed_after_shift_close` dihapus.
  - Komisi (`Services.commission/1`) dan `deposit_used/1` ikut berubah.
- **Penolakan:** semua galat di tabel. Baris tidak berubah, dan transaksi organisasi
  lain menjadi 404.
- **Data usang:** koreksi kedua dengan struct lama menghasilkan `:same_status`.
- **Jawaban penyedia belakangan:** `apply_result/2` yang bertentangan dengan hasil
  koreksi mengisi `review_reason` tanpa mengubah status.
- **`awaiting_refund/1`:** `shift_totals/1`, daftar menunggu dikembalikan, dan
  `Monitoring` memakai aturan yang sama. Tes yang sudah ada tetap hijau.

`LiveDriver`:

- **Riwayat layanan:**
  - Admin melihat **Koreksi status**; kasir tidak, dan event dari kasir ditolak.
  - `confirm_correction` tanpa popup terbuka tidak berbuat apa-apa.
  - Alasan kosong membiarkan popup terbuka dengan pesan galatnya.
  - Setelah disimpan, muncul pesan berhasil dan teks "Dikoreksi".
  - Id diterima sebagai angka maupun teks.
- **Rekonsiliasi:**
  - Baris "Bertentangan" yang dikoreksi pindah ke "Cocok" tanpa permintaan baru ke
    SBI.
  - Baris yang sedang ditinjau tidak punya tombol koreksi.

Tes tidak memanggil SBI (`Sbi.StubClient`), dan semua nilai rekaan.

## Dokumen

- `CLAUDE.md`:
  - bagian PPOB (koreksi admin, aturan menunggu dikembalikan);
  - bagian Invariants: status final berubah hanya lewat Peninjauan atau koreksi
    admin.
- `docs/IA.md`: tombol di Riwayat layanan dan Rekonsiliasi.
