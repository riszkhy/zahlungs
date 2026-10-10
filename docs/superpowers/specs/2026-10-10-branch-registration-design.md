# Desain — Registrasi toko cabang (wizard admin)

Tanggal: 2026-10-10 · Status: menunggu tinjauan

## Tujuan

Admin membuka cabang baru dalam **satu alur**: mengisi data toko, lalu (bila
mau) membuat akun kasir pertamanya, tanpa berpindah antara menu Stores dan
Users. Ada satu pintu masuk yang jelas di navbar.

Berhasil bila: setelah wizard selesai, cabang muncul di daftar toko dan di
pemilih toko; bila kasir diisi, kasir itu langsung bisa login dan terikat ke
cabang tersebut; dan tidak pernah ada hasil setengah jadi (toko tersimpan
tetapi kasir yang diisi gagal).

## Keputusan (dari diskusi)

| Hal | Keputusan |
| --- | --- |
| Siapa yang mendaftarkan | Admin, sekali jalan |
| Stok awal | Tidak di wizard; cabang mulai dari 0 dan diisi lewat form produk |
| Kasir pertama | Opsional; boleh dilewati |
| Bentuk | Halaman wizard tersendiri (bukan modal, bukan rantai dua layar) |

## Alur

```
Navbar "Daftar Cabang" / tombol di /admin/stores
  → /admin/stores/register
      Langkah 1 — Data toko   [Lanjut]
      Langkah 2 — Kasir pertama (opsional)   [Kembali] [Lewati] [Daftarkan cabang]
  → /admin/stores  (pesan: cabang terdaftar, stok masih 0)
```

### Langkah 1 — Data toko

Field sama dengan form toko yang ada: nama, kode, alamat, telepon, zona waktu
(WIB/WITA/WIT), latitude dan longitude (opsional, dengan tombol "pakai lokasi
saya sekarang"). "Lanjut" hanya berpindah ke langkah 2 bila datanya valid,
termasuk **kode belum dipakai toko lain**. Belum ada yang disimpan di langkah
ini.

### Langkah 2 — Kasir pertama (opsional)

Di atas: ringkasan data toko dari langkah 1. Field: nama, email, password.

- **Daftarkan cabang** — menyimpan toko dan kasir.
- **Lewati** — menyimpan toko saja; isi field kasir diabaikan.
- **Kembali** — ke langkah 1 dengan data toko yang tadi diisi masih ada; isi
  field kasir juga dipertahankan.

Role (`cashier`) dan toko kasir **tidak** berasal dari form: keduanya
ditetapkan oleh fungsi penyimpan. Akun langsung berstatus confirmed, seperti
akun yang dibuat lewat `/admin/users`.

### Sesudah tersimpan

Pindah ke `/admin/stores` dengan pesan: *"Cabang {nama} terdaftar. Stoknya
masih 0 — pilih cabang ini di menu atas, lalu isi stok lewat Products."* Toko
aktif admin tidak diubah otomatis.

## Komponen

### `Zahlungs.Stores.register_branch/2` (baru)

```elixir
register_branch(store_attrs, cashier_attrs \\ nil)
  :: {:ok, %{store: %Store{}, cashier: %User{} | nil}}
   | {:error, :store, %Ecto.Changeset{}}
   | {:error, :cashier, %Ecto.Changeset{}}
```

- Satu transaksi (`Ecto.Multi`): buat toko; bila `cashier_attrs` bukan `nil`,
  buat user dengan `role: "cashier"`, `store_id` = toko baru, dan
  `confirmed_at` terisi.
- Kasir gagal divalidasi (email sudah dipakai, password terlalu pendek, dsb.)
  → seluruh transaksi dibatalkan, toko tidak tersimpan.
- Menerima map berkunci string (dari form) maupun atom.
- Kunci `role` dan `store_id` di `cashier_attrs` diabaikan.

### `Zahlungs.Stores.Store.changeset/2` (ubah kecil)

Tambah `unsafe_validate_unique(:code, Repo)` supaya kode yang sudah dipakai
tertangkap di langkah 1, bukan baru saat disimpan. `unique_constraint(:code)`
tetap ada sebagai penjaga terakhir.

### `ZahlungsWeb.StoreLive.Register` (baru)

LiveView di live session admin. State: `step` (`:store` | `:cashier`),
`store_params`, `cashier_params`, dan form untuk masing-masing. Form adalah
bagian dari LiveView ini sendiri (bukan live component), supaya bisa diuji
lewat `ZahlungsWeb.LiveDriver`.

| Event | Akibat |
| --- | --- |
| `validate_store` | Validasi langsung saat mengetik |
| `next` | Valid → langkah 2; tidak valid → tetap di langkah 1 dengan error |
| `back` | Ke langkah 1, data dipertahankan |
| `validate_cashier` | Validasi langsung (nama, email, password) |
| `save` | `register_branch(store_params, cashier_params)` |
| `skip` | `register_branch(store_params, nil)` |

Hasil `save`/`skip`:

- `{:ok, _}` → pesan sukses, pindah ke `/admin/stores`.
- `{:error, :store, changeset}` → kembali ke langkah 1 dengan error (misalnya
  kode keburu dipakai orang lain di antara langkah 1 dan simpan).
- `{:error, :cashier, changeset}` → tetap di langkah 2 dengan error.

Validasi form kasir memakai `Accounts.change_user_registration/2` (nama,
email, password; tanpa toko, karena tokonya belum ada).

### Field toko dipakai bersama

Field form toko sekarang ada di modal `StoreLive.Index`. Field itu dipindah ke
satu function component, `ZahlungsWeb.StoreLive.FormFields.store_fields/1`,
yang dipakai modal "Ubah" dan langkah 1 wizard, supaya tidak ada dua salinan.

### Perubahan pada yang sudah ada

- `StoreLive.Index`: aksi `:new` dan rute `/admin/stores/new` **dihapus**;
  tombol "Toko baru" diganti "Daftar cabang" yang menuju wizard. "Ubah" tetap
  memakai modal.
- Router: `live "/admin/stores/register", StoreLive.Register, :new` di live
  session admin, dikelompokkan bersama rute toko yang lain.
- Navbar: link "Daftar Cabang" untuk admin, di sebelah "Stores".

## Penanganan kesalahan

| Situasi | Perilaku |
| --- | --- |
| Data toko tidak valid di langkah 1 | Tidak bisa lanjut; error per field |
| Kode toko keburu dipakai saat simpan | Kembali ke langkah 1 dengan error pada kode |
| Email kasir sudah terdaftar | Tetap di langkah 2; toko tidak tersimpan |
| Field kasir kosong lalu "Daftarkan cabang" | Error wajib isi di langkah 2 (pakai "Lewati" untuk tanpa kasir) |
| Bukan admin membuka rute | Sama seperti halaman admin lain: dialihkan |

## Pengujian

- **Context** (`Stores.register_branch/2`): toko saja; toko + kasir (role,
  toko, confirmed, bisa login); kasir tidak valid → toko tidak tersimpan; kode
  ganda → `{:error, :store, _}`; `role`/`store_id` dari attrs diabaikan.
- **Changeset toko**: kode yang sudah dipakai ditolak tanpa perlu menyentuh
  constraint database.
- **Wizard** (lewat `LiveDriver`): lanjut dengan data valid; tertahan dengan
  data tidak valid; kembali mempertahankan data; lewati → toko tanpa kasir;
  simpan → toko + kasir; email ganda → tetap di langkah 2 dan toko tidak ada;
  kode ganda saat simpan → kembali ke langkah 1.
- **Akses** (`get/2`): tamu → login; kasir → `/`; admin → 200.
- **Navbar dan daftar toko**: link "Daftar Cabang" ada untuk admin;
  `/admin/stores/new` tidak lagi ada.
- Test lama untuk aksi `:new` di `store_live_test.exs` dipindahkan menjadi test
  wizard.

Tombol "pakai lokasi saya sekarang" tetap tanpa test otomatis (proyek belum
punya test runner JavaScript).

## Di luar cakupan

- Stok awal (salin dari toko lain, isi manual, atau CSV).
- Lebih dari satu kasir, atau memindahkan kasir yang sudah ada.
- Pendaftaran mandiri oleh cabang dengan persetujuan admin.
- Mengganti toko aktif admin secara otomatis ke cabang baru.
