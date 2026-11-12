# Rapikan tampilan Rekonsiliasi dan popup Koreksi status

Tanggal: 2026-11-12 · Branch: `feat/rapikan-rekonsiliasi` (dari `master`)

Melanjutkan `2026-11-12-rekonsiliasi-layanan-design.md` dan
`2026-11-12-koreksi-layanan-design.md`. Hanya tampilan: tidak ada perubahan pada
context, data, migrasi, aturan uang, atau pertanyaan ke SBI.

## Tujuan

Admin langsung tahu baris mana yang berbahaya, apa yang berbeda, dan satu langkah
yang benar, tanpa membandingkan dua kolom sendiri. Di popup koreksi, admin tahu
persis akibat tombol yang ditekannya.

Ukuran berhasil:

- Golongan berbahaya tampil merah dan di atas; yang cocok tidak mengganggu.
- Sel yang berbeda tersorot; selisih modal tertulis angkanya.
- Setiap baris punya paling banyak satu tombol utama dan satu kalimat petunjuk.
- Tombol utama popup menyebut tindakannya; kedua arah punya peringatan uang.

## 1. Halaman Rekonsiliasi (`DepositLive.Reconcile`)

### Golongan: label, warna, petunjuk, tombol

Satu peta di `reconcile.ex` menggantikan `@kind_labels` dan `@buttons`. Urutan
tampil (chip dan baris) mengikuti tabel ini, bukan `Reconciliation.kinds/0`;
urutan di context tidak diubah.

| Golongan | Label | Warna | Petunjuk | Tombol utama |
|---|---|---|---|---|
| `:conflict` | Bertentangan | merah | Zahlungs dan SBI sama-sama final tapi berbeda. Samakan dengan SBI; cek status dulu bila ragu. | Koreksi status (tombol kedua: Cek status SBI) |
| `:theirs_only` | Hanya di SBI | merah | SBI memotong saldo, tapi transaksinya tidak ada di akun ini. Tanyakan ke SBI. | — |
| `:follow` | Belum final di Zahlungs | kuning | SBI sudah final, Zahlungs masih Diproses. | Ikuti SBI |
| `:ours_only` | Hanya di Zahlungs | kuning | Terkirim, tapi tidak ada di riwayat SBI. | Cek status |
| `:pending_there` | Belum final di SBI | kuning | SBI belum memberi status akhir. | Cek status |
| `:cost_diff` | Selisih modal | kuning | Status sama, modal Zahlungs beda dengan potongan SBI. | — |
| `:matched` | Cocok | hijau | — | — |

- Label `:follow` berganti dari "Ikuti SBI" menjadi "Belum final di Zahlungs",
  agar label (apa masalahnya) tidak sama dengan tombol (apa langkahnya).
- Tombol "Tinjau" pada `:conflict` berganti nama menjadi **Cek status SBI** dan
  menjadi tombol kedua. Perilakunya tetap (`recheck`).
- Warna (kelas Tailwind): merah `border-red-300 bg-red-50 text-red-800`, kuning
  `border-amber-300 bg-amber-50 text-amber-800`, hijau
  `border-green-300 bg-green-50 text-green-800`.

### Chip ringkasan menjadi filter

- Setiap chip memakai warna golongannya dan menampilkan jumlahnya.
- Chip berjumlah 0: diredupkan (`opacity-50`), `disabled`, tidak bisa diklik.
- Assign baru `kind_filter` (`nil` = semua yang perlu tindakan). Event
  `filter_kind` dengan `%{"kind" => teks}`:
  - teks nama golongan yang dikenal dan jumlahnya > 0: filter ke golongan itu;
    bila golongan itu sudah aktif, kembali ke `nil`;
  - selain itu (tak dikenal, jumlah 0, bukan teks): tidak berubah. Teks
    dicocokkan dengan peta golongan, tidak pernah `String.to_atom`.
- Chip aktif diberi `ring-2` dan `aria-pressed="true"`.
- `nil`: semua baris kecuali `:matched`. Golongan terpilih: hanya baris itu,
  termasuk `:matched` (chip **Cocok** menggantikan tombol "Lihat yang cocok";
  `show_matched` dan event `toggle_matched` dihapus).
- Bila `nil` dan tidak ada baris yang perlu tindakan tapi ada yang cocok:
  "Semua transaksi cocok dengan SBI." Hari kosong tetap "Tidak ada transaksi pada
  tanggal ini."
- `kind_filter` kembali `nil` setiap kali Cocokkan ditekan. Sesudah Cek status,
  Ikuti SBI, atau koreksi, filter tetap; baris yang pindah golongan keluar dari
  tampilan bila tidak cocok dengan filter.

### Kartu baris

- Garis kiri berwarna golongan (`border-l-4` + warna garis merah/kuning/hijau).
- Lencana golongan memakai warna yang sama; lencana "Sedang ditinjau" tetap.
- Kalimat petunjuk (tabel di atas) di bawah produk · nomor, `text-sm`. Tidak ada
  petunjuk untuk `:matched`.
- **Status berbeda:** bila status Zahlungs dan SBI tidak sama, kedua nilai status
  tampil `font-semibold text-red-700`. Sama berarti: success = success,
  failed = failed **atau refunded**, processing = pending. Salah satu sisi tidak
  ada ("Tidak ada") selalu berbeda.
- **Modal berbeda:** bila kedua sisi punya modal dan nilainya tidak sama, di bawah
  Potongan SBI tampil "selisih +Rp 150" / "selisih −Rp 150" (potongan SBI −
  modal Zahlungs), `text-red-700`. Sama atau salah satu kosong: tidak tampil.
- **Tombol:** satu tombol utama (gaya `.button`) menurut tabel, hanya bila baris
  punya transaksi Zahlungs dan tidak sedang ditinjau (aturan lama).
  - `:conflict`: tombol utama **Koreksi status** (bila `ServiceCorrection.button?`),
    tombol kedua **Cek status SBI** (gaya `chip`). Bila koreksi tidak mungkin
    (mis. uangnya sudah dikembalikan), hanya Cek status SBI yang tampil, tetap
    sebagai `chip`.
  - Golongan lain: "Koreksi status" tetap ada sebagai tombol kedua (gaya `chip`)
    bila `ServiceCorrection.button?`.
  - Urutan dalam satu baris: tombol utama dulu, lalu tombol kedua.

## 2. Popup Koreksi status (`ZahlungsWeb.ServiceCorrection.popup/1`)

Dipakai Riwayat layanan dan Rekonsiliasi; perubahan berlaku di keduanya.

- **Kepala:** hanya judul ("Jadikan gagal" / "Jadikan berhasil"). Tombol Batal
  pindah dari kepala ke bawah; `pr-10` pada kepala tetap untuk ✕ bawaan modal.
- **Baris Status:** lencana berwarna, sama dengan Riwayat layanan: Berhasil
  `bg-green-100 text-green-700`, Gagal `bg-red-100 text-red-700`, Diproses
  `bg-amber-100 text-amber-800`. "lencana sekarang → lencana tujuan".
- **Peringatan (kuning, kedua arah):**
  - ke gagal (tetap): "Uang {harga} menunggu dikembalikan ke pelanggan oleh
    kasir."
  - ke berhasil (baru): "Uang {harga} tidak jadi dikembalikan ke pelanggan;
    transaksi dihitung berhasil."
- **Kolom isian:** tetap (SN / token opsional hanya ke berhasil; Alasan wajib,
  `maxlength` 200).
- **Fokus awal:** kolom isian pertama (SN untuk ke berhasil, Alasan untuk ke
  gagal), lewat `JS.focus_first` modal yang sudah ada. Ini menggantikan "fokus
  awal di Batal" dari spec koreksi. Aman: Enter di Alasan menambah baris; Enter
  di SN ditahan browser selama Alasan kosong (`required`).
- **Tombol bawah** (`flex justify-end gap-2`): **Batal** (`chip`,
  `phx-click="cancel_correction"`), lalu tombol utama:
  - ke gagal: **Jadikan gagal**, `!bg-red-600` (pola yang sudah dipakai Close
    shift);
  - ke berhasil: **Jadikan berhasil**, gaya `.button` biasa;
  - keduanya `phx-disable-with="Menyimpan..."`.
- Teks "Simpan koreksi" hilang.

## 3. Riwayat layanan

- Lencana Gagal berubah dari `bg-gray-200 text-gray-700` ke
  `bg-red-100 text-red-700`, sama dengan popup.

## Dokumen

- CLAUDE.md, bagian Admin correction: popup memfokuskan kolom isian pertama;
  tombol utama "Jadikan gagal"/"Jadikan berhasil". Bagian Reconciliation:
  chip golongan menyaring, satu tombol utama per baris.
- `2026-11-12-koreksi-layanan-design.md`: catatan di bagian Popup bahwa fokus dan
  tombol diganti oleh spec ini.
- `docs/IA.md` (bagian Rekonsiliasi): nama golongan "Ikuti SBI" menjadi "Belum
  final di Zahlungs", tombol "Tinjau" menjadi "Cek status SBI", chip menyaring.

## Tes

Lewat `ZahlungsWeb.LiveDriver` (`reconcile_test.exs`,
`service_history_live_test.exs`), nilai karangan, SBI = `Sbi.StubClient`.

- Chip: warna golongan; chip 0 `disabled`; `filter_kind` menyaring, klik kedua
  kembali ke semua; teks tak dikenal / golongan berjumlah 0 tidak mengubah apa
  pun; chip Cocok menampilkan baris cocok; Cocokkan lagi mengembalikan filter ke
  semua; "Semua transaksi cocok dengan SBI." bila semua cocok.
- Urutan: baris Bertentangan tampil sebelum baris Belum final di Zahlungs.
- Kartu: petunjuk per golongan; label `:follow` "Belum final di Zahlungs";
  status berbeda tersorot (dan Gagal vs Refund tidak); "selisih +Rp …" pada
  `:cost_diff`.
- Tombol: `:conflict` punya Koreksi status sebagai tombol utama dan Cek status SBI
  sebagai tombol kedua; `:follow` punya Ikuti SBI; `:theirs_only` tanpa tombol.
- Popup: "Jadikan gagal" / "Jadikan berhasil" sesuai arah; peringatan arah
  berhasil; Batal tampil sebelum tombol utama di bagian bawah, tidak di kepala;
  tidak ada "Simpan koreksi".
- Tes lama yang memakai `toggle_matched`, "Lihat yang cocok (1)", atau
  "Ikuti SBI" sebagai label disesuaikan.

## Di luar cakupan

Kotak angka besar untuk ringkasan uang, tombol cepat "Kemarin", tautan ke halaman
Rekonsiliasi dari tempat lain, kolom Keterangan/Aksi di tabel Riwayat, lencana
"Menunggu dikembalikan", dan temuan kecil 3–5 dari tinjauan koreksi.
