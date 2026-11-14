# Layar kasir dengan Material Design 3

Tanggal: 2026-11-13 · Branch: `feat/kasir-md3` (dari `master`)

Hanya tampilan: tidak ada perubahan pada context, data, migrasi, aturan uang,
event, atau alur kerja kasir (scan → keranjang → Bayar → popup konfirmasi).

## Tujuan

Layar kasir memakai bahasa visual Material Design 3 (MD3) dengan identitas hijau
Zahlungs, dan meninggalkan fondasi (token + komponen) yang bisa dipakai halaman
lain satu per satu.

Ukuran berhasil:

- `/cashier` di ponsel dan tablet memakai warna peran, sudut, huruf, dan komponen
  MD3 di bawah; tidak ada lagi teks tombol berhuruf kapital semua.
- Semua event `phx-*`, id elemen, dan hook (`Beeper`, kamera barcode, input uang)
  tetap sama; tes kasir yang ada tetap lulus, kecuali yang memeriksa struktur
  HTML lama (disesuaikan).
- Halaman lain tidak berubah, kecuali navbar (dipakai bersama).
- Tidak ada dependensi baru (npm atau hex), tidak ada font yang diunduh.

Di luar cakupan: halaman lain, mode gelap, menyeragamkan bahasa teks (yang masih
Inggris tetap Inggris), format uang (`format_money/1` tetap, mis. `Rp 27.500,00`),
flash message.

## 1. Token

### Warna

Variabel CSS di `:root` dalam `assets/css/app.css`, bernama `--md-<peran>`, nilai
hex di bawah. Dihitung dari warna sumber `#15803d` (green-700, hijau Zahlungs
sekarang): nada = L\* CIELAB pada hue sumber, chroma dipotong ke sRGB (pendekatan
HCT). Nilainya ditulis langsung, tidak dihitung saat build.

| Peran | Hex | Peran | Hex |
|---|---|---|---|
| `primary` | `#016D30` | `on-primary` | `#FFFFFF` |
| `primary-container` | `#ABF3B8` | `on-primary-container` | `#002106` |
| `secondary` | `#4C6450` | `on-secondary` | `#FFFFFF` |
| `secondary-container` | `#CEEAD2` | `on-secondary-container` | `#0A200E` |
| `tertiary` | `#006971` | `on-tertiary` | `#FFFFFF` |
| `tertiary-container` | `#96F1FA` | `on-tertiary-container` | `#002023` |
| `error` | `#BA1A1A` | `on-error` | `#FFFFFF` |
| `error-container` | `#FFDAD6` | `on-error-container` | `#410002` |
| `warning` | `#914D00` | `on-warning` | `#FFFFFF` |
| `warning-container` | `#FFDCC2` | `on-warning-container` | `#2B1700` |
| `surface` | `#F4FBF5` | `on-surface` | `#181D19` |
| `surface-container-lowest` | `#FFFFFF` | `on-surface-variant` | `#3E4A40` |
| `surface-container-low` | `#EEF5EF` | `outline` | `#6E7A6F` |
| `surface-container` | `#E9F0E9` | `outline-variant` | `#BDCABE` |
| `surface-container-high` | `#E3EAE4` | `inverse-surface` | `#2C322D` |
| `surface-container-highest` | `#DDE4DE` | `inverse-on-surface` | `#ECF2EC` |

`error*` dari palet baseline MD3. `warning*` adalah peran tambahan (MD3 tidak
punya), dihitung dengan cara yang sama dari `#d97706`.

`assets/tailwind.config.js` memetakan setiap peran ke `theme.extend.colors` dengan
nama yang sama (`bg-primary`, `text-on-surface`, `bg-surface-container-high`,
`border-outline`, `bg-warning-container`, …), nilainya `var(--md-<peran>)`.
Nama Tailwind bawaan (`green-700`, `gray-300`, …) tetap ada; halaman lain tidak
tersentuh.

### Bentuk, elevasi, huruf

- **Sudut** (`theme.extend.borderRadius`): `md3-xs` 4px, `md3-sm` 8px, `md3-md`
  12px, `md3-lg` 16px, `md3-xl` 28px, `full` untuk pil.
- **Elevasi** (`theme.extend.boxShadow`): `elev-1`, `elev-2`, `elev-3` (nilai MD3:
  dua lapis bayangan hitam tipis). Kartu dan panel tidak berbayang; beda tingkat
  ditunjukkan oleh warna `surface-container-*`. Bayangan hanya untuk dialog
  (`elev-3`) dan bottom sheet (`elev-1`).
- **Huruf**: `font-family: Roboto, system-ui, sans-serif` untuk elemen dengan
  kelas `md3` (akar layar kasir dan navbar); tidak ada `@font-face`.
  Skala (`theme.extend.fontSize`): `title-lg` 22/28, `title-md` 16/24 500,
  `title-sm` 14/20 500, `body-lg` 16/24, `body-md` 14/20, `body-sm` 12/16,
  `label-lg` 14/20 500, `label-md` 12/16 500, `headline-sm` 24/32.
  Label tombol tidak `uppercase`.

### State layer

Kelas `.md-state` di `app.css`: `::before` menutupi elemen dengan warna teksnya
(`currentColor`), opasitas 0 → 0.08 saat hover, 0.10 saat `:focus-visible`,
0.10 saat `:active`; elemen `disabled` tanpa state layer dan 38% opasitas.
Semua komponen interaktif di bawah memakainya.

## 2. Komponen — `lib/zahlungs_web/components/md_components.ex`

Modul `ZahlungsWeb.MdComponents`, di-import di `html_helpers` bersama
`CoreComponents`. Semua kelas Tailwind memakai token di atas. Target sentuh
minimal 44px (aturan `.touch-target` yang ada).

| Fungsi | Attr penting | Bentuk |
|---|---|---|
| `md_button/1` | `variant` `"filled"` (default) / `"tonal"` / `"outlined"` / `"text"` / `"danger"`, `type`, `class`, global `disabled form name value phx-*` | pil, tinggi 40px (44px di `pointer: coarse`), `label-lg`. `filled` = `bg-primary text-on-primary`; `tonal` = `bg-secondary-container text-on-secondary-container`; `outlined` = border `outline`, teks `primary`; `text` = teks `primary`; `danger` = `bg-error text-on-error`. Slot `inner_block`, slot opsional `icon`. |
| `md_chip/1` | `selected` (bool), `kind` `"filter"` / `"assist"`, global | sudut 8px, tinggi 32px (44px sentuh). Filter terpilih: `bg-secondary-container`, centang di depan, tanpa border. Tidak terpilih: border `outline`. Assist: border `outline`, ikon opsional, teks `on-surface`. `aria-pressed` untuk filter. |
| `md_search/1` | `id`, `name`, `value`, `placeholder`, global; slot `trailing` | pil `bg-surface-container-high`, ikon search di depan, `body-lg`; input di dalamnya tetap `<input>` biasa (hook dan `phx-*` dipasang oleh pemanggil lewat global). |
| `md_card/1` | `variant` `"filled"` / `"outlined"` / `"elevated"`, `class` | sudut 12px, padding 16px. filled = `bg-surface-container-highest`; outlined = border `outline-variant`, `bg-surface`; elevated = `bg-surface-container-low` + `elev-1`. (Tile produk bukan `md_card`, lihat §3.) |
| `md_segmented/1` | `name`, `value` (terpilih), `options` (list `{value, label}`), `disabled_options` (list value), global (`phx-click`, `form`) | pil ber-border `outline`, segmen dipisah garis; tiap segmen `<label>` berisi `<input type="radio" class="sr-only">`, sehingga tetap terkirim di form; segmen terpilih `bg-secondary-container` + centang. Maksimal 5 segmen. |
| `md_text_field/1` | sama dengan `<.input>` untuk `type` text/number/date/search/select (`options`, `prompt`) + `label`, `supporting` | outlined, sudut 4px, label di atas kolom (bukan label melayang), `errors` di bawah dengan warna `error`. |
| `md_dialog/1` | `id`, `show`, `on_cancel`; slot `title`, `inner_block`, `actions` | memakai `show_modal/2` dan `hide_modal/2` dari `CoreComponents`, struktur dan id sama dengan `<.modal>` (`#{id}-bg`, `#{id}-container`, `#{id}-content`, ✕ di luar `-content`, `focus_wrap`, Esc, klik di luar). Panel `bg-surface-container-high`, sudut 28px, `elev-3`, judul `headline-sm`, `actions` rata kanan dengan jarak 8px. |
| `md_sheet/1` | `open` (bool), `on_close` (event), `id`; slot `inner_block` | bottom sheet: latar redup `bg-black/30` (klik = `on_close`), panel `bg-surface-container-low` sudut atas 28px, pegangan 32×4px di tengah atas, `elev-1`. Hanya di layar < `lg` (dan bukan `md:landscape`); di layar lebar isinya tampil sebagai panel biasa. |
| `md_icon/1` | `name` (`search` `camera` `check` `plus` `minus` `close` `cart` `history` `person`), `class` | SVG 24px inline, `currentColor`, `aria-hidden`. |

`<.button>`, `<.modal>`, `<.input>`, dan kelas `.chip` / `.btn` di
`core_components.ex` / `app.css` tidak diubah.

### Navbar

`layouts/app.html.heex` menjadi top app bar MD3 untuk semua halaman:
`bg-surface-container text-on-surface`, judul aplikasi `title-lg`, link navigasi
`label-lg` dengan yang aktif ditandai `bg-secondary-container` pil, pemilih toko
`md_text_field` gaya filled kecil, tombol Menu `md_button variant="text"` dengan
ikon. Struktur link, id, dan perilaku drawer tidak berubah.

## 3. Layar kasir — `cashier_live.ex`

Akar layar mendapat kelas `md3 bg-surface text-on-surface`. Breakpoint dua kolom
tetap yang sekarang (`lg` dan `md:landscape`).

### Belum ada shift

Satu `md_card variant="outlined"` di tengah: judul `title-lg` "Open shift",
`md_text_field` kas awal (`id="opening-cash-input"`, hook uang tetap),
`md_button` filled penuh "Open shift".

### Kolom produk

1. **Kartu shift**: `md_card` `bg-surface-container-low` sudut 12px — toko
   (`title-sm`), `Shift #n · dibuka <tanggal jam> · float <uang>` (`body-sm`
   `on-surface-variant`); di kanan `md_button variant="outlined"` "Catat kas" dan
   `md_button variant="outlined"` "Close shift" berteks `error`.
2. **Search bar**: `md_search` untuk input pemindai yang ada (id dan hook tetap);
   slot `trailing` = tombol ikon 40px yang menggantikan tombol teks
   "📷 Scan with camera" / "■ Stop camera": event dan elemen `BarcodeScanner`
   sama; ikon `camera` dengan `aria-label="Scan with camera"`, atau ikon `close`
   dengan `aria-label="Stop camera"` saat `@scanning`. Teks tip pindah ke bawah
   bar sebagai `body-sm` `on-surface-variant`.
3. **Chip panel**: `md_chip kind="filter"` "Piutang" (ikon `person`,
   `phx-click="toggle_receivable"`, `selected={@receivable_open}`) dan
   "Ditunda (n)" (ikon `history`, `phx-click="toggle_held"`,
   `selected={@held_open}`), teks dan syarat tampil sama dengan sekarang. Panel
   yang dibukanya (`#receivable-panel`, `#held-carts`) jadi
   `md_card variant="outlined"`.
4. **Kategori**: `md_chip kind="filter"` per kategori dan "Semua", dalam baris yang
   bisa digeser (`overflow-x-auto`, tanpa scrollbar terlihat), yang aktif
   `selected`.
5. **Tile produk**: `<button>` dengan `.md-state`, `bg-surface-container-low`
   sudut 12px, tanpa border dan bayangan, tinggi minimal 88px: nama `title-sm`
   (maks 2 baris), harga `label-lg` `text-primary`, stok `body-sm`
   `on-surface-variant`. Stok 0: opasitas 38%, teks "Habis" `text-error`,
   tetap `disabled` seperti sekarang. Tekan = state layer, bukan border hijau.

### Keranjang (panel kanan di layar lebar, bottom sheet di ponsel)

Panel `bg-surface-container-lowest` sudut 16px, padding 16px.

- Judul `title-md` "Cart" + jumlah item.
- Baris item: nama `body-lg`, harga satuan dan promo (`Hemat promo …`) `body-sm`;
  kanan: `md_button variant="outlined"` bulat 44px berikon `minus`, jumlah
  `title-sm`, `md_button variant="tonal"` bulat 44px berikon `plus`. Pemisah
  `outline-variant`.
- Diskon dan pajak: dua `md_text_field` berdampingan (id dan hook uang tetap).
- **Metode bayar**: `md_segmented` dengan opsi yang sama dan urutan yang sama
  dengan tombol sekarang (Tunai, QRIS, Kartu, Transfer, Piutang), yang tidak
  tersedia tetap tidak bisa dipilih (`disabled_options`); event pemilihan sama.
- Uang diterima: `md_text_field` (`id="amount-paid"`) + `md_chip kind="assist"`
  "Uang pas".
- Panel kredit (`#credit-panel`): `md_card` `bg-warning-container
  text-on-warning-container`, isi dan field sama; tombol kecil "Ganti" dan
  "+ Pelanggan baru" (sekarang `.chip-sm`) jadi `md_button variant="text"`.
- Ringkasan Subtotal / Total / Change: `body-md`, Total `title-md`.
- Tombol utama: `md_button` filled penuh, tinggi 56px, `phx-click="review_checkout"`,
  `disabled={not @can_checkout}`, teks sama dengan sekarang.
- Tunda (`#hold-form`): `md_text_field` nama + `md_button variant="outlined"`.

### Ponsel (< `lg`, bukan `md:landscape`)

- `.cart-bar` menjadi bottom app bar: `bg-surface-container`, tinggi 80px,
  `elev-2`; kiri `n item` (`body-sm`) dan total (`title-lg`); kanan `md_button`
  filled "Bayar" / "Tutup" (event `toggle_cart`, `disabled={@cart == []}` seperti
  sekarang).
- Keranjang dirender di dalam `md_sheet open={@cart_open} on_close="toggle_cart"`;
  di layar lebar tetap panel kanan. Assign dan event (`cart_open`, `toggle_cart`)
  tidak berubah; kelas `cart-panel` / `cart-panel-open` diganti oleh `md_sheet`.

### Popup

Keempat `<.modal>` di kasir menjadi `md_dialog` dengan id yang sama:

- `confirm-sale`: judul "Konfirmasi penjualan"; `actions` = Batal
  (`md_button variant="text"`, tetap elemen pertama yang difokus) lalu
  "Ya, selesaikan" (filled, `phx-disable-with` sama).
- `receipt-modal`: judul "Transaction complete", "Receipt <kode>" sebagai
  `body-md`, struk sama; `actions` = "Print receipt" (`md_button variant="text"`,
  link yang sama), "Koreksi / batalkan" (`text`, berwarna `warning`, link yang
  sama), "New Transaction" (filled, `phx-click="new_sale"`).
- `close-shift-modal`: ringkasan dalam `md_card` filled; tombol
  `md_button variant="danger"` "Close shift".
- `movement-modal`: judul "Catat kas laci" + kalimat penjelas `body-md`; Tipe dan
  Supplier `md_text_field type="select"` (opsi dan syarat sama), Jumlah
  `md_text_field` (`id="movement-amount-input"`, hook `MoneyInput`, `phx-update`
  sama), Catatan `md_text_field`; filled penuh "Simpan".

## 4. Pengujian

- Tes yang ada di `test/zahlungs_web/live/cashier_live_test.exs` (61) dan seluruh
  suite tetap lulus. Yang memeriksa kelas lama (`cart-panel-open`, `chip-active`,
  …) atau teks huruf kapital disesuaikan, dengan alasan di commit.
- `test/zahlungs_web/md_components_test.exs` baru (`render_component/2`):
  - `md_button`: setiap varian memberi kelas warnanya; tidak ada `uppercase`;
    `disabled` dan `phx-disable-with` diteruskan.
  - `md_chip`: filter terpilih punya centang dan `aria-pressed="true"`.
  - `md_segmented`: satu `<input type="radio">` per opsi dengan `name` yang
    diberikan, yang terpilih `checked`, opsi di `disabled_options` `disabled`.
  - `md_dialog`: id `#{id}-content` ada dan ✕ di luarnya; `role="dialog"`.
  - `md_sheet`: tertutup tidak merender panel di bawah `lg`; terbuka merender
    latar dengan `phx-click` = `on_close`.
- Tes kasir baru (LiveDriver):
  - tombol kamera ada di dalam search bar (`md_search` trailing);
  - metode bayar berupa segmented button: memilih QRIS lewat event yang sama
    mengubah segmen terpilih;
  - `toggle_cart` membuka bottom sheet (panel sheet dirender, `cart_open` true);
  - popup konfirmasi tetap memfokuskan Batal lebih dulu (`Batal` sebelum
    `Ya, selesaikan`).
- Pemeriksaan visual di panel browser pada 375×812 (ponsel) dan 1280×800
  (tablet/desktop): layar tanpa shift, layar dengan keranjang berisi, bottom sheet,
  dan popup konfirmasi (dibuka lalu Batal; tidak ada penjualan yang disimpan).
  Data yang dipakai: yang sudah ada di layar; tidak membuat data uji di database
  dev tanpa izin.

## 5. Dokumen

- `CLAUDE.md`: satu baris di Conventions tentang token MD3 (`--md-*`, kelas
  Tailwind), `MdComponents`, dan bahwa halaman baru/revamp memakainya.
