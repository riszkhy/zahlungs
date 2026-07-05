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
| `FORCE_SSL`            |       | `true` / `1` (default off)                | Redirect HTTP→HTTPS + HSTS; **hanya** jika di belakang reverse proxy TLS (trust `x-forwarded-proto`) |
| `DATABASE_SSL`         |       | `true` / `1` (default off)                | TLS ke database (managed MariaDB)                       |
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
*secure context* — di production artinya **wajib HTTPS** (di dev dipakai
sertifikat self-signed di port 4001). Tanpa HTTPS, kamera tidak akan menyala di
browser HP; scanner fisik (keyboard wedge) tetap jalan.

Contoh Caddy (otomatis Let's Encrypt):

```
pos.tokosaya.id {
    reverse_proxy localhost:4000
}
```

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
- [ ] Mailer: default Swoosh `Local` tidak mengirim email sungguhan. Reset
      password via email TIDAK berfungsi sampai adapter prod dikonfigurasi
      (lihat komentar di `config/runtime.exs`); sementara itu admin bisa reset
      password user dari `/admin/users`.

## 6. Rollback

```bash
bin/zahlungs eval "Release.rollback(Zahlungs.Repo, 20260701170000)"
```

Versi = timestamp file di `priv/repo/migrations/`. Rollback aplikasi = deploy
ulang image/release sebelumnya (DB rollback hanya bila migrasi terbaru memang
harus dibatalkan).
