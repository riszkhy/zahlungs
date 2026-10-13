# SaaS — banyak pemilik dalam satu instalasi

Status: diimplementasikan di branch `feat/saas-multi-owner`.

## Keputusan

| Hal | Keputusan |
| --- | --- |
| Pendaftaran | Terbuka untuk umum; baru aktif setelah disetujui super admin |
| Penagihan | Manual: super admin mencatat "dibayar sampai" + catatan |
| Email | Satu email = satu akun, lintas semua pemilik |
| Alamat | Satu domain untuk semua pemilik |
| Isolasi data | Satu database; tiap baris milik pemilik membawa `organization_id` |

## Model

- **Organisasi** (`organizations`) = pemilik / tenant. Status: `pending` →
  `active` atau `rejected`; `active` ↔ `suspended`; `rejected` bisa disetujui
  belakangan.
- **Milik organisasi** (kolom `organization_id`): `stores`, `users`,
  `categories`, `suppliers`, `products`, `user_logins`.
- **Mengikuti toko** (tanpa kolom sendiri): stok, shift, gerakan kas,
  penjualan. Toko selalu milik satu organisasi, jadi data ini ikut terisolasi.
- **Unik per organisasi:** SKU, barcode, nama kategori, kode toko. Kode invoice
  unik per toko. Email tetap unik se-aplikasi.

## Peran

| Role | Milik | Bisa apa |
| --- | --- | --- |
| `superadmin` | tidak ada organisasi | Hanya `/platform`: meninjau organisasi, mencatat tagihan |
| `admin` | satu organisasi | Semua toko organisasinya (pendaftar pertama = pemilik) |
| `cashier` | satu toko | Berjualan di tokonya |

## Penjaga isolasi

`Zahlungs.Repo` menolak atau menyaring otomatis:

- Query yang tabel utamanya milik organisasi **selalu** disaring ke organisasi
  aktif proses itu (`Repo.put_org_id/1`, dipasang saat `Zahlungs.Scope` dibentuk
  untuk user).
- Tanpa organisasi aktif, query itu **gagal** (bukan mengembalikan semua data).
- Query yang memang lintas organisasi (cari user by email saat login, halaman
  platform, pembersihan log) menyebutkannya dengan `skip_org_id: true`.
- Hanya tabel utama query yang diperiksa. Tabel hasil join/subquery dan data
  per toko tidak disaring di sini; "Semua toko" untuk admin disaring eksplisit
  ke toko-toko organisasinya (`Stores.store_ids/0`).

## Alur

```
/signup  → organisasi (pending) + "Toko Utama" (kode TU) + akun pemilik (admin)
         → /signup/pending          (tidak otomatis login)
login pemilik saat pending/rejected/suspended → ditolak dengan pesan yang sesuai
/platform/organizations (superadmin)
         → Setujui / Tolak / Tangguhkan / Aktifkan lagi, + catatan
         → "Dibayar sampai" + catatan tagihan
penangguhan → sesi yang sedang terbuka berakhir pada request berikutnya
```

## Menjalankan

- Super admin dibuat lewat seeds: di production set
  `SEED_PLATFORM_ADMIN_EMAIL` dan `SEED_PLATFORM_ADMIN_PASSWORD` lalu `bin/seed`;
  di dev akunnya `platform@zahlungs.test`.
- Migrasi `20261013090000`–`20261013090001` membuat organisasi bawaan
  **"Organisasi Utama"** (aktif) dan memindahkan semua data lama ke sana.

## Belum ada (sengaja atau terhalang)

- **Verifikasi email pendaftar** dan reset password lewat email: mailer belum
  bisa mengirim (dependency SMTP belum terpasang). Persetujuan super admin
  menjadi satu-satunya saringan; pemilik yang lupa password belum bisa
  memulihkannya sendiri.
- **Penagihan otomatis**: tidak ada gateway, tidak ada batas paket, dan lewat
  "dibayar sampai" tidak menangguhkan otomatis (hanya diberi tanda di halaman
  platform).
- **Role pemilik terpisah dari admin**, dan pemindahan kepemilikan.
- **Super admin** tidak punya halaman profil (ganti password lewat konsol).
- **Ekspor / penghapusan data per organisasi**, CI, database test terpisah,
  backup dan pemantauan: masih pekerjaan operasional.
- Pembatas pendaftaran dan login disimpan di memori satu server.
