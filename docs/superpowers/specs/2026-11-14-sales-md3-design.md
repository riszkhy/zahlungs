# Riwayat penjualan dengan Material Design 3

Tanggal: 2026-11-14 · Branch: `feat/sales-md3` (dari `feat/layanan-md3`, yang
belum di-merge; kalau itu di-merge lebih dulu, branch ini menyusul di atas
`master`)

Tampilan, ditambah satu perubahan alur: **Return sekarang lewat popup
konfirmasi MD3**, bukan konfirmasi bawaan browser. Tidak ada perubahan pada
context (`Sales`), data, migrasi, aturan uang atau stok.

## Tujuan

`/sales` (`SalesLive.Index`) memakai token dan komponen MD3 yang sudah dipakai
Kasir, Layanan dan Riwayat layanan
(`2026-11-13-kasir-md3-design.md`, `2026-11-14-layanan-md3-design.md`), supaya
kasir yang berpindah dari Kasir ke riwayat penjualan melihat satu bahasa
visual. Return (tidak bisa dibatalkan) mendapat popup sendiri dengan Batal
lebih dulu, seperti "bayar tanya dulu" di Kasir dan Layanan.

Ukuran berhasil:

- Template `/sales` tidak lagi memakai `.header`, `.table`, `<.modal>`,
  `<.button>`, `.list-card`, `.form-control`, `btn`/`btn-sm`/`btn-link` atau
  warna Tailwind bawaan (`gray-*`, `green-*`, `red-*`, `amber-*`). Pengecualian:
  `.pagination` dan `sale_receipt` (bersama, tetap gaya lama).
- Event yang ada (`filter`, `page`, `prompt_void`, `cancel_void`,
  `void_change`, `do_void`), id `sale-card-<id>`, `sale-modal`, `void-modal`
  dan nama field (`date`, `reason`) tetap sama; tes yang ada tetap lulus,
  kecuali yang memakai event `return` (diganti, lihat §3) atau kelas lama.
- Kasir dan halaman lain tidak berubah.
- Tidak ada dependensi baru.

Di luar cakupan: `sale_receipt`, `.pagination`, `.header`/`.table`/`<.modal>`
di `core_components.ex`, halaman struk cetak (`ReceiptController`), teks status
(`completed` / `returned` / `void` tetap seperti sekarang), bahasa teks, mode
gelap, halaman laporan.

## Pendekatan

Dipilih: **halaman ditulis ulang dengan MdComponents; tabel ditulis langsung di
halamannya; ketiga popup memakai `md_dialog`; Return mendapat popup
konfirmasi.** Sama dengan cara Layanan.

Dipertimbangkan dan tidak dipilih:

- Mengubah `.table` / `.modal` bersama ke MD3 — semua halaman admin yang belum
  direvamp ikut berubah tanpa diperiksa.
- Hanya mengganti kelas warna — tidak seragam dengan Kasir/Layanan, dan Return
  tetap memakai konfirmasi browser.

## 1. `MdComponents`

Satu tambahan: `md_button` meneruskan `target` (dan `rel`) lewat global, untuk
"Cetak struk" yang membuka tab baru (`href` + `target="_blank"`).

## 2. Halaman `/sales`

Akar seperti Layanan: `<div class="md3 -m-6 rounded-xl bg-surface p-4
text-on-surface">`.

- **Judul:** "Sales" `headline-sm`, anak judul "Riwayat transaksi" `body-md
  text-on-surface-variant` (teks sama).
- **Filter:** form `phx-change="filter"`, `md_text_field type="date"
  name="date" label="Filter by date"`, nilai tetap.
- **Layar sempit (< `lg`):** tiap penjualan `md_card variant="outlined"` yang
  bisa diketuk (link `patch` ke `/sales/:id`, id `sale-card-<id>`): kiri kode
  `title-sm` dan baris kecil waktu · jumlah item (· cabang bila semua toko)
  `body-sm text-on-surface-variant`; kanan total dan badge status bertumpuk.
  Kosong: "Belum ada penjualan." `body-md text-on-surface-variant`.
- **Layar lebar (`lg`+):** tabel ditulis di halaman, `div#sales` dengan
  `rounded-md3-lg` dan latar `surface-container-low`, kolom Code, Date, Store
  (hanya semua toko), Cashier, Items, Total (rata kanan), Status (badge), dan
  aksi "View" (`md_button variant="text"`, `patch`). Baris id `sales-<id>`.
  Kosong: satu baris "Belum ada penjualan.".
- **Badge status:** `md_badge` — `completed` → success, `returned` → error,
  `void` → neutral; teks status apa adanya.
- `.pagination` tetap.

## 3. Popup

**Detail** (`md_dialog id="sale-modal"`, `on_cancel` patch ke `/sales`):
judul "Sale <kode>", `sale_receipt` apa adanya, baris Status (badge) dan
Alasan batal (bila void) dengan `body-md`. Aksi: "Print receipt"
(`md_button variant="text"`, `href` ke struk, tab baru), lalu — dengan aturan
tampil yang sama seperti sekarang — "Batalkan (koreksi)" (`tonal`, membuka
popup batal) dan "Return / Refund" (`danger`, membuka popup return).

**Batalkan** (`md_dialog id="void-modal"`): judul "Batalkan penjualan
<kode>", penjelasan yang sama, form `phx-change="void_change"
phx-submit="do_void"` dengan `md_text_field name="reason" label="Alasan
koreksi"` (wajib, placeholder sama) sebagai elemen pertama sehingga difokus.
Aksi: Batal (`text`, `cancel_void`), "Konfirmasi batalkan" (`filled`, submit).

**Return** (baru, `md_dialog id="return-modal"`), admin saja:

- Judul "Return penjualan <kode>". Isi: total penjualan, dan kalimat bahwa
  penjualan ditandai *returned*, stok dikembalikan ke cabang penjualan, dan
  uang tunai dikembalikan dari laci (untuk piutang: uang mukanya saja); tidak
  bisa dibatalkan.
- Aksi: **Batal** lebih dulu (fokus pertama, `text`, `cancel_return`), lalu
  "Return" (`danger`, `confirm_return`, `phx-disable-with`).
- Event:
  - `prompt_return` (`id`): hanya admin (selain itu flash izin, seperti
    sekarang); memuat penjualan dengan `Sales.get_sale!/2` lewat scope dan
    menyimpannya di `@returning`.
  - `cancel_return`: `@returning` jadi nil.
  - `confirm_return`: tidak berbuat apa-apa bila `@returning` nil (klik kedua);
    peran diperiksa lagi; `Sales.return_sale/2` dengan penjualan yang dimuat
    ulang lewat scope; pesan sukses/gagal sama seperti sekarang; `@returning`
    dikosongkan, daftar dimuat ulang, patch ke `/sales`.
  - Event lama `return` dihapus; tes return beralih ke `prompt_return` +
    `confirm_return`.
- `return_sale/2` tetap yang mengunci dan memeriksa ulang (sudah di-return,
  shift tutup → refund di laci admin); popup tidak menggantikannya.

## Tes

- Halaman MD3: akar `md3`, tidak ada kelas lama (kecuali pagination dan isi
  struk), tabel punya kolom yang benar, Store hanya untuk semua toko.
- Kartu dan baris tabel: badge tone per status.
- Popup detail: tombol sesuai peran/status; "Print receipt" ke struk dengan
  `target="_blank"`.
- Return: kasir ditolak di `prompt_return`; admin `prompt_return` → popup
  dengan Batal sebelum Return; `cancel_return` tidak mengubah apa pun;
  `confirm_return` tanpa popup tidak berbuat apa-apa; return dua kali
  (popup dibuka dari dua layar) dilaporkan "already been returned" dan stok
  kembali sekali; return setelah shift tutup tetap refund di laci admin.
- Void: tes yang ada tetap lulus; field Alasan elemen pertama di popup.

## Diserahkan ke pembangun

Spasi, ukuran huruf persis di dalam kartu/tabel, dan teks kalimat penjelasan
Return, selama mengikuti token MD3 dan isi di atas.
