# Konsep: Shift Kasir (Cashier Shift / Sesi Kas)

| | |
|---|---|
| **Produk** | Zahlungs POS |
| **Status** | Draft konsep |
| **Tanggal** | 30 Juni 2026 |
| **Terkait** | `Zahlungs.Sales`, `Zahlungs.Accounts` (role cashier/admin), `docs/PRD-POS.md` |

---

## 1. Ringkasan

**Shift kasir** adalah satu sesi kerja seorang kasir di laci uang (cash drawer): dimulai
dengan **modal awal** (opening cash), mencatat semua transaksi selama sesi, dan diakhiri
dengan **hitung fisik uang** (closing cash). Sistem membandingkan **uang seharusnya**
(expected) dengan **uang aktual** (counted) untuk mendapatkan **selisih (variance)** —
sehingga tiap kasir bertanggung jawab atas kasnya sendiri.

Tujuannya: akuntabilitas kas per kasir, deteksi selisih (lebih/kurang), dan pelaporan
penjualan **per shift**.

---

## 2. Tujuan & Non-Goals

### Tujuan
- Kasir wajib **buka shift** (isi modal awal) sebelum bertransaksi.
- Setiap penjualan **tertaut ke shift** yang sedang terbuka.
- Saat **tutup shift**, sistem menghitung kas seharusnya dan **selisih** terhadap hitungan fisik.
- Laporan & audit per shift / per kasir (dipakai admin).

### Non-Goals (v1)
- Multi-laci/register per kasir (asumsi 1 kasir = 1 laci).
- Manajemen kas besar / rekonsiliasi bank.
- Pembayaran non-tunai terpisah (lihat §8 — perlu `payment_method` dulu).

---

## 3. Model Data

### Tabel baru: `cashier_shifts`
```
id
user_id            → users (kasir pemegang shift)
opened_at          (utc_datetime)
closed_at          (utc_datetime, null saat masih open)
opening_cash       (decimal 12,2)  -- modal awal di laci
expected_cash      (decimal 12,2, null → diisi saat tutup)
counted_cash       (decimal 12,2, null → hasil hitung fisik saat tutup)
variance           (decimal 12,2, null → counted - expected)
status             (string: "open" | "closed")
note               (text, opsional — catatan selisih)
inserted_at / updated_at
```

### Perubahan tabel `sales`
```
+ shift_id          → cashier_shifts (nullable FK)
```
Setiap `create_sale` menandai `shift_id` = shift terbuka milik kasir tsb.

### (Opsional, fase lanjut) `cash_movements` — kas masuk/keluar non-penjualan
```
id, shift_id → cashier_shifts, kind ("in" | "out"),
amount (decimal), reason (string), inserted_at
```
Contoh: ambil uang untuk beli galon (`out`), tambah modal receh (`in`).

### Relasi
- `user` 1—N `cashier_shifts`
- `cashier_shift` 1—N `sales`
- `cashier_shift` 1—N `cash_movements` (opsional)

---

## 4. Rumus Rekonsiliasi

```
cash_sales     = Σ sale.total   (sales completed pada shift, metode tunai)
cash_refunds   = Σ sale.total   (sales pada shift yang di-return)
cash_in/out    = Σ cash_movements (opsional)

expected_cash  = opening_cash + cash_sales - cash_refunds + cash_in - cash_out
variance       = counted_cash - expected_cash
```
- `variance > 0` → **lebih (surplus)**
- `variance < 0` → **kurang (shortage)**
- `variance = 0` → pas ✅

> Catatan: bila kelak ada pembayaran non-tunai, hanya bagian **tunai** yang masuk
> `cash_sales`. Lihat §8.

---

## 5. State & Alur

```
                 buka shift (isi modal)
   [Tidak ada shift] ───────────────────────▶ [OPEN]
        ▲                                        │
        │        tutup shift (hitung fisik)       │  transaksi tertaut shift_id
        └──────────────── [CLOSED] ◀─────────────┘
```

### 5.1 Buka shift
1. Kasir login → jika **belum ada shift OPEN**, diarahkan/di-blok untuk **Buka Shift**.
2. Isi **modal awal** → shift `status: open`, `opened_at = now`.
3. Layar kasir aktif; banner menampilkan shift berjalan (kasir, jam buka, modal).

### 5.2 Selama shift
- Semua transaksi (`Sales.create_sale`) otomatis `shift_id` = shift open kasir.
- Return/refund pada transaksi shift ini memengaruhi `expected_cash`.

### 5.3 Tutup shift
1. Kasir klik **Tutup Shift** → sistem tampilkan **ringkasan**: modal, penjualan tunai,
   refund, **expected_cash**.
2. Kasir input **counted_cash** (hitung fisik laci) → sistem tampilkan **variance** live.
3. Konfirmasi → shift `status: closed`, simpan `expected_cash`, `counted_cash`, `variance`, `closed_at`, `note`.
4. Kasir tak bisa transaksi lagi sampai buka shift baru.

### 5.4 Aturan bisnis
- **Satu shift OPEN per kasir** dalam satu waktu.
- **Transaksi butuh shift OPEN** (kasir). Admin boleh dikecualikan (opsional).
- Logout saat shift open → shift tetap OPEN, dilanjut saat login lagi.
- **Admin** dapat melihat semua shift, memaksa tutup (force-close) shift terbengkalai, dan melihat laporan selisih.

---

## 6. Layar / UI

| Layar | Isi |
|---|---|
| **Buka Shift** (modal) | Input modal awal → mulai shift |
| **Banner kasir** | "Shift #12 • Kasir: budi • buka 09:00 • modal Rp 200.000" + tombol Tutup Shift |
| **Tutup Shift** (modal) | Ringkasan (modal, penjualan tunai, refund, expected) + input hitung fisik + preview selisih |
| **Riwayat Shift** (`/shifts`) | Daftar shift: kasir, buka/tutup, modal, expected, counted, **variance** (badge lebih/kurang), status |
| **Detail Shift** (`/shifts/:id`) | Ringkasan + daftar transaksi shift + kas masuk/keluar (opsional) + tombol cetak |
| **(Admin) Laporan shift** | Rekap variance per kasir/periode (lanjutan dari modul Laporan) |

Gunakan komponen yang sudah ada: `format_money/1`, `<.table>`, `<.modal>`, kartu ringkasan.

---

## 7. Integrasi dengan Kode Saat Ini

- **Context baru `Zahlungs.Shifts`**: `open_shift/2`, `close_shift/2` (hitung expected+variance, transaksional `Ecto.Multi`), `current_shift/1` (shift open milik user), `list_shifts/1`, `get_shift!/1`, `shift_summary/1`.
- **`Sales.create_sale/3`**: terima/`shift_id`; tolak bila kasir tak punya shift open (`{:error, :no_open_shift}`). Cashier UI: cek `current_shift`; jika nil → paksa buka shift.
- **`CashierLive`**: banner shift + guard "harus buka shift"; tombol buka/tutup.
- **Reports**: tambah dimensi shift (mis. `sales_by_shift`, variance per kasir) — memperluas modul laporan yang sudah ada.
- **Role**: buka/tutup shift = kasir & admin; laporan shift & force-close = admin.

---

## 8. Catatan & Perluasan

- **Metode pembayaran**: agar rekonsiliasi kas akurat saat ada kartu/QRIS, tambah
  `sales.payment_method` ("cash" | "card" | "qris" …). Hanya `cash` yang dihitung ke laci.
  (Saat ini semua transaksi dianggap tunai.)
- **Kas masuk/keluar** (`cash_movements`) untuk pengeluaran/pemasukan operasional.
- **Multi-register**: tambah `register_id` bila satu toko punya beberapa laci.
- **Cetak laporan shift** (mirip struk) untuk arsip.
- **Zona waktu**: `opened_at`/`closed_at` UTC; tampilkan sesuai zona toko.

---

## 9. Rencana Implementasi (bertahap)

| Fase | Isi |
|---|---|
| **1 — Fondasi** | Migrasi `cashier_shifts` + `sales.shift_id`; context `Shifts` (open/close/current); guard "harus buka shift" di kasir; tandai `shift_id` di `create_sale` |
| **2 — Tutup & rekonsiliasi** | Hitung `expected_cash`/`variance` saat tutup; modal buka/tutup + banner shift |
| **3 — Riwayat & laporan** | `/shifts` (list) + `/shifts/:id` (detail); rekap variance per kasir (admin) |
| **4 — Opsional** | `cash_movements`, `payment_method`, multi-register, cetak laporan shift |

**Definition of Done tiap fase**: migrasi + context (validasi) + LiveView + test context (happy path + edge: shift ganda/ tak ada shift/ variance), otorisasi role, `mix format` & compile bersih.
