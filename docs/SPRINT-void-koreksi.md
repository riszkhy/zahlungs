# Sprint Plan — Void / Koreksi Invoice (kesalahan input kasir)

## Masalah

Setelah "Complete Sale", kadang kasir sadar ada salah input (salah produk, qty,
metode bayar, dsb). Bagaimana mengoreksinya?

## Prinsip (rekomendasi)

- **Invoice bersifat immutable** — jangan diedit di tempat. Mengubah angka pada
  invoice yang sudah tercatat menghancurkan jejak audit & rekonsiliasi shift.
- **Koreksi = Void (Batalkan) + terbitkan ulang.** Invoice salah ditandai
  `void` (tetap tersimpan, dengan alasan), lalu kasir input ulang transaksi yang
  benar sebagai invoice baru.
- **Void ≠ Return.** Return = barang dikembalikan pelanggan (transaksi sah lalu
  dibatalkan). Void = pembatalan karena kesalahan pencatatan. Keduanya
  mengembalikan stok & keluar dari omzet, tapi dibedakan status + alasannya agar
  laporan jujur.

## Kontrol / kebijakan

- Kasir boleh **void penjualannya sendiri hanya selama shift masih terbuka**
  (belum tutup kas). Setelah shift ditutup / ganti hari → **butuh admin**
  (karena mengubah shift yang sudah direkonsiliasi).
- **Alasan wajib** diisi saat void.
- Void otomatis: (a) mengembalikan stok, (b) keluar dari omzet & `expected_cash`
  shift (karena status ≠ `completed`) — konsisten dengan mekanisme Return yang
  sudah ada.

## V.0 — Data model

- **V.0.1** Migrasi `sales`: tambah `voided_at` (naive_datetime), `void_reason`
  (string), `voided_by_id` (FK users, nullable). (Status memakai kolom `status`
  yang sudah ada, nilai baru `"void"`.)
- **V.0.2** `Sale`: `void_changeset/2` (set status `void`, `voided_at`, reason,
  voided_by). Helper `voided?/1`.

## V.1 — Context (Sales)

- **V.1.1** `Sales.void_sale/3(sale, user, reason)` — `Ecto.Multi`: kembalikan
  stok tiap item + set changeset void. Pakai ulang helper restore-stock dari
  `return_sale/1` (satu private function `restore_stock_multi/2`).
- **V.1.2** Guard: hanya sale berstatus `completed` yang bisa di-void; jika
  `sale.shift` sudah `closed` dan user bukan admin → `{:error, :shift_closed}`.

## V.2 — UI

- **V.2.1** Kasir: di modal struk setelah Complete Sale, tambah tombol
  **"Batalkan (koreksi)"** → modal alasan → `void_sale`. Setelah sukses, tawarkan
  **"Input ulang"** (buka cart kosong untuk mengetik transaksi yang benar).
- **V.2.2** `/sales`: aksi **Void** untuk sale `completed` (kasir: miliknya +
  shift terbuka; admin: semua), dengan konfirmasi + alasan. Badge status
  `void` (abu) berbeda dari `returned`.

## V.3 — Laporan & konsistensi

- **V.3.1** Pastikan semua agregasi memakai `status == "completed"` sehingga
  `void` otomatis dikecualikan (sales report, shift summary, settlement
  konsinyasi). Audit ringkas: `void` tetap tampil di daftar & detail shift.
- **V.3.2** Detail shift / daftar sales menampilkan alasan void (tooltip/kolom).

## V.4 — Tests + migrate + compile + verify

- `void_sale` mengembalikan stok & set status `void` + alasan + voided_by.
- Tidak bisa void sale non-`completed`; non-admin tidak bisa void sale di shift
  tertutup.
- Void keluar dari `expected_cash`, omzet, dan settlement konsinyasi.
- `mix compile` bersih, `mix ecto.migrate`, `mix test` hijau, boot verify.

## Di luar cakupan (sengaja)

- **Edit invoice per baris** (ubah qty/harga di tempat) — ditolak demi
  integritas audit; koreksi lewat void + re-issue.
- Void parsial (batalkan sebagian item) — jika benar-benar perlu, jadikan sprint
  lanjutan; MVP membatalkan seluruh invoice lalu terbitkan ulang.
- Cetak nota kredit/void formal untuk pajak.
