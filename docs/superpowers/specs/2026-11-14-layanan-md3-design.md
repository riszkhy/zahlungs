# Layar Layanan dan Riwayat layanan dengan Material Design 3

Tanggal: 2026-11-14 · Branch: `feat/layanan-md3` (dari `feat/kasir-md3`, yang
belum di-merge; kalau kasir di-merge lebih dulu, branch ini menyusul di atas
`master`)

Hanya tampilan: tidak ada perubahan pada context, data, migrasi, aturan uang,
event, nama field, atau alur kerja (pilih produk → isi nomor → Bayar → popup
konfirmasi; cek tagihan dulu untuk tagihan api).

## Tujuan

`/services` dan `/services/history` memakai token dan komponen MD3 yang dibuat
untuk kasir (`docs/superpowers/specs/2026-11-13-kasir-md3-design.md`), sehingga
kasir yang berpindah antara Kasir, Layanan dan Riwayat layanan melihat satu
bahasa visual. Popup Koreksi status (admin) ikut pindah ke `md_dialog` karena
dibuka di atas Riwayat layanan.

Ukuran berhasil:

- Kedua halaman memakai warna peran, sudut, huruf dan komponen MD3; tidak ada
  lagi kelas `.chip`, `.chip-sm`, `.product-tile`, `.btn-primary`,
  `.form-control`, `.list-card` atau warna Tailwind bawaan (`gray-*`, `green-*`,
  `red-*`, `amber-*`) di template keduanya.
- Semua event `phx-*`, id elemen dan nama field tetap sama; tes yang ada tetap
  lulus, kecuali yang memeriksa kelas lama (disesuaikan, alasannya di commit).
- Halaman lain tidak berubah, kecuali popup Koreksi status di Rekonsiliasi
  (isinya sama, wadahnya MD3).
- Tidak ada dependensi baru, tidak ada font yang diunduh.

Di luar cakupan: halaman Rekonsiliasi sendiri, halaman admin, `.header`,
`.table`, `.pagination` dan `<.modal>` di `core_components.ex`, struk, mode
gelap, bahasa teks, format uang.

## Pendekatan

Dipilih: **kedua halaman ditulis ulang dengan komponen MD3; tabel Riwayat ditulis
langsung di halamannya; popup Koreksi pindah ke `md_dialog`.**

Dipertimbangkan dan tidak dipilih:

- Sekaligus mengubah `.header`, `.table`, `.pagination` di `core_components` —
  belasan halaman admin ikut berubah tanpa diperiksa; layak jadi pekerjaan
  sendiri.
- Hanya mengganti kelas warna — chip, tombol dan popup tetap terasa gaya lama,
  tidak seragam dengan kasir.

## 1. Tambahan pada `MdComponents`

Kecil, dipakai kedua halaman; komponen lain tidak berubah.

| Perubahan | Isi |
|---|---|
| `md_button/1`: attr `navigate` dan `href` | Kalau salah satunya diisi, dirender sebagai `<.link>` dengan kelas yang sama (untuk "Lihat semua riwayat", "Buka shift di Cashier", "Layanan", "Komisi saya"). `type`/`disabled` diabaikan pada link. |
| `md_text_field/1`: `type="textarea"` | `<textarea>` dengan gaya outlined yang sama, attr `rows` lewat global. |
| `md_text_field/1`: slot `trailing` | Diletakkan di dalam kolom, rata kanan, untuk tombol ikon (✕ hapus nomor). Input mendapat padding kanan bila slot diisi. |
| `md_badge/1` baru | Attr `tone` `"success"` / `"error"` / `"warning"` / `"neutral"`, slot `inner_block`. Pil kecil `label-md`: success = `bg-primary-container text-on-primary-container`, error = `bg-error-container text-on-error-container`, warning = `bg-warning-container text-on-warning-container`, neutral = `bg-surface-container-highest text-on-surface-variant`. |

Status layanan → tone: `success` → success, `failed` → error, `processing` →
warning. Satu fungsi `ZahlungsWeb.ServiceCorrection.status_badge/1` (sudah ada,
privat) dijadikan publik dan dipakai ketiga tempat (Layanan, Riwayat, popup).
Ini mengubah satu hal yang terlihat: di riwayat shift `/services`, Gagal sekarang
abu-abu, nanti merah seperti di Riwayat layanan.

## 2. `/services` — `ServiceLive.Index`

Akar halaman seperti kasir: `<div class="md3 -m-6 rounded-xl bg-surface p-4 …">`.
Breakpoint dua kolom tetap (`lg` dan `md:landscape`).

### Atas

- Judul pengganti `.header`: "Layanan" `headline-sm`, anak judul yang sama
  `body-md text-on-surface-variant`; di kanan `md_button variant="outlined"`
  ikon `history` "Lihat semua riwayat" (`navigate` ke `/services/history`).
- Belum ada shift: `md_card variant="outlined"` — "Belum ada shift" `title-md`,
  kalimat yang sama `body-md`, `md_button` filled "Buka shift di Cashier"
  (`navigate`).
- Toko tanpa akun deposit: `md_card` `bg-warning-container
  text-on-warning-container`, teks sama.
- **Perlu dikembalikan** (`#refunds-due`): `md_card` `bg-error-container
  text-on-error-container`; judul `title-sm`; tiap baris (`#refund-<id>`) isi sama,
  catatan `body-sm`; tombol `md_button variant="outlined"` "Uang sudah
  dikembalikan" (event, `phx-disable-with` sama).

### Kolom produk

- Kategori: `md_chip kind="filter"` per kategori, baris yang bisa digeser seperti
  kasir, `selected` = kategori aktif. Event `set_category` sama.
- Nomor tujuan (`#brand-number`, kategori pulsa/paket data): `md_text_field`
  label "Nomor tujuan", `id="brand-number-input"`, nama, `inputmode`,
  `placeholder` dan `autocomplete` sama; slot `trailing` = tombol ikon `close`
  `aria-label="Hapus nomor"` (`phx-click="clear_number"`, hanya bila nomor
  terisi). Petunjuk `#brand-number-hint` `body-md text-on-surface-variant`.
- Brand: `md_chip kind="filter"` "Semua" lalu per brand dalam `role="group"
  aria-label="Brand"`; lebih kecil dari chip kategori (`min-h-[36px]`,
  `label-md`) agar dua baris tidak terbaca satu. Event `set_brand` sama.
- Catatan "Belum ada produk …, yang tampil produk tanpa brand": `md_card`
  `bg-warning-container`, "Tampilkan semua" `md_button variant="text"`.
- Tile produk: seperti kasir (`md-state rounded-md3-md bg-surface-container-low`,
  min 88px, nama `title-sm`, harga `label-lg text-primary`); tile terpilih
  `bg-secondary-container text-on-secondary-container` dengan
  `aria-pressed="true"`. Event `select` sama.
- Pesan kosong: `body-md text-on-surface-variant`, "Tampilkan semua"
  `md_button variant="text"`.

### Panel bayar (kanan di layar lebar, bottom sheet di ponsel)

- `md_sheet id="service-sheet" open={@panel_open} on_close="toggle_panel"`; di
  dalamnya panel `id="service-panel"` `bg-surface-container-lowest
  rounded-md3-lg p-4`, menempel saat digulir di layar lebar (seperti kasir).
  Assign dan event (`panel_open`, `toggle_panel`) tidak berubah; kelas
  `cart-panel` / `cart-panel-open` hilang dari halaman ini.
- Tombol "Tutup" di atas panel (hanya ponsel, saat produk terpilih) menjadi
  `md_button variant="text"` ikon `close`.
- Cek tagihan / pelanggan (api): `md_text_field` ID pelanggan, `md_text_field
  type="select"` Jumlah bulan 1–12, `md_button` filled penuh dengan teks sama.
- Hasil cek (`#inquiry`): `md_card variant="filled"`; nama `title-sm`, baris
  rincian `body-md`, total `title-md`.
- Peringatan brand (`#brand-mismatch`, `role="alert"`): `rounded-md3-sm
  bg-error-container text-on-error-container`.
- Nominal tagihan, Nomor tujuan (kategori lain), Uang diterima: `md_text_field`
  dengan nama dan `inputmode` sama. Nomor besar: `headline-sm` di
  `bg-surface-container-high rounded-md3-md`.
- **Cara bayar**: `md_segmented name="service[payment_method]"` dengan keempat
  opsi dan urutan yang sama (Tunai, QRIS, Kartu, Transfer), tanpa `event`:
  radio di dalam form, jadi `phx-change="change"` yang ada menerimanya seperti
  dari `<select>`.
- Kembalian `title-sm`. Tombol kirim: `md_button` filled penuh tinggi 56px, teks
  dan `phx-disable-with` sama.

### Ponsel

`#service-bar` seperti bilah kasir: `.cart-bar` dengan `!min-h-[80px]
!border-t-0 !bg-surface-container shadow-elev-2`; kiri nama produk `body-sm` dan
harga `title-lg`; kanan `md_button` filled `id="service-bar-open"`, teks
`bar_action/1` sama, `disabled` sama.

### Bawah

- **Sedang diproses**: judul `title-md`; tiap transaksi (`#processing-<id>`)
  `md_card variant="outlined"`; "Menunggu penyedia" `text-warning`; "Cek status"
  `md_button variant="tonal"`; peringatan 10 menit `body-sm text-warning`; form
  Berhasil: `md_text_field` Token/SN + `md_button variant="tonal"` "Berhasil";
  form Gagal: `md_text_field` alasan + `md_button variant="outlined"` berteks
  `error` "Gagal". Nama field, `maxlength`, `required` sama.
- Komisi (`#shift-commission`): `body-md`, angka `text-primary`, "Komisi saya"
  `md_button variant="text"` (`navigate`).
- **Riwayat shift ini**: baris `#history-<id>` `rounded-md3-md
  bg-surface-container-low` (isi sama), status lewat `status_badge`, "Cetak
  struk" link `text-primary`.

### Popup konfirmasi

`<.modal id="confirm-service">` menjadi `md_dialog` dengan id sama: judul
"Konfirmasi pembayaran", kalimat penjelas `body-md`, peringatan brand
`bg-error-container`, nomor `headline-sm` di `bg-surface-container-highest`,
rincian `dl` `body-md`; `actions` = Batal (`md_button variant="text"`, tetap yang
difokus lebih dulu) lalu "Ya, bayar" / "Ya, catat" (filled, `phx-disable-with`
sama).

## 3. `/services/history` — `ServiceLive.History`

- Akar `md3 -m-6 rounded-xl bg-surface p-4`. Judul "Riwayat layanan"
  `headline-sm` + anak judul; kanan `md_button variant="outlined"` "Layanan"
  (`navigate` ke `/services`).
- Filter (`#history-filter`, `phx-change`/`phx-submit="filter"` sama): Dari dan
  Sampai `md_text_field type="date"`; Status dan Kategori `md_text_field
  type="select"` (opsi sama); Cari `md_search` (`name="q"`, `phx-debounce="300"`,
  placeholder sama). Grid sama (2 kolom, 6 di `lg`).
- Pesan kosong / tanggal tidak valid: `body-md text-on-surface-variant`.
- Kartu (< `lg`, `#service-card-<id>`): `rounded-md3-md bg-surface-container-low
  p-3`, isi sama; status `status_badge`; "Koreksi status" `md_button
  variant="text"` kecil (event `review_correction`, `phx-value-id` sama); "Cetak
  struk" link `text-primary`; catatan koreksi/ulasan/gagal `body-sm` (ulasan
  `text-warning`).
- Tabel (`lg`): `<table>` ditulis di halaman ini di dalam
  `<div id="service-history">` `rounded-md3-lg bg-surface-container-lowest
  overflow-x-auto`; kepala `label-md text-on-surface-variant`, baris dipisah
  `outline-variant`, kolom dan syarat kolom Cabang sama dengan sekarang.
- `<.pagination>` tetap.

## 4. Popup Koreksi status — `ZahlungsWeb.ServiceCorrection`

`<.modal id="correct-service">` menjadi `md_dialog` dengan id sama dan
`on_cancel` sama:

- `title` = "Jadikan gagal" / "Jadikan berhasil".
- Rincian `dl` `body-md`, label `text-on-surface-variant`, status lama → baru
  dengan `status_badge`.
- Peringatan uang: `rounded-md3-sm bg-warning-container
  text-on-warning-container`, kalimat sama.
- Form `id="correct-service-form"` (`phx-submit="confirm_correction"`): SN/token
  `md_text_field` (hanya arah berhasil, `maxlength` 64), Alasan `md_text_field
  type="textarea"` (`rows` 2, `maxlength` 200, `required`), galat `role="alert"
  text-error`. Kolom pertama tetap yang difokus.
- `actions` = Batal (`md_button variant="text"`, `phx-click="cancel_correction"`)
  lalu `md_button variant="danger"` "Jadikan gagal" atau filled "Jadikan
  berhasil", keduanya `type="submit" form="correct-service-form"` dan
  `phx-disable-with="Menyimpan..."`.

Fungsi `button?/2`, `target/1`, `message/1`, `keep_open?/1` tidak berubah.

## 5. Pengujian

- Seluruh suite tetap lulus. Yang disesuaikan karena memeriksa kelas lama:
  `service_live_test.exs` (chip brand `chip-sm-active`, `cart-panel-open`),
  `service_history_live_test.exs` (`pr-10`, `!bg-red-600`, `bg-red-100`).
- `md_components_test.exs`: `md_button` dengan `navigate` merender `<a>` berkelas
  varian; `md_text_field type="textarea"` merender `<textarea>` dengan nama dan
  nilai; slot `trailing` dirender di dalam kolom; `md_badge` setiap tone memberi
  kelasnya.
- Tes Layanan baru (LiveDriver): cara bayar berupa radio
  `service[payment_method]` dan event `change` dengan `qris` membuat segmen QRIS
  `checked`; `select` membuka `#service-sheet`; tile terpilih `aria-pressed="true"`;
  popup konfirmasi tetap menaruh Batal sebelum "Ya, bayar".
- Tes Riwayat baru: tabel `#service-history` tanpa kelas `.table` lama dan dengan
  kolom yang sama; popup Koreksi memakai tombol `danger` dengan `form=
  "correct-service-form"`, Batal lebih dulu.
- Pemeriksaan visual di panel browser 375×812 dan 1280×800: Layanan tanpa
  produk terpilih, dengan produk terpilih, bottom sheet, popup konfirmasi (dibuka
  lalu Batal; tidak ada transaksi tercatat), Riwayat layanan (kartu dan tabel),
  popup Koreksi (dibuka lalu Batal, tanpa menyimpan). Hanya data yang sudah ada;
  tidak membuat data uji di database dev tanpa izin; nilai dari layar tidak
  disalin ke kode, tes atau dokumen.

## 6. Dokumen

`CLAUDE.md`: baris **UI** di Conventions menyebut `/services` dan Riwayat
layanan sudah MD3, `.cart-bar` kini hanya dipakai lewat timpaan MD3, dan
`.cart-panel` / `.cart-panel-open` tidak dipakai lagi (CSS-nya dibiarkan, dibuang
nanti bersama kelas lama lain).
