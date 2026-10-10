# Deployment — Zahlungs POS

Panduan menyiapkan dan menjalankan aplikasi di production. Aplikasi dirilis
sebagai **OTP release** (bukan `mix phx.server`), dengan konfigurasi runtime
sepenuhnya lewat **environment variables** (`config/runtime.exs`).

## 1. Environment variables

| Variable               | Wajib | Contoh / default                          | Keterangan                                              |
| ---------------------- | :---: | ----------------------------------------- | ------------------------------------------------------- |
| `DATABASE_URL`         |  ✅   | `ecto://user:pass@host:3306/zahlungs`     | Koneksi MySQL/MariaDB (adapter `myxql`)                 |
| `SECRET_KEY_BASE`      |  ✅   | hasil `mix phx.gen.secret`                | Kunci tanda tangan cookie/sesi — **jangan** di-commit   |
| `PHX_HOST`             |  ⚠️   | `pos.tokosaya.id` (default `localhost`)   | Host publik untuk URL yang digenerate (email, redirect) |
| `PORT`                 |       | `4000`                                    | Port HTTP yang di-bind                                  |
| `POOL_SIZE`            |       | `10`                                      | Ukuran pool koneksi DB                                  |
| `UTC_OFFSET_HOURS`     |       | `7` (WIB; `8` WITA, `9` WIT)              | Zona waktu toko: menentukan awal "hari ini" di laporan dan jam yang ditampilkan |
| `MAIL_FROM`            |       | `kasir@tokosaya.id`                       | Alamat pengirim email akun (hanya berguna bila mailer sudah dikonfigurasi) |
| `FORCE_SSL`            |       | `true` / `1` (default off)                | Redirect HTTP→HTTPS + HSTS; **hanya** jika di belakang reverse proxy TLS (trust `x-forwarded-proto`) |
| `DATABASE_SSL`         |       | `true` / `1` (default off)                | TLS ke database (managed MariaDB)                       |
| `HTTPS_PORT`           |       | `4001`                                    | Aktifkan listener HTTPS di app sendiri (LAN tanpa proxy) — perlu cert + key |
| `SSL_CERT_PATH`        |       | `/app/priv/cert/selfsigned.pem`           | Path absolut sertifikat (wajib bila `HTTPS_PORT` diset) |
| `SSL_KEY_PATH`         |       | `/app/priv/cert/selfsigned_key.pem`       | Path absolut private key                                |
| `SEED_ADMIN_EMAIL`     |       | `owner@tokosaya.id`                       | Dipakai `Release.seed` — tanpa ini admin TIDAK dibuat   |
| `SEED_ADMIN_PASSWORD`  |       | (min 12 karakter)                         | Password admin awal                                     |
| `SEED_ADMIN_NAME`      |       | `Administrator`                           | Nama tampilan admin                                     |
| `SEED_CASHIER_EMAIL`   |       | —                                         | Opsional: kasir awal                                    |
| `SEED_CASHIER_PASSWORD`|       | —                                         | Opsional                                                |
| `SEED_CASHIER_NAME`    |       | `Kasir`                                   | Opsional                                                |

Catatan seeds: di **prod**, seeds hanya membuat akun bila env `SEED_*` diisi,
dan **tidak pernah** memasukkan katalog contoh. Password lemah dev
(`adminpassword123`) hanya berlaku di dev/test.

## 2. Opsi A — Docker (disarankan)

```bash
# Build image (multi-stage; hasil akhir Debian slim + release, non-root)
docker build -t zahlungs .

# Jalankan (migrasi jalan otomatis sebelum server start)
docker run -d --name zahlungs -p 4000:4000 \
  -e DATABASE_URL="ecto://user:pass@dbhost:3306/zahlungs" \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e PHX_HOST="pos.tokosaya.id" \
  -e FORCE_SSL=true \
  zahlungs

# Seed admin pertama (sekali saja)
docker exec \
  -e SEED_ADMIN_EMAIL=owner@tokosaya.id \
  -e SEED_ADMIN_PASSWORD='GantiDenganYangKuat!' \
  zahlungs /app/bin/seed
```

Perintah di dalam kontainer: `/app/bin/server` (start), `/app/bin/migrate`,
`/app/bin/seed`. Untuk pemisahan ketat, jalankan `bin/migrate` sebagai langkah
deploy terpisah dan ganti `CMD` menjadi `bin/server` saja.

## 3. Opsi B — Release langsung di server (Linux)

```bash
export MIX_ENV=prod DATABASE_URL=... SECRET_KEY_BASE=... PHX_HOST=...

./build.sh                      # deps → compile → assets.deploy → release → migrate
_build/prod/rel/zahlungs/bin/zahlungs daemon    # atau: bin/server (foreground)

# Utilitas
_build/prod/rel/zahlungs/bin/zahlungs eval "Release.migrate"
_build/prod/rel/zahlungs/bin/zahlungs eval "Release.seed"
_build/prod/rel/zahlungs/bin/zahlungs eval "Release.rollback(Zahlungs.Repo, VERSI)"
_build/prod/rel/zahlungs/bin/zahlungs remote   # IEx ke node berjalan
```

Prasyarat build: Elixir 1.18 / OTP 27, Node.js + `npm install --prefix assets`
(untuk alpinejs/daisyui/topbar yang dibundel esbuild/tailwind).

## 4. Reverse proxy & HTTPS

Terminasi TLS di reverse proxy (nginx/caddy/traefik), teruskan ke `PORT`
aplikasi. Set `FORCE_SSL=true` agar HTTP diredirect dan HSTS aktif — aplikasi
mempercayai header `x-forwarded-proto` dari proxy.

**Penting untuk POS ini:** fitur **scan barcode via kamera HP** membutuhkan
*secure context* — browser hanya mengizinkan `getUserMedia`/`BarcodeDetector`
lewat **HTTPS** (atau `localhost`). Lewat HTTP biasa ke IP LAN, kamera **tidak
akan menyala** (scanner fisik/keyboard-wedge tetap jalan). Jadi di production
kamera hanya berfungsi jika app diakses via HTTPS. Ada dua cara:

**Cara 1 — Reverse proxy TLS (deploy internet, domain publik).**
Terminasi TLS di proxy, set `FORCE_SSL=true`. Contoh Caddy (auto Let's Encrypt):

```
pos.tokosaya.id {
    reverse_proxy localhost:4000
}
```

**Cara 2 — HTTPS langsung dari app (LAN, tanpa proxy — kasus umum warung).**
Release bisa menyajikan HTTPS sendiri. Buat sertifikat self-signed lalu set env
`HTTPS_PORT` + `SSL_CERT_PATH` + `SSL_KEY_PATH`:

```bash
# hasilkan priv/cert/selfsigned.pem & selfsigned_key.pem
mix phx.gen.cert

docker run -d --name zahlungs -p 4000:4000 -p 4001:4001 \
  -e DATABASE_URL=... -e SECRET_KEY_BASE=... -e PHX_HOST=192.168.1.10 \
  -e HTTPS_PORT=4001 \
  -e SSL_CERT_PATH=/certs/selfsigned.pem \
  -e SSL_KEY_PATH=/certs/selfsigned_key.pem \
  -v /path/to/certs:/certs:ro \
  zahlungs
```

Buka `https://<IP-LAN>:4001` di HP → terima peringatan sertifikat self-signed
sekali → kamera aktif. Jangan set `FORCE_SSL` untuk mode ini (itu untuk proxy).

## 5. Checklist go-live

- [ ] `SECRET_KEY_BASE` baru dari `mix phx.gen.secret` (jangan pakai milik dev)
- [ ] `DATABASE_URL` menunjuk DB production (bukan DB dev/test bersama!)
- [ ] `PHX_HOST` = domain sebenarnya; `FORCE_SSL=true` di belakang proxy TLS
- [ ] Migrasi jalan: `bin/migrate` (otomatis pada CMD Docker default)
- [ ] Admin pertama dibuat via `bin/seed` + env `SEED_ADMIN_*`, lalu **hapus env
      password** dari konfigurasi
- [ ] Login admin → buat akun kasir via `/admin/users` (bukan register publik)
- [ ] Smoke test: login kasir → buka shift → transaksi → tutup shift → cek
      laporan
- [ ] Backup DB terjadwal (mysqldump/managed backup) — data penjualan = uang
- [ ] Mailer: belum ada adapter email sungguhan, jadi di production tidak ada
      email yang terkirim (reset password, konfirmasi, ganti email). Aplikasi
      tahu soal ini: saat boot muncul warning di log dan link "Forgot password?"
      di halaman login diganti "Lupa password? Hubungi admin." Admin me-reset
      password dan mengonfirmasi user dari `/admin/users`. Ganti email lewat
      halaman Profile belum bisa diselesaikan tanpa mailer. Untuk mengaktifkan
      email: tambahkan dependency adapter (mis. `{:gen_smtp, "~> 1.2"}`) dan
      konfigurasi sesuai komentar "Mailer" di `config/runtime.exs`.

## 6. Multi-toko (server pusat online)

Satu instalasi melayani semua cabang lewat internet.

- **Migrasi ke multi-toko** (`20261011090000`–`20261011090003`) membuat tabel
  `stores`, toko bawaan **"Toko Utama"** (kode `TU`), dan memindahkan semua
  kasir, shift, penjualan, dan stok yang ada ke toko itu. Ambil backup dulu dan
  coba di salinan database: migrasi ini mengubah data nyata dan DDL MySQL tidak
  transaksional.
- Setelah migrasi: login admin → `/admin/stores` → lengkapi alamat/telepon Toko
  Utama (tampil di struk), buat cabang lain, lalu tempatkan kasir lewat kolom
  **Store** di `/admin/users`. Kasir tanpa toko aktif tidak bisa login.
- Stok cabang baru mulai dari 0 untuk semua produk: pilih cabang itu di navbar,
  lalu isi stok lewat form produk.
- Kolom lama `products.stock` sengaja belum dihapus (tidak dipakai lagi);
  dihapus pada rilis berikutnya.
- **Wajib HTTPS** (`FORCE_SSL=true` di belakang reverse proxy). Selain keamanan,
  browser hanya memberi lokasi dan kamera barcode di halaman HTTPS.
- **Zona waktu per toko** diatur di form toko (WIB/WITA/WIT). `UTC_OFFSET_HOURS`
  hanya dipakai saat admin melihat "Semua toko".
- **Pembatas login:** 5 kali gagal untuk satu email dari satu alamat → ditahan
  15 menit (di memori, hilang saat restart). Di belakang proxy alamatnya adalah
  alamat proxy, jadi praktis berlaku per email.
- **Log lokasi login** disimpan 90 hari (`config :zahlungs,
  :login_log_retention_days`) dan dibersihkan otomatis tiap hari.
- **Internet toko putus = toko tidak bisa berjualan.** Siapkan prosedur manual
  (catat di kertas, input ulang setelah tersambung).
- `POOL_SIZE`: naikkan sesuai jumlah kasir yang aktif bersamaan di semua toko.

## 7. Rollback

```bash
bin/zahlungs eval "Release.rollback(Zahlungs.Repo, 20260701170000)"
```

Versi = timestamp file di `priv/repo/migrations/`. Rollback aplikasi = deploy
ulang image/release sebelumnya (DB rollback hanya bila migrasi terbaru memang
harus dibatalkan).
