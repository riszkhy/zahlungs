# PRD — Aplikasi POS Sederhana (Zahlungs)

| | |
|---|---|
| **Nama Produk** | Zahlungs POS |
| **Versi Dokumen** | 1.0 |
| **Tanggal** | 27 Juni 2026 |
| **Status** | Draft |
| **Pemilik Produk** | Tim Zahlungs |

---

## 1. Ringkasan (Overview)

Zahlungs POS adalah aplikasi *Point of Sale* (kasir) sederhana berbasis web untuk
usaha kecil–menengah (UMKM): toko ritel, kedai, kafe, atau warung. Aplikasi ini
memungkinkan pemilik/kasir untuk mengelola katalog produk, melakukan transaksi
penjualan, dan memantau ringkasan operasional dari satu antarmuka yang ringkas.

Aplikasi dibangun di atas stack yang sudah ada pada repositori ini:
**Elixir + Phoenix (LiveView) + Ecto + MySQL**. Modul autentikasi
(registrasi, login, reset password, konfirmasi email) sudah tersedia melalui
scaffold `phx.gen.auth` dan akan dipakai ulang untuk fitur **Login**, **Logout**,
dan sebagian **Profile**.

---

## 2. Tujuan (Goals) & Metrik Keberhasilan

### Tujuan
- Menyediakan alur transaksi kasir yang cepat (≤ 5 langkah dari pilih produk hingga selesai bayar).
- Memberikan satu sumber data produk yang konsisten antara katalog dan kasir.
- Membatasi akses fitur sensitif (manajemen produk) hanya untuk pengguna berwenang.

### Metrik Keberhasilan
| Metrik | Target |
|---|---|
| Waktu menyelesaikan 1 transaksi | < 30 detik |
| Waktu muat halaman kasir | < 1 detik |
| Akurasi total transaksi (perhitungan) | 100% |
| Tingkat keberhasilan login | > 99% |

### Non-Goals (Di Luar Cakupan v1)
- Integrasi pembayaran online / payment gateway.
- Manajemen multi-cabang & multi-gudang.
- Laporan keuangan/akuntansi lengkap.
- Aplikasi mobile native (cukup web responsif).
- Pencetakan struk ke printer thermal (hanya tampilan/preview struk).

---

## 3. Target Pengguna (Personas)

| Persona | Deskripsi | Kebutuhan Utama |
|---|---|---|
| **Pemilik / Admin** | Mengelola toko dan data produk. | CRUD produk, lihat ringkasan penjualan, kelola profil. |
| **Kasir** | Melayani transaksi penjualan harian. | Cari produk cepat, hitung total, selesaikan pembayaran. |

> **Catatan peran (role):** v1 menggunakan dua peran sederhana — `admin` dan
> `cashier`. Fitur **Product Management** hanya dapat diakses `admin`.

---

## 4. Cakupan Fitur (Scope)

Tujuh fitur utama:

1. Login
2. Home (Dashboard)
3. Catalog Product
4. Cashier (Kasir)
5. Product Management
6. Profile
7. Logout

---

## 5. Rincian Fitur (Feature Requirements)

### 5.1 Login

**Deskripsi:** Pengguna masuk ke aplikasi menggunakan email dan password.

**User Story:**
> Sebagai pengguna terdaftar, saya ingin masuk dengan email & password agar dapat
> mengakses fitur sesuai peran saya.

**Functional Requirements:**
- FR-1.1 Form login berisi field **Email** dan **Password**.
- FR-1.2 Opsi **"Keep me logged in"** (remember me) hingga 60 hari.
- FR-1.3 Validasi kredensial; pesan error generik bila gagal (mencegah *user enumeration*).
- FR-1.4 Setelah berhasil, pengguna diarahkan ke **Home**.
- FR-1.5 Pengguna yang sudah login tidak dapat membuka halaman login lagi (auto-redirect).

**Acceptance Criteria:**
- ✅ Kredensial benar → masuk & diarahkan ke Home.
- ✅ Kredensial salah → tetap di halaman login dengan pesan "Email atau password salah".
- ✅ Session bertahan sesuai opsi remember me.

**Catatan teknis:** Sudah tersedia via `UserSessionController` + `UserAuth` (token-based session, remember-me cookie, hashing `pbkdf2_elixir`).

---

### 5.2 Home (Dashboard)

**Deskripsi:** Halaman utama setelah login berisi ringkasan singkat dan navigasi ke fitur lain.

**User Story:**
> Sebagai pengguna, saya ingin melihat ringkasan aktivitas dan pintasan ke fitur
> agar dapat langsung bekerja.

**Functional Requirements:**
- FR-2.1 Menampilkan sapaan pengguna (mis. "Halo, {email}").
- FR-2.2 Kartu ringkasan: total penjualan hari ini, jumlah transaksi hari ini, jumlah produk aktif, produk stok menipis.
- FR-2.3 Pintasan navigasi cepat ke: Cashier, Catalog, Product Management (admin), Profile.
- FR-2.4 Konten menyesuaikan peran (kartu/menu admin hanya tampil untuk admin).

**Acceptance Criteria:**
- ✅ Angka ringkasan dihitung dari transaksi & produk pada hari berjalan.
- ✅ Menu admin tidak muncul untuk kasir.

---

### 5.3 Catalog Product

**Deskripsi:** Daftar produk yang dapat dilihat (read-only) oleh semua pengguna,
dengan pencarian dan filter.

**User Story:**
> Sebagai pengguna, saya ingin menelusuri katalog produk beserta harga & stok agar
> mudah menemukan barang.

**Functional Requirements:**
- FR-3.1 Menampilkan daftar produk: nama, gambar/ikon, kategori, harga, stok, status (aktif/nonaktif).
- FR-3.2 Pencarian berdasarkan nama / SKU (real-time via LiveView).
- FR-3.3 Filter berdasarkan kategori dan ketersediaan stok.
- FR-3.4 Paginasi untuk daftar panjang.
- FR-3.5 Hanya menampilkan produk berstatus **aktif** (default).

**Acceptance Criteria:**
- ✅ Mengetik di kotak cari → daftar terfilter tanpa reload halaman.
- ✅ Produk nonaktif tidak tampil di katalog default.

---

### 5.4 Cashier (Kasir)

**Deskripsi:** Layar transaksi penjualan — inti dari aplikasi POS.

**User Story:**
> Sebagai kasir, saya ingin memilih produk, menyesuaikan jumlah, dan menyelesaikan
> pembayaran dengan cepat agar antrean pelanggan lancar.

**Functional Requirements:**
- FR-4.1 Cari & tambahkan produk ke **keranjang** (cart) via pencarian nama/SKU/scan barcode (input teks).
- FR-4.2 Ubah kuantitas item, hapus item dari keranjang.
- FR-4.3 Hitung otomatis: subtotal per item, **subtotal**, diskon (opsional), pajak (opsional, konfigurasi flat), **grand total**.
- FR-4.4 Input jumlah uang dibayar → hitung **kembalian**.
- FR-4.5 Tombol **Selesaikan Transaksi** → simpan transaksi & kurangi stok produk.
- FR-4.6 Tampilkan **preview struk** (nomor transaksi, item, total, kembalian, waktu, kasir).
- FR-4.7 Validasi stok: tidak boleh menjual melebihi stok tersedia.
- FR-4.8 Tombol **Transaksi Baru** untuk mengosongkan keranjang.

**Acceptance Criteria:**
- ✅ Menambah item memperbarui total secara real-time.
- ✅ Stok berkurang sesuai jumlah terjual setelah transaksi sukses.
- ✅ Tidak dapat menyelesaikan transaksi jika keranjang kosong atau uang bayar < total.
- ✅ Setiap transaksi tersimpan dengan nomor unik & dapat ditelusuri.

---

### 5.5 Product Management

**Deskripsi:** CRUD produk — **khusus admin**.

**User Story:**
> Sebagai admin, saya ingin menambah, mengubah, dan menghapus produk agar katalog
> selalu akurat.

**Functional Requirements:**
- FR-5.1 **Create:** tambah produk (nama, SKU, kategori, harga, stok awal, gambar opsional, deskripsi, status).
- FR-5.2 **Read:** daftar produk dengan pencarian, filter, sortir; lihat detail.
- FR-5.3 **Update:** ubah field produk termasuk penyesuaian stok.
- FR-5.4 **Delete:** hapus / nonaktifkan produk (disarankan *soft delete* via status nonaktif).
- FR-5.5 Validasi: nama & SKU wajib, SKU unik, harga ≥ 0, stok ≥ 0.
- FR-5.6 Akses ditolak untuk peran non-admin (redirect + pesan).

**Acceptance Criteria:**
- ✅ Admin dapat membuat produk dan langsung muncul di katalog/kasir.
- ✅ SKU duplikat ditolak dengan pesan validasi.
- ✅ Kasir yang mencoba mengakses halaman ini diarahkan keluar.

---

### 5.6 Profile

**Deskripsi:** Pengguna mengelola data akun pribadi.

**User Story:**
> Sebagai pengguna, saya ingin memperbarui email dan password saya agar akun tetap
> aman dan terkini.

**Functional Requirements:**
- FR-6.1 Lihat info akun (email, peran, tanggal bergabung).
- FR-6.2 Ubah email (memerlukan password saat ini + konfirmasi email baru).
- FR-6.3 Ubah password (password saat ini + password baru + konfirmasi).
- FR-6.4 Validasi password sesuai kebijakan (panjang minimum, dll.).

**Acceptance Criteria:**
- ✅ Perubahan email memerlukan verifikasi melalui tautan konfirmasi.
- ✅ Perubahan password memerlukan password lama yang valid.

**Catatan teknis:** Sebagian besar sudah tersedia via `UserSettingsController`
(ganti email + ganti password). Perlu penambahan tampilan info peran & tanggal bergabung.

---

### 5.7 Logout

**Deskripsi:** Mengakhiri sesi pengguna dengan aman.

**User Story:**
> Sebagai pengguna, saya ingin keluar dari aplikasi agar akun saya tidak disalahgunakan.

**Functional Requirements:**
- FR-7.1 Tombol **Logout** tersedia di navigasi/menu pengguna.
- FR-7.2 Menghapus session token & remember-me cookie.
- FR-7.3 Memutus koneksi LiveView aktif untuk sesi tersebut.
- FR-7.4 Mengarahkan ke halaman publik (login/landing) setelah logout.

**Acceptance Criteria:**
- ✅ Setelah logout, halaman terproteksi tidak dapat diakses tanpa login ulang.

**Catatan teknis:** Sudah tersedia via `UserAuth.log_out_user/1`.

---

## 6. Kebutuhan Non-Fungsional (Non-Functional Requirements)

| Kategori | Kebutuhan |
|---|---|
| **Performa** | Halaman kasir & katalog merespons < 1 detik untuk ≤ 1.000 produk. |
| **Keamanan** | Password di-hash (`pbkdf2`); proteksi CSRF; otorisasi berbasis peran; perlindungan terhadap *user enumeration*. |
| **Ketersediaan** | Aplikasi web responsif (desktop & tablet). |
| **Usability** | Alur kasir minim klik; pesan error jelas dalam Bahasa Indonesia. |
| **Auditabilitas** | Setiap transaksi mencatat kasir, waktu, dan item. |
| **Skalabilitas** | Skema data mendukung pertumbuhan produk & transaksi. |

---

## 7. Arsitektur & Stack Teknis

- **Bahasa/Framework:** Elixir, Phoenix (LiveView).
- **Database:** MySQL via `myxql` + Ecto.
- **Autentikasi:** scaffold `phx.gen.auth` (sudah ada).
- **Frontend:** HEEx + Tailwind CSS + esbuild.
- **Pola arsitektur:** Phoenix context — pisahkan domain (`Accounts`, `Catalog`, `Sales`) dari lapisan web.

### Context yang Diusulkan
| Context | Tanggung jawab |
|---|---|
| `Zahlungs.Accounts` | Pengguna, peran, autentikasi (sudah ada). |
| `Zahlungs.Catalog` | Produk, kategori. |
| `Zahlungs.Sales` | Transaksi, item transaksi, ringkasan penjualan. |

---

## 8. Model Data (High-Level)

```
users (sudah ada)
  - id, email, hashed_password, role (admin|cashier),
    confirmed_at, inserted_at, updated_at

categories
  - id, name, inserted_at, updated_at

products
  - id, sku (unik), name, description, image_url,
    price (decimal), stock (integer), active (boolean),
    category_id (FK), inserted_at, updated_at

sales (transaksi)
  - id, code (nomor unik), user_id (kasir, FK),
    subtotal, discount, tax, total,
    amount_paid, change_due, status,
    inserted_at, updated_at

sale_items
  - id, sale_id (FK), product_id (FK),
    quantity, unit_price, line_total
```

**Relasi utama:**
- `category` 1—N `products`
- `sale` 1—N `sale_items`
- `product` 1—N `sale_items`
- `user` (kasir) 1—N `sales`

---

## 9. Peta Rute (Routing) Usulan

| Rute | Method | Akses | Fitur |
|---|---|---|---|
| `/users/log_in` | GET/POST | Publik | Login |
| `/users/log_out` | DELETE | Terautentikasi | Logout |
| `/` atau `/home` | GET | Terautentikasi | Home/Dashboard |
| `/catalog` | GET | Terautentikasi | Catalog Product |
| `/cashier` | GET | Terautentikasi | Cashier |
| `/products` (CRUD) | GET/POST/PUT/DELETE | **Admin** | Product Management |
| `/users/settings` | GET/PUT | Terautentikasi | Profile |

---

## 10. Asumsi & Ketergantungan

- Modul autentikasi existing dipakai ulang (tidak membangun ulang login dari nol).
- Pajak & diskon bersifat sederhana (nilai flat/persentase global), bukan aturan kompleks.
- Pencetakan struk fisik di luar cakupan v1 (hanya preview di layar).
- Satu mata uang (default: IDR).

---

## 11. Rencana Rilis (Usulan Bertahap)

| Fase | Isi |
|---|---|
| **MVP (v1.0)** | Login, Logout, Profile, Product Management (CRUD), Catalog, Cashier dasar, Home. |
| **v1.1** | Diskon/pajak konfigurasi, riwayat transaksi, struk preview yang lebih lengkap. |
| **v1.2** | Laporan penjualan, ekspor data, notifikasi stok menipis. |

---

## 12. Pertanyaan Terbuka (Open Questions)

1. Apakah perlu dukungan multi-mata uang ke depan?
2. Bagaimana kebijakan stok negatif (boleh oversell atau dikunci)?
3. Apakah diskon diterapkan per item atau per transaksi?
4. Apakah perlu modul retur/refund pada versi mendatang?
