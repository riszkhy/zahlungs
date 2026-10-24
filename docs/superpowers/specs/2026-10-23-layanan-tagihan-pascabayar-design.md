# Desain — Layanan PPOB, tagihan pascabayar (BPJS, PDAM, Telkom, Gas PGN)

Tanggal: 2026-10-23 · Status: menunggu tinjauan
Dibangun di atas: `docs/superpowers/specs/2026-10-21-layanan-ppob-sbi-design.md`
(branch `feat/layanan-ppob-fase-1`)

## Tujuan

Kasir bisa menerima pembayaran **BPJS Kesehatan, PDAM, Telkom/IndiHome dan Gas
PGN** dari layar Layanan, dengan alur yang sama seperti Tagihan PLN: lewat akun
API (SBI) dicek dulu lalu dibayar, lewat akun manual nominalnya diketik.

Berhasil bila:

- keempat jenis tagihan bisa dicek dan dibayar, tercatat benar di kas shift,
  perkiraan saldo deposit dan laporan layanan;
- BPJS Kesehatan bisa dibayar untuk 1–12 bulan sekaligus;
- Tagihan PLN tetap berjalan seperti sekarang, di bawah kategori baru
  "Tagihan".

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Kategori | Satu kategori **Tagihan** (`tagihan`) untuk semua tagihan, termasuk PLN; jenisnya dibedakan oleh produk (nama, kode vendor) |
| Data lama | `tagihan_pln` di produk dan transaksi dimigrasi menjadi `tagihan` |
| Jumlah bulan (BPJS) | Per produk: centang **"Tanyakan jumlah bulan saat cek tagihan"**; kasir memilih 1–12 bulan sebelum Cek tagihan |
| Harga (akun API) | Seperti Tagihan PLN: total penyedia + biaya tambahan toko × bulan |
| Akun manual | Nominal tagihan diketik (alur Fase 0); jumlah bulan tidak ditanyakan |
| Pendekatan | Perluas aturan tagihan yang ada; tidak ada alur baru |

Produk SBI yang dipakai (dipilih admin lewat "Cari di daftar SBI"): `PLN`,
`BPJSKS`, PDAM per daerah (505 kode, mis. `PDAMSLTG`), `TELKOM` / `TELEPON`,
`PGN`.

## Perubahan data

Migrasi baru:

1. `service_products.ask_months` (boolean, default false, not null).
2. `service_inquiries.months` (integer, boleh kosong): jumlah bulan yang
   diminta kasir.
3. `UPDATE service_products SET category = 'tagihan' WHERE category =
   'tagihan_pln'`, dan sama untuk `service_transactions`. Rollback membalik
   `tagihan` → `tagihan_pln` (sebelum migrasi, tagihan hanya PLN).

`Product.categories/0` menjadi `~w(pulsa paket_data token_pln tagihan)`;
label `Services.categories/0` "Tagihan". `ask_months` di-cast di
`Product.changeset/2`.

## Aturan inti

- Semua aturan yang kini memeriksa `"tagihan_pln"` beralih ke `"tagihan"`
  (`Product.bill?/1` dan pemakaiannya): inquiry kind `"bill"`, ref inquiry
  dipakai ulang saat bayar, harga dari `inquiry_price/1`, biaya tambahan per
  bulan, `note_vendor_price` tidak menandai produk tagihan, tanda "Jumlah …"
  di struk.
- **Jumlah bulan.** `Services.inquire/4` menerima `opts` dengan `months`
  (1–12); diabaikan bila produk tidak `ask_months`, wajib (default 1) bila
  `ask_months`. Nilai di luar 1–12 → `{:error, :invalid_months}`. Disimpan di
  `service_inquiries.months` dan dikirim ke adapter sebagai `periode`
  (permintaan inquiry: kunci `months`).
- **Lembar = bulan.** `sheets` inquiry = jumlah bulan dari jawaban penyedia
  (`Jml bulan:`); bila jawaban tidak menyebutnya dan inquiry punya `months`,
  `sheets` = `months`. Harga = `provider_total` + `api_extra_fee` × `sheets`.
- **Bayar.** Adapter SBI mengirim `periode` saat `payment` bila inquiry-nya
  punya `months` (permintaan bayar: kunci `months`, dibaca dari inquiry
  seperti `inquiry_ref`).
- **Akun manual** tidak berubah: `bill_amount` diketik, `sheets` 1.

## Adapter SBI

- `inquiry/2` dan `pay/2`: bila permintaan membawa `months`, body JSON
  menyertakan `"periode" => "<months>"`. `sign` tidak berubah (SBI tidak
  menandatangani `periode`).
- Katalog: `category_hint` `"tagihan"` untuk semua item grup `PPOB` (bukan
  hanya kode `PLN`).

## Layar

- **Layanan:** tab **Tagihan**. Produk tagihan di akun API: ID pelanggan; bila
  `ask_months`, pilihan **Jumlah bulan** (1–12, default 1); **Cek tagihan**;
  kartu (nama, periode, "N bulan", tagihan, admin penyedia, tambahan toko,
  total); Bayar. Mengubah ID pelanggan **atau** jumlah bulan setelah cek
  membuang hasil cek.
- **Produk layanan:** kategori "Tagihan"; centang **"Tanyakan jumlah bulan
  saat cek tagihan"** untuk Tagihan; label biaya tetap.
- **Struk:** "Jumlah N bulan".
- **Laporan layanan:** baris "Tagihan" (termasuk PLN lama).
- Teks "Tagihan PLN" yang tersisa di layar dan bantuan diganti "Tagihan".

## Pengujian

- Test Tagihan PLN yang ada lulus dengan kategori `tagihan` (fixture
  `api_product_fixture` berkategori `tagihan`).
- BPJS (`ask_months`): `inquire` dengan `months: 3` menyimpan `months` 3 dan
  mengirim `periode` "3" (StubClient); jawaban tanpa `Jml bulan` → `sheets`
  3, harga = total + tambahan × 3; `months` 0 atau 13 → `:invalid_months`;
  produk tanpa `ask_months` mengabaikan `months`; `pay` mengirim `periode`.
- PDAM/Telkom/PGN: inquiry dan bayar dengan kode vendornya (StubClient).
- Akun manual: tagihan BPJS dengan nominal diketik.
- Migrasi: test schema — `tagihan_pln` bukan lagi kategori yang sah; laporan
  menghitung transaksi `tagihan` di baris "Tagihan". Pemindahan data diperiksa
  di database dev setelah `mix ecto.migrate`: tidak ada lagi baris
  `tagihan_pln` di `service_products` maupun `service_transactions`, dan
  `mix ecto.rollback --step 1` mengembalikannya.
- Katalog: item grup PPOB (`BPJSKS`, `PDAMSLTG`, `TELKOM`, `PGN`) →
  `category_hint` `"tagihan"`.
- Layar: pilihan jumlah bulan hanya untuk produk `ask_months`; mengubahnya
  membuang hasil cek; kartu menampilkan "3 bulan".

## Di luar cakupan

- PBB (butuh tahun), kartu kredit (butuh nominal), multifinance, PKB, TV
  pascabayar, HP pascabayar (bisa memakai alur yang sama nanti, kecuali yang
  butuh isian tambahan).
- Pengelompokan laporan per jenis tagihan.
