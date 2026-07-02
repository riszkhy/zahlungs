# Sprint Plan — Modul Konsinyasi (Model A: harga supplier tetap)

## Ringkasan model

**Konsinyasi (titip jual masuk):** supplier menitipkan barang ke toko. Toko hanya
membayar supplier untuk barang yang **laku**; sisa stok bisa dikembalikan.

**Model A — harga supplier tetap:** setiap barang titipan punya *harga titip*
(harga yang dibayar ke supplier). Margin toko = `harga jual − harga titip`.

Field `purchase_price` yang **sudah ada** di `products` dan di-*snapshot* ke
`sale_items` saat terjual dipakai sebagai **harga titip**. Jadi:

> **Utang ke supplier = Σ (purchase_price × qty)** dari `sale_items` konsinyasi yang terjual (status `completed`).
> **Margin toko = Σ (line_total) − utang ke supplier.**

**Sisi kasir: tidak ada perubahan.** Barang titipan dijual lewat modul Cashier
seperti produk biasa. Aspek konsinyasi murni urusan back-office (master supplier
+ penandaan produk + laporan settlement).

---

## K.0 — Data model

- **K.0.1** Migrasi: buat tabel `suppliers` — `name` (not null), `phone`, `note`,
  `deleted_at` (soft delete), timestamps.
- **K.0.2** Migrasi: tambah ke `products` — `consignment` (boolean, default false,
  not null) + `supplier_id` (FK `suppliers`, nullable, `on_delete: :nilify_all`).
- **K.0.3** Schema `Zahlungs.Catalog.Supplier` + `changeset` (validasi `name`).
- **K.0.4** `Product` schema: cast `:consignment`, `:supplier_id`; **validasi:
  jika `consignment == true` maka `supplier_id` wajib**. `belongs_to :supplier`.

## K.1 — Manajemen Supplier (admin)

- **K.1.1** Context `Catalog` (atau modul `Suppliers` baru): `list_suppliers/0`,
  `get_supplier!/1`, `create_supplier/1`, `update_supplier/2`,
  `delete_supplier/1` (soft delete), semua query kecualikan yang terhapus.
- **K.1.2** `SupplierLive.Index` + `FormComponent` (list + modal create/edit),
  route di scope admin (`/admin/suppliers*`), link nav "Suppliers" (admin only).

## K.2 — Integrasi form produk

- **K.2.1** Form produk: checkbox **"Konsinyasi (titip jual)"** + select
  **Supplier** (muncul saat checkbox aktif). Saat konsinyasi, beri label kolom
  `purchase_price` sebagai **"Harga titip (bayar ke supplier)"**.
- **K.2.2** `Catalog.list_products/get_product`: preload `:supplier`; opsi filter
  `consignment: true` untuk dipakai laporan.

## K.3 — Laporan Settlement Konsinyasi

- **K.3.1** Context: `consignment_settlement(date_from, date_to)` →
  per-supplier `%{supplier, qty_sold, revenue, payable, margin}` (hanya sale
  `completed`, exclude `returned`). Plus `consignment_stock_on_hand/0` →
  per-supplier sisa stok titipan (yang bisa dikembalikan).
- **K.3.2** `ReportLive.Consignment` (`/reports/consignment`): filter tanggal,
  tabel per-supplier (terjual, omzet, **yang harus dibayar**, margin toko),
  ringkasan total, dan daftar sisa stok titipan. Route admin + link nav.

## K.4 — Tests + migrate + verify

- Supplier CRUD + soft delete.
- Produk konsinyasi: `supplier_id` wajib saat `consignment == true`.
- Settlement math: penjualan tunai/non-tunai konsinyasi masuk hitungan; sale
  `returned` **tidak** dihitung; `payable = Σ purchase_price×qty`,
  `margin = revenue − payable`.
- Laporan render; kasir tetap bisa jual barang titipan tanpa langkah tambahan.
- `mix compile` bersih, `mix ecto.migrate`, `mix test` hijau, boot verify.

---

## Di luar cakupan (sengaja)

- Alur pembelian/utang penuh (PO, hutang) — inti konsinyasi justru "bayar hanya
  yang laku", cukup dari laporan settlement.
- Komisi persen (Model B) — perlu field `commission_percent`; tidak dipakai di
  Model A.
- Pencatatan pengembalian fisik barang titipan ke supplier (retur ke consignor)
  — bisa jadi sprint lanjutan; sementara "sisa stok" di laporan sudah menandai
  yang bisa dikembalikan.
