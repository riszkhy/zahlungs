# Sprint Plan — Implementasi Zahlungs POS

| | |
|---|---|
| **Produk** | Zahlungs POS |
| **Referensi** | [`docs/PRD-POS.md`](./PRD-POS.md) |
| **Tanggal** | 27 Juni 2026 |
| **Stack** | Elixir + Phoenix 1.8 (LiveView) + Ecto + MariaDB (`myxql`) |
| **Durasi sprint** | 1 minggu / sprint (asumsi 1 developer) |

---

## Kondisi Awal (Baseline — sudah selesai)

✅ Migrasi ke Phoenix 1.8 (core components, verified routes, layouts).
✅ Database MariaDB tersambung via env; tabel `users` & `users_tokens` ter-migrasi.
✅ Autentikasi (`Accounts`): register, login, logout, reset password, konfirmasi email, ubah email/password.

> Karena auth sudah ada, fitur **Login (5.1)**, **Logout (5.7)**, dan sebagian **Profile (5.6)** tinggal disesuaikan, bukan dibangun dari nol.

---

## Peta Sprint (Ringkasan)

| Sprint | Tema | Fitur PRD | Hasil utama |
|---|---|---|---|
| **0** | Fondasi & Role | — | Field `role`, otorisasi admin/cashier, layout menu POS |
| **1** | Product Management | 5.5 | Context `Catalog`, CRUD produk + kategori (admin) |
| **2** | Catalog & Home | 5.3, 5.2 | Katalog read-only + pencarian, dashboard ringkasan |
| **3** | Cashier | 5.4 | Context `Sales`, keranjang, transaksi, potong stok, struk |
| **4** | Profile, Polish & Test | 5.6 | Profil + role, riwayat transaksi, test, perapihan |

Dependensi: **0 → 1 → 2 → 3**. Sprint 4 menyusul setelah 3 (sebagian bisa paralel).

---

## Sprint 0 — Fondasi & Role (1 minggu)

**Tujuan:** Menyiapkan peran pengguna dan kerangka navigasi POS sebelum fitur bisnis dibangun.

### Tasks
- [ ] **0.1** Migrasi: tambah kolom `role` di `users` (`string`, default `"cashier"`, not null).
- [ ] **0.2** `Accounts.User`: tambah `role` ke schema + `registration_changeset` (cast, validasi `inclusion ["admin","cashier"]`).
- [ ] **0.3** `Accounts`: helper `admin?/1`, dan fungsi seed/promote admin (mis. `set_user_role/2`).
- [ ] **0.4** Plug otorisasi `require_admin_user` di `UserAuth` (redirect + flash bila bukan admin).
- [ ] **0.5** Seed (`priv/repo/seeds.exs`): buat 1 user admin & 1 user cashier default.
- [ ] **0.6** Update layout `root`: menu navigasi POS (Home, Cashier, Catalog, Products[admin], Profile, Logout) sesuai role.
- [ ] **0.7** Tambah scope router `:require_authenticated_user` & scope baru `:require_admin_user`.

### Acceptance Criteria
- User baru default `cashier`; admin dibuat via seed.
- Mengakses rute admin sebagai cashier → diarahkan keluar + pesan.
- Menu admin hanya tampil untuk admin.

### Deliverables
Migrasi role, plug `require_admin_user`, seeds, menu navigasi berbasis role.

---

## Sprint 1 — Product Management (1 minggu) — PRD 5.5

**Tujuan:** Admin dapat mengelola katalog produk & kategori (CRUD).

### Tasks
- [ ] **1.1** Context `Zahlungs.Catalog`.
- [ ] **1.2** Schema + migrasi `Category` (`name`, timestamps; `name` unik).
- [ ] **1.3** Schema + migrasi `Product` (`sku` unik, `name`, `description`, `price` decimal, `stock` integer, `active` boolean, `category_id` FK, `image_url`).
- [ ] **1.4** Changeset & validasi: `sku`/`name` wajib, `sku` unik, `price ≥ 0`, `stock ≥ 0`.
- [ ] **1.5** API context: `list_products/1` (filter/search), `get_product!/1`, `create_product/1`, `update_product/2`, `delete_product/1` (soft delete via `active=false`), CRUD kategori.
- [ ] **1.6** LiveView admin produk (`/products`): index (tabel + search + filter), form modal new/edit, hapus/nonaktif.
- [ ] **1.7** LiveView kategori (`/categories`) atau kelola inline.
- [ ] **1.8** Test context `Catalog` + test LiveView dasar.

### Acceptance Criteria
- Admin membuat produk → muncul di daftar.
- SKU duplikat ditolak dengan pesan validasi.
- Cashier tidak bisa membuka `/products`.

### Deliverables
Context `Catalog`, tabel `categories` & `products`, LiveView manajemen produk admin.

---

## Sprint 2 — Catalog & Home (1 minggu) — PRD 5.3 & 5.2

**Tujuan:** Semua pengguna dapat menelusuri produk; dashboard ringkasan tersedia.

### Tasks
- [ ] **2.1** LiveView Catalog (`/catalog`): daftar produk aktif (read-only), kartu/tabel.
- [ ] **2.2** Pencarian real-time (nama/SKU) via `phx-change` (debounce).
- [ ] **2.3** Filter kategori + ketersediaan stok; paginasi.
- [ ] **2.4** LiveView Home (`/home` atau `/`): sapaan + kartu ringkasan.
- [ ] **2.5** Query ringkasan (sementara dummy bila Sales belum ada): jumlah produk aktif, stok menipis (`stock < threshold`).
- [ ] **2.6** Pintasan navigasi cepat di Home (sesuai role).
- [ ] **2.7** Test Catalog (search/filter) + Home.

### Acceptance Criteria
- Ketik di kotak cari → daftar terfilter tanpa reload.
- Produk nonaktif tidak tampil di katalog default.
- Kartu admin tidak tampil untuk cashier.

> Catatan: kartu "penjualan hari ini" diselesaikan penuh setelah Sprint 3 (butuh data `Sales`).

### Deliverables
LiveView Catalog dengan search/filter/paginasi, LiveView Home dashboard.

---

## Sprint 3 — Cashier (1 minggu) — PRD 5.4 ⭐ Inti

**Tujuan:** Kasir dapat menyelesaikan transaksi penjualan end-to-end.

### Tasks
- [ ] **3.1** Context `Zahlungs.Sales`.
- [ ] **3.2** Schema + migrasi `Sale` (`code` unik, `user_id` FK, `subtotal`, `discount`, `tax`, `total`, `amount_paid`, `change_due`, `status`).
- [ ] **3.3** Schema + migrasi `SaleItem` (`sale_id` FK, `product_id` FK, `quantity`, `unit_price`, `line_total`).
- [ ] **3.4** LiveView Cashier (`/cashier`): cari & tambah produk ke keranjang (state di socket assigns).
- [ ] **3.5** Ubah qty, hapus item; hitung subtotal/diskon/pajak/total real-time.
- [ ] **3.6** Input uang dibayar → hitung kembalian; validasi `amount_paid ≥ total`.
- [ ] **3.7** `Sales.create_sale/2`: **Ecto.Multi** transaksional — simpan sale + items + **potong stok** produk (atomik).
- [ ] **3.8** Validasi stok (tak boleh oversell) sebelum commit.
- [ ] **3.9** Preview struk (nomor, item, total, kembalian, waktu, kasir) + tombol "Transaksi Baru".
- [ ] **3.10** Test `Sales` (termasuk kasus stok kurang & rollback Multi).

### Acceptance Criteria
- Menambah item memperbarui total real-time.
- Transaksi sukses → stok berkurang sesuai jumlah terjual.
- Keranjang kosong / uang < total → tidak bisa menyelesaikan.
- Setiap transaksi punya nomor unik & tersimpan.

### Deliverables
Context `Sales`, tabel `sales` & `sale_items`, LiveView kasir transaksional + struk.

---

## Sprint 4 — Profile, Polish & Test (1 minggu) — PRD 5.6

**Tujuan:** Lengkapi profil, riwayat transaksi, dan kualitas.

### Tasks
- [ ] **4.1** Halaman Profile: tampilkan role + tanggal bergabung (lengkapi `UserSettings`).
- [ ] **4.2** Riwayat transaksi (`/sales`): daftar + detail (filter tanggal).
- [ ] **4.3** Lengkapi kartu Home dengan data `Sales` (penjualan & jumlah transaksi hari ini).
- [ ] **4.4** Indikator stok menipis (badge/notifikasi).
- [ ] **4.5** Setup `config/test.exs` ke DB test terpisah; perbaiki test scaffold yang terdampak migrasi 1.8.
- [ ] **4.6** Perapihan UI (Tailwind), pesan error Bahasa Indonesia, seed contoh produk.

### Acceptance Criteria
- Profil menampilkan peran & info akun.
- Home menampilkan angka penjualan hari berjalan yang akurat.
- Test suite hijau di DB test.

### Deliverables
Profil lengkap, riwayat transaksi, dashboard final, test suite.

---

## Skema Data Target (akhir Sprint 3)

```
users (ada)        + role
categories         id, name
products           id, sku*, name, description, image_url, price, stock, active, category_id→categories
sales              id, code*, user_id→users, subtotal, discount, tax, total, amount_paid, change_due, status
sale_items         id, sale_id→sales, product_id→products, quantity, unit_price, line_total
```
`*` = unik.

---

## Definition of Done (per fitur)

- Migrasi & schema + changeset dengan validasi.
- Fungsi context (bukan akses schema langsung dari web layer).
- LiveView/route + otorisasi role sesuai PRD.
- Test context (minimal happy path + 1 edge case).
- `mix compile` bersih (tanpa warning) & `mix format`.

---

## Risiko & Catatan

| Risiko | Mitigasi |
|---|---|
| Transaksi kasir & potong stok harus atomik | Pakai `Ecto.Multi`; uji rollback saat stok kurang. |
| DB MariaDB remote dipakai bersama | Sprint 4: arahkan test ke DB test khusus; hindari drop DB produksi. |
| Konsistensi stok saat akses bersamaan | Pertimbangkan locking/`select ... for update` bila perlu (post-MVP). |
| `decimal` untuk harga | Gunakan tipe `:decimal` Ecto, hindari float. |

---

## Urutan Eksekusi yang Disarankan

**Sprint 0 → 1 → 2 → 3 → 4.** Mulai dari Sprint 0 (role & fondasi) karena semua fitur lain bergantung pada otorisasi role.
