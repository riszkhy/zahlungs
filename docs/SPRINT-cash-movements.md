# Sprint Plan — Cash Movements (kas masuk/keluar laci) + bayar konsinyasi

## Masalah yang diselesaikan

Saat ini uang yang keluar/masuk laci **di tengah shift** (setor ke brankas, beli
keperluan, **bayar supplier konsinyasi**) tidak bisa dicatat. Akibatnya kalau
kasir bayar supplier dari laci, tutup shift menunjukkan **variance minus besar
tanpa penjelasan**.

Solusi: modul **cash movements** — mencatat setiap pergerakan kas laci, dengan
salah satu tipe khusus **"Pembayaran konsinyasi"** yang ditautkan ke supplier +
shift, dan otomatis masuk perhitungan tutup kas.

## Model

Setiap gerakan kas punya **arah** (`in`/`out`) dan **kategori**:

| Kategori              | Arah | Contoh                                   |
| --------------------- | ---- | ---------------------------------------- |
| `cash_in`             | in   | tambah modal, uang masuk lain            |
| `cash_drop`           | out  | setor sebagian uang laci ke brankas      |
| `expense`             | out  | beli galon/kantong plastik dari laci     |
| `consignment_payment` | out  | **bayar supplier barang titipan**        |

Amount disimpan **positif**; arah menentukan tambah/kurang. Kas ekspektasi jadi:

> **expected_cash = opening + cash sales + Σ(in) − Σ(out)**

`consignment_payment` **wajib** menautkan `supplier_id`.

---

## CM.0 — Data model

- **CM.0.1** Migrasi: tabel `cash_movements` — `shift_id` (FK, not null),
  `user_id` (FK), `direction` (string), `category` (string), `amount` (decimal),
  `supplier_id` (FK nullable), `note` (string), timestamps. Index `shift_id`.
- **CM.0.2** Schema `Zahlungs.Shifts.CashMovement` + changeset: validasi
  `direction` ∈ (in/out), `category` ∈ daftar, `amount > 0`, dan **`supplier_id`
  wajib bila `category == "consignment_payment"`**. Derive `direction` dari
  kategori (server-side) agar konsisten.

## CM.1 — Integrasi Shifts

- **CM.1.1** `Shifts.add_cash_movement/2` (hanya untuk shift `open`),
  `list_cash_movements/1` (per shift).
- **CM.1.2** `expected_cash/1` + `shift_summary/1`: tambahkan Σ(in) dan Σ(out);
  `expected = opening + cash_sales + cash_in − cash_out`. Tambah field
  `cash_in`, `cash_out` ke summary. `close_shift` otomatis ikut karena memakai
  `expected_cash/1`.

## CM.2 — UI Kasir (saat shift terbuka)

- **CM.2.1** Tombol **"Catat kas"** di banner shift → modal: pilih tipe
  (Setor/Ambil/Beli/**Bayar konsinyasi**), amount (format ribuan), catatan; bila
  "Bayar konsinyasi" tampil select **Supplier**.
- **CM.2.2** Daftar ringkas gerakan kas shift berjalan + subtotal in/out; preview
  tutup kas (modal close) menampilkan baris Cash in / Cash out sebelum expected.

## CM.3 — Riwayat & tautan ke settlement

- **CM.3.1** Detail shift (`/shifts/:id`): tabel gerakan kas (waktu, tipe,
  supplier, jumlah, catatan).
- **CM.3.2** Laporan settlement konsinyasi: tambah kolom **"Sudah dibayar"**
  (Σ `consignment_payment` per supplier pada rentang) dan **"Sisa (outstanding)"**
  = payable − dibayar. Inilah payoff-nya: terlihat utang vs yang sudah dibayar.

## CM.4 — Tests + migrate + compile + verify

- Movement wajib shift open; `consignment_payment` wajib supplier.
- `expected_cash`: `cash_out` mengurangi, `cash_in` menambah; variance akurat
  setelah bayar supplier dari laci.
- Settlement: "sudah dibayar" & "outstanding" benar; retur tetap dikecualikan.
- `mix compile` bersih, `mix ecto.migrate`, `mix test` hijau, boot verify.

---

## Di luar cakupan (sengaja)

- Multi-laci/register.
- Approval/otorisasi pengeluaran (misal butuh persetujuan admin) — bisa sprint
  lanjutan; sekarang kasir mencatat langsung.
- Rekonsiliasi bank/transfer untuk pembayaran non-tunai ke supplier — modul ini
  fokus pada kas laci.
