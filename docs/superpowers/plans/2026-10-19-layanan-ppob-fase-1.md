# Layanan PPOB Fase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zahlungs mengecek tagihan PLN dan membayar layanan PPOB lewat API penyedia (adapter tiruan sampai vendor dipilih), dengan hasil dari jawaban langsung, callback, dan pengecek status, tanpa kehilangan jejak atau membayar dua kali.

**Architecture:** Behaviour `Zahlungs.Services.Provider` dengan adapter `Provider.Fake`. Akun deposit punya mode `manual` (alur Fase 0) atau `api`. Transaksi `api` dan `ref_id`-nya di-commit dulu, lalu `Services.Dispatcher` mengirimnya (proses latar di dev/prod, inline di test). Semua jawaban masuk lewat `Services.apply_result/2`, yang mengunci baris dan menyiarkan perubahan lewat PubSub.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MyXQL, `Plug.Crypto`, `:httpc` (OTP). Tanpa dependensi baru.

**Spec:** `docs/superpowers/specs/2026-10-19-layanan-ppob-fase-1-design.md` (di atas `docs/superpowers/specs/2026-10-16-layanan-ppob-fase-0-design.md`)

## Global Constraints

- Tidak ada dependensi baru (hex.pm tidak terjangkau).
- LiveView dan controller hanya memanggil fungsi konteks.
- Uang `Decimal`, kolom `decimal(15, 2)`; waktu bisnis lewat `Zahlungs.LocalTime`.
- Data per toko disaring dengan `Scope.store_id/1` / `Stores.store_ids/0`; toko tidak pernah dari parameter.
- Tabel milik pemilik memakai `organization_id` + `Organizations.put_organization/1`. `service_inquiries` milik toko (tanpa `organization_id`).
- Proses tanpa user (Dispatcher, StatusChecker, callback) menetapkan organisasi dari toko transaksi: `Repo.get!(Store, id, skip_org_id: true)` lalu `Repo.put_org_id(store.organization_id)`.
- **Error jaringan atau timeout saat `pay`/`status` = pending, bukan gagal.**
- Kredensial tidak pernah dikirim ke browser atau ditulis ke log.
- Alur akun `manual` tetap persis Fase 0; semua test Fase 0 tetap lulus.
- Teks UI berbahasa Indonesia; handler menerima id integer maupun string.
- Test lewat `ZahlungsWeb.LiveDriver` dan `get/2`/`post/3`; database dev dipakai bersama test (cari data dengan nilai unik).
- `config/test.exs`: `config :zahlungs, :service_dispatch, :inline` dan `config :zahlungs, :service_status_checker, false`.
- Line ending LF. Commit: `type(layanan-ppob-fase-1): subjek`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Setiap task selesai bila `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, dan `mix test` bersih.

## Keputusan di luar spec (dicatat di sini, bukan rahasia)

- **`sent_at`** di `service_transactions`, diisi (dan di-commit) tepat sebelum `pay` dipanggil. Pengecek status mengirim transaksi yang `sent_at`-nya kosong (pengiriman pertama, bukan ulang); yang sudah punya `sent_at` hanya ditanya `status`. Tanpa ini, transaksi yang tercatat tapi belum sempat dikirim saat server mati menggantung selamanya.
- `status` dan `pay` menerima map `%{ref_id, product_code, customer_ref}` agar adapter tiruan bisa tetap stateless.
- `Provider.Fake` menambah digit **4** (pay timeout, lalu `status` = tidak dikenal) untuk menguji aturan spec "penyedia tidak mengenal `ref_id`", dan inquiry dengan digit **7** = `:unavailable`.

## Review Focus

1. **ID pelanggan diubah di layar setelah Cek tagihan, lalu Bayar ditekan**: yang dibayar harus pelanggan yang dicek (nomor dari inquiry), dan layar membuang hasil inquiry saat nomornya diubah → test di Task 5 dan Task 10.
2. **Admin menyimpan form akun tanpa mengisi ulang kredensial** (mis. hanya mengganti nama): kredensial lama tidak boleh terhapus → test di Task 2.
3. **Mode akun diganti dari `api` ke `manual` saat masih ada transaksi pending**: transaksi itu tetap `api`, tetap diselesaikan callback/pengecek, dan tidak bisa ditandai manual → test di Task 7.
4. **Callback datang sebelum balasan `pay` kembali** (penyedia cepat): balasan `pay` yang datang belakangan untuk transaksi yang sudah final diabaikan tanpa error → test di Task 6.
5. **Penyedia lambat atau mati saat Cek tagihan**: layar tidak menggantung; tampil "Penyedia tidak tersedia, coba lagi", dan tidak ada yang tercatat → test di Task 4 dan Task 10.

---

### Task 1: Antarmuka penyedia dan adapter tiruan

**Files:**
- Create: `lib/zahlungs/services/provider.ex`, `lib/zahlungs/services/provider/fake.ex`
- Test: `test/zahlungs/services/provider_fake_test.exs`

**Interfaces:**
- Produces:
  - Behaviour `Zahlungs.Services.Provider` dengan callback persis seperti spec (bagian Antarmuka penyedia), plus `credential_fields() :: [{key :: String.t(), label :: String.t()}]`. `balance/1` opsional (`@optional_callbacks`).
  - `Provider.adapters() :: %{String.t() => module}` → `%{"fake" => Provider.Fake}`; `Provider.adapter(key) :: {:ok, module} | :error`; `Provider.options() :: [{label, key}]` (`[{"Penyedia tiruan (uji coba)", "fake"}]`).
  - `Provider.Fake`: `credential_fields/0` → `[{"secret", "Secret callback"}]`. Hasil menurut digit terakhir `customer_ref`:

    | Digit | `inquiry` | `pay` | `status` |
    | --- | --- | --- | --- |
    | 0 | ok | `failed` ("Nomor tidak aktif") | `failed` |
    | 9 | ok | `pending` | `success` |
    | 8 | ok | `pending` | `failed` |
    | 7 | `{:error, :unavailable}` | `{:error, :timeout}` | `success` |
    | 6 | `{:error, :not_found}` | `success` | `success` |
    | 5 | `{:error, :already_paid}` | `success` | `success` |
    | 4 | ok | `{:error, :timeout}` | `{:error, :not_found}` |
    | lain | ok | `success` | `success` |

  - Inquiry ok: `sheets` = 3 bila digit kedua dari akhir `"3"`, selain itu 1; `bill_amount` = 245000 × `sheets`; `customer_name` = `"PELANGGAN " <> 4 digit terakhir`; `period` = `"OKT 2026"` (1 lembar) / `"AGU–OKT 2026"` (3 lembar); `inquiry_ref` = `"INQ-" <> customer_ref`.
  - Success: `token_sn` = 20 digit dari `customer_ref` (diulang/dipotong) untuk `product_code` berawalan `"PLN"`, selain itu `"SN" <> ref_id`; `provider_ref` = `"FAKE-" <> ref_id`.
  - Setiap panggilan `pay`/`status` mengirim `{:fake_provider, :pay | :status, ref_id}` ke `self()` (agar test bisa menghitung panggilan).
  - `verify_callback(credentials, params, headers)`: header `"x-fake-signature"` harus `Base.encode16(:crypto.mac(:hmac, :sha256, credentials["secret"], params["ref_id"] <> "|" <> params["status"]), case: :lower)`; `params["status"]` `"success"` / `"failed"` / `"pending"`. `ping/1` → `:ok`; `balance/1` → `{:ok, Decimal.new("1000000")}`. Plus `Provider.Fake.sign(secret, ref_id, status)` untuk test.

- [ ] **Step 1: Tulis test yang gagal** untuk setiap baris tabel di atas, inquiry 1 vs 3 lembar (`"530011223341"` → 1 lembar 245000; `"530011223331"` → 3 lembar 735000), token PLN 20 digit, pesan `{:fake_provider, :pay, ref}` diterima, `verify_callback` benar/salah tanda tangan, dan `Provider.adapter("nope") == :error`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services/provider_fake_test.exs` → gagal (modul belum ada).
- [ ] **Step 3: Implementasi** behaviour dan adapter (murni, tanpa database, tanpa jaringan).
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): a vendor-neutral provider interface and a fake adapter`.

### Task 2: Akun deposit mode API dan kredensial terenkripsi

**Files:**
- Create: `priv/repo/migrations/20261019090000_add_api_mode_to_deposit_accounts.exs`, `lib/zahlungs/deposits/credentials.ex`
- Modify: `lib/zahlungs/deposits/account.ex`, `lib/zahlungs/deposits.ex`, `test/support/fixtures/services_fixtures.ex`
- Test: `test/zahlungs/deposits_test.exs`

**Interfaces:**
- Consumes: `Provider.adapter/1`, `credential_fields/0`, `ping/1`, `balance/1`.
- Produces:
  - Kolom `deposit_accounts`: `mode` string NOT NULL default `"manual"`, `provider` string, `credentials` binary (`:binary`, blob), `callback_token` string unik.
  - `Deposits.Credentials.encrypt(map) :: binary`, `decrypt(binary | nil) :: {:ok, map} | :error` (JSON lalu `Plug.Crypto.MessageEncryptor`; kunci dari `Plug.Crypto.KeyGenerator.generate(secret_key_base, "deposit credentials")` dan `"deposit credentials sign"`; `secret_key_base` dari `Application.fetch_env!(:zahlungs, ZahlungsWeb.Endpoint)[:secret_key_base]`).
  - `Deposits.update_account/2` dan `create_account/1` menerima `"mode"`, `"provider"`, `"credentials" => %{key => value}`: nilai kosong **tidak** mengganti nilai tersimpan (digabung dengan yang lama); mode `api` wajib `provider` dikenal dan semua `credential_fields` terisi; `callback_token` dibuat (32 byte acak, `Base.url_encode64(padding: false)`) saat akun pertama kali menjadi `api`.
  - `Deposits.api?(account) :: boolean`; `Deposits.provider(account) :: {:ok, module, credentials_map} | :manual`; `Deposits.credentials_saved?(account) :: boolean`.
  - `Deposits.get_account_by_callback_token(token) :: Account.t() | nil` (`skip_org_id: true`).
  - `Deposits.ping(account) :: :ok | {:error, String.t()}`; `Deposits.provider_balance(account) :: {:ok, Decimal.t()} | {:error, :unsupported | String.t()}`.
  - `ServicesFixtures.api_account_fixture(attrs \\ %{})` (mode api, provider fake, secret `"rahasia-uji"`).

- [ ] **Step 1: Tulis test yang gagal**:
  - `"credentials are stored encrypted and read back"`: setelah `api_account_fixture()`, kolom `credentials` mentah (via `Repo.get!`) tidak mengandung `"rahasia-uji"`; `Deposits.provider(account)` → `{:ok, Provider.Fake, %{"secret" => "rahasia-uji"}}`.
  - `"saving without re-entering the credentials keeps them"` (Review Focus 2): `update_account(account, %{"name" => "Baru", "credentials" => %{"secret" => ""}})` → kredensial tetap `"rahasia-uji"`.
  - `"api mode needs a known provider and its credentials"`: provider `"nope"` → error di `:provider`; tanpa secret → error di `:credentials`.
  - `"an api account gets a callback token once"`: token terisi; update berikutnya tidak menggantinya; `get_account_by_callback_token/1` menemukannya lintas organisasi (dari dalam `in_org` lain).
  - `"tampered credentials don't decrypt"`: `Credentials.decrypt("xx") == :error`.
  - `"ping and balance go to the provider"`: `ping` → `:ok`; `provider_balance` → 1000000; akun manual → `{:error, :unsupported}`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/deposits_test.exs` → gagal.
- [ ] **Step 3: Implementasi** migrasi, `Credentials`, dan perubahan `Account`/`Deposits`.
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus (test Fase 0 tetap hijau).
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): deposit accounts in api mode, with encrypted credentials`.

### Task 3: Harga per lembar dan kode produk vendor

**Files:**
- Create: `priv/repo/migrations/20261019090001_add_provider_code_to_service_products.exs`
- Modify: `lib/zahlungs/services/product.ex`, `lib/zahlungs/services.ex`
- Test: `test/zahlungs/services_test.exs`

**Interfaces:**
- Produces:
  - `service_products.provider_code` string(60); cast di `Product.changeset/2`.
  - `Services.price_for(product, bill_amount, sheets \\ 1)`: tagihan → margin rupiah × `sheets`, biaya penyedia × `sheets`; margin persen dari total tagihan; produk bernominal tetap mengabaikan `sheets`.

- [ ] **Step 1: Tulis test yang gagal**: tagihan biaya penyedia 1500, admin 3000, tagihan 735000, 3 lembar → price 744000, cost 739500; margin persen 1 → price 742350, cost 739500; `price_for(bill, 245000)` (tanpa lembar) tetap 248000 / 246500; `provider_code` > 60 karakter ditolak.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): bill admin fee per sheet; vendor product codes`.

### Task 4: Inquiry tagihan

**Files:**
- Create: `priv/repo/migrations/20261019090002_create_service_inquiries.exs`, `lib/zahlungs/services/inquiry.ex`
- Modify: `lib/zahlungs/services.ex`
- Test: `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Consumes: `Deposits.provider/1`, `Provider` `inquiry/2`, `Shifts.current_shift/1`.
- Produces:
  - Tabel `service_inquiries` dengan kolom persis spec; indeks `(store_id, inserted_at)`.
  - `Services.inquire(%User{}, product_id, customer_ref) :: {:ok, Inquiry.t()} | {:error, reason}`; `reason` ∈ `:no_open_shift`, `:no_deposit_account`, `:not_api`, `:product_unavailable`, `:no_provider_code`, `:not_found`, `:already_paid`, `:unavailable`, `{:rejected, pesan}`, changeset (nomor). Toko dari shift; akun dari toko; produk harus `tagihan_pln`, aktif, berkode vendor; `expires_at` = sekarang + 15 menit. Panggilan adapter dibungkus `Task.async` + `Task.yield(task, 15_000) || Task.shutdown(task)` → `:unavailable` bila habis waktu.
  - `Services.inquiry_price(Inquiry.t()) :: %{price, cost}` (lewat `price_for/3` dengan produk inquiry).
  - `ServicesFixtures.api_store_fixture()` → default store dengan `api_account_fixture()`; `api_product_fixture(attrs)` (default tagihan_pln, `provider_code: "PLNPASCA"`, biaya penyedia 1500, admin 3000).

- [ ] **Step 1: Tulis test yang gagal** (describe `"inquire/3"`):
  - `"stores what the provider says, for 15 minutes"`: `"530011223331"` → 3 lembar, 735000, nama `"PELANGGAN 3331"`; `expires_at` ≈ 15 menit; `inquiry_price` → 744000.
  - `"passes the provider's refusals on, recording nothing"`: digit 6 → `:not_found`, 5 → `:already_paid`, 7 → `:unavailable` (Review Focus 5); tidak ada baris `service_inquiries` baru.
  - `"needs an api account, a bill product with a vendor code and an open shift"`: akun manual → `:not_api`; produk pulsa → `:product_unavailable`; tanpa `provider_code` → `:no_provider_code`; tanpa shift → `:no_open_shift`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_api_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): bill inquiry through the provider`.

### Task 5: Mencatat transaksi API

**Files:**
- Create: `priv/repo/migrations/20261019090003_add_api_fields_to_service_transactions.exs`, `lib/zahlungs/services/dispatcher.ex`
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs/services/transaction.ex`, `lib/zahlungs/application.ex`, `config/test.exs`
- Test: `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Consumes: Task 4 `Inquiry`.
- Produces:
  - Kolom `service_transactions` persis spec ditambah `sent_at`; `ref_id` unik (= `code`); `sheets` default 1; `failed_after_shift_close` default false.
  - `Services.record/3` untuk akun `api`: `channel: "api"`; produk wajib `provider_code`; tagihan wajib `"inquiry_id"`: inquiry milik toko shift, produk sama, `used_at` nil, belum kedaluwarsa → selain itu `{:error, :inquiry_expired}`; `customer_ref`, `bill_amount`, `sheets`, `customer_name`, `period` dari inquiry (`"customer_ref"`/`"bill_amount"` dari attrs diabaikan); `used_at` diisi dalam transaksi yang sama. Akun manual: `channel: "manual"`, perilaku Fase 0.
  - `Services.Dispatcher.dispatch(Transaction.t()) :: :ok` dipanggil `record/3` setelah commit untuk `channel: "api"`: `:async` → `Task.Supervisor.start_child(Zahlungs.Services.TaskSupervisor, fn -> Services.send_payment(id) end)`; `:inline` → panggil langsung. Mode dari `Application.get_env(:zahlungs, :service_dispatch, :async)`.
  - `{Task.Supervisor, name: Zahlungs.Services.TaskSupervisor}` di supervision tree (sebelum Endpoint).
  - `Services.send_payment(transaction_id) :: :ok` — dibuat di Task 6; di Task 5 cukup stub yang tidak melakukan apa-apa.

- [ ] **Step 1: Tulis test yang gagal**:
  - `"a bill is recorded from its inquiry, once"`: inquiry → `record(user, product.id, %{"inquiry_id" => inq.id, "payment_method" => "cash", "amount_paid" => "750000", "customer_ref" => "081200000000", "bill_amount" => "1"})` → channel `"api"`, `customer_ref` `"530011223331"`, bill 735000, sheets 3, price 744000, `ref_id == code` (Review Focus 1); memakai inquiry yang sama lagi → `:inquiry_expired`.
  - `"an expired inquiry, or one of another store or product, can't be paid"`: geser `expires_at` ke masa lalu → `:inquiry_expired`; inquiry toko lain → `:inquiry_expired`; produk lain → `:inquiry_expired`.
  - `"pulsa on an api account needs a vendor code"`: tanpa `provider_code` → `:no_provider_code`.
  - `"a manual account still records the Fase 0 way"`: channel `"manual"`, tanpa inquiry.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): record api services, bills from their inquiry`.

### Task 6: Mengirim pembayaran dan menerapkan jawaban

**Files:**
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs/services/transaction.ex`
- Test: `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Consumes: `Deposits.provider/1`, `Provider` `pay/2`.
- Produces:
  - `Services.send_payment(transaction_id) :: :ok`: kunci baris; hanya bila `processing`, `channel: "api"`, `sent_at` nil → isi `sent_at`, commit, lalu `pay`; hasil ke `apply_result/2`; `{:error, :timeout | :unavailable}` → pending dengan `provider_message` "Belum ada jawaban penyedia".
  - `Services.apply_result(transaction_id, result) :: {:ok, Transaction.t()} | {:ok, :already_final}`: kunci baris; hanya `processing` → final; success → `token_sn`, `provider_ref`, `resolved_at`; failed → `provider_message`, `resolved_at`, dan `failed_after_shift_close` bila shiftnya `closed`; pending → `provider_ref`, `last_checked_at`. Menyiarkan `{:service_changed, id}` ke `"services:store:#{store_id}"`.
  - `Services.subscribe(store_id) :: :ok`.
  - `mark_success/3` dan `mark_failed/3` mengembalikan `{:error, :not_manual}` untuk `channel: "api"`.

- [ ] **Step 1: Tulis test yang gagal**:
  - `"pays at once: success keeps the token, failure the message"`: pulsa (`"081234567891"`) → `success`, `token_sn` `"SN" <> ref_id`; token PLN (`provider_code` `"PLN20"`) → token 20 digit; digit 0 → `failed` dengan pesan.
  - `"pending stays processing; a timeout too"`: digit 9 dan 7 → `processing`, `sent_at` terisi.
  - `"a payment is sent once"`: setelah record, tepat satu `{:fake_provider, :pay, ref}`; `send_payment(id)` lagi → tidak ada `pay` kedua (`refute_received`).
  - `"a late answer for a settled service is ignored"` (Review Focus 4): `apply_result(id, %{status: :failed, message: "x"})` lalu `apply_result(id, %{status: :success, ...})` → `{:ok, :already_final}`, status tetap `"failed"`.
  - `"changes are broadcast to the store"`: `subscribe(store.id)` lalu record → `assert_receive {:service_changed, ^id}`.
  - `"api services can't be marked by hand"`: `mark_success` → `:not_manual`.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): send payments and apply the provider's answers`.

### Task 7: Pengecek status

**Files:**
- Create: `lib/zahlungs/services/status_checker.ex`
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs/application.ex`, `config/test.exs`
- Test: `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Produces:
  - `Services.check_status(transaction_id) :: {:ok, Transaction.t()} | {:ok, :already_final}`: panggil `status`; `{:error, :not_found}` → tetap processing, `provider_message` "Penyedia tidak mengenal transaksi ini. Periksa di aplikasi penyedia."; `last_checked_at` diisi.
  - `Services.check_pending(now \\ NaiveDateTime.utc_now()) :: non_neg_integer` (jumlah yang diproses): transaksi `api` `processing` dengan `sent_at` nil → `send_payment/1`; dengan `last_checked_at` nil atau < `now − 30 s` → `check_status/1`.
  - `Zahlungs.Services.StatusChecker`: GenServer; `handle_info(:tick)` → `check_pending/0`, jadwal ulang 60 000 ms; ditambahkan di application hanya bila `Application.get_env(:zahlungs, :service_status_checker, true)`.

- [ ] **Step 1: Tulis test yang gagal**:
  - `"pending is settled by a later status check"`: digit 9 → `check_pending/0` (dengan `now` +31 s) → `success`; digit 8 → `failed`.
  - `"a service never sent is sent by the checker, once"`: catat digit 9 (pending, satu `pay`), kosongkan `sent_at` dengan `Repo.update_all` untuk meniru server mati sebelum mengirim, buang pesan `{:fake_provider, _, _}` yang ada di mailbox, lalu `check_pending/1` → tepat satu `pay` baru dan `sent_at` terisi lagi.
  - `"a sent service is only asked about, never paid again"`: digit 4 → `check_pending` dua kali → nol `pay` tambahan, pesan "tidak mengenal".
  - `"recently checked services wait their turn"`: `last_checked_at` 10 detik lalu → tidak ada `status`.
  - `"switching the account to manual leaves pending api services to the provider"` (Review Focus 3): digit 9 pending; `update_account(account, %{"mode" => "manual"})`; `mark_success` → `:not_manual`; `check_pending` tetap menyelesaikannya → `success`.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.** `check_pending` menetapkan organisasi per transaksi (lihat Global Constraints).
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): a status checker settles what is pending`.

### Task 8: Callback penyedia

**Files:**
- Create: `lib/zahlungs_web/controllers/ppob_callback_controller.ex`
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs_web/router.ex` (scope `/api`, `pipe_through :api`, `post "/ppob/callback/:token", PpobCallbackController, :create`)
- Test: `test/zahlungs_web/controllers/ppob_callback_controller_test.exs`

**Interfaces:**
- Produces: `Services.handle_callback(token, params, headers) :: {:ok, :applied | :already_final} | {:error, :unknown_account | :invalid_signature | :unknown_ref}`; `ref_id` harus transaksi `api` milik akun itu. Controller: `:applied`/`:already_final` → 200 `{"ok": true}`; `:invalid_signature` → 401; lainnya → 404.

- [ ] **Step 1: Tulis test yang gagal**: digit 9 pending → callback bertanda tangan benar `status=success` → 200 dan transaksi `success`; callback yang sama lagi → 200, tetap `success`; tanda tangan salah → 401, tetap processing; token tak dikenal → 404; `ref_id` transaksi akun lain → 404.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.** Header diteruskan sebagai map huruf kecil dari `conn.req_headers`.
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): provider callbacks`.

### Task 9: Kas shift, tutup shift, dan pengembalian

**Files:**
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs/shifts.ex`, `lib/zahlungs_web/live/cashier_live.ex`
- Test: `test/zahlungs/services_api_test.exs`, `test/zahlungs/shifts_test.exs`

**Interfaces:**
- Produces:
  - `Services.shift_totals/1` menghitung `processing`, `success`, dan `failed` dengan `failed_after_shift_close`.
  - `Services.count_blocking_close(%Shift{}) :: non_neg_integer` (hanya `channel: "manual"` `processing`); `Shifts.close_shift/3` dan pesan CashierLive memakainya (menggantikan `count_processing/1` di dua tempat itu).
  - `Services.list_refunds_due(%Scope{}) :: [Transaction.t()]` (`api`, `failed`, `refunded_at` nil, toko scope).
  - `Services.confirm_refund(%Transaction{}, %User{}) :: {:ok, Transaction.t()} | {:error, :no_open_shift | :other_store | :not_refundable}`: kunci baris; tunai + `failed_after_shift_close` → pengeluaran kas `refund` (catatan `"Refund #{code}"`) di shift user yang terbuka (harus di toko transaksi) dalam satu transaksi; selain itu hanya `refunded_at`/`refunded_by_id`.

- [ ] **Step 1: Tulis test yang gagal**:
  - `"a shift closes over pending api services; manual ones still hold it"`: digit 9 pending → `close_shift` ok, `expected_cash` memuatnya; transaksi manual processing → `:services_processing`.
  - `"a failure after close keeps the closed shift final"`: tutup dengan digit 8 pending (kas 50000 + harga); `check_pending` → `failed`, `failed_after_shift_close`; `shift_summary(closed).expected_cash` == `closed.expected_cash`.
  - `"the refund comes out of the next shift's drawer"`: kasir buka shift baru; `list_refunds_due` memuatnya; `confirm_refund` → pengeluaran `refund` sebesar harga di shift baru; hilang dari `list_refunds_due`; kedua kali → `:not_refundable`.
  - `"a failure while the shift is open is not counted, and confirming it books no cash"`: digit 0 → `expected_cash` tidak memuatnya; `confirm_refund` → tanpa pengeluaran kas.
  - `"a non-cash failure is never refunded from a drawer"`: QRIS digit 8 setelah tutup → `confirm_refund` tanpa pengeluaran kas.
  - `"refunds are confirmed in the service's own store"`: kasir toko lain → `:other_store`; tanpa shift → `:no_open_shift`.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Mutation check**: hilangkan `failed_after_shift_close` dari `shift_totals/1` → test "closed shift final" gagal; kembalikan.
- [ ] **Step 6: Commit** `feat(layanan-ppob-fase-1): pending services don't hold a shift; failures after close are refunded from the next`.

### Task 10: Layar Layanan untuk akun API

**Files:**
- Modify: `lib/zahlungs_web/live/service_live/index.ex`
- Test: `test/zahlungs_web/live/service_live_test.exs`

**Interfaces:**
- Consumes: `inquire/3`, `inquiry_price/1`, `record/3` (`"inquiry_id"`), `check_status/1`, `list_refunds_due/1`, `confirm_refund/2`, `subscribe/1`, `Deposits.api?/1`.
- Event baru: `"inquire"` `%{"customer_ref"}`; `"check_status"` `%{"transaction_id"}`; `"confirm_refund"` `%{"transaction_id"}`; `handle_info({:service_changed, _id})` memuat ulang daftar.
- Pesan: `:not_found` "ID pelanggan tidak ditemukan."; `:already_paid` "Tagihan ini sudah lunas."; `:unavailable` "Penyedia tidak tersedia, coba lagi."; `{:rejected, pesan}` pesan apa adanya; `:inquiry_expired` "Hasil cek tagihan sudah tidak berlaku. Cek tagihan lagi."; `:no_provider_code` "Produk ini belum punya kode vendor. Minta admin melengkapinya.".

- [ ] **Step 1: Tulis test yang gagal**:
  - `"an api bill is checked, shown, then paid"`: pilih produk tagihan → `"inquire"` `"530011223331"` → html memuat "PELANGGAN 3331", "AGU–OKT 2026", "3 lembar", "Rp 744.000,00"; `"record"` (uang "750.000") → transaksi `api` dibayar dari inquiry dan langsung `success` (dispatch inline).
  - `"changing the number after checking drops the result"` (Review Focus 1): setelah inquiry, `"change"` dengan `customer_ref` lain → kartu inquiry hilang, tombol Bayar tidak ada.
  - `"a slow or refusing provider says so"` (Review Focus 5): digit 7 → flash "Penyedia tidak tersedia, coba lagi."; digit 5 → "Tagihan ini sudah lunas."
  - `"pending shows the wait and a status check"`: digit 9 → html "Menunggu penyedia", tidak ada tombol "Berhasil"; `"check_status"` → `success` dan hilang dari daftar diproses.
  - `"refunds due are confirmed from the screen"`: kegagalan setelah tutup (seperti Task 9) → "Perlu dikembalikan" memuatnya; `"confirm_refund"` → flash "Pengembalian dicatat."
  - `"updates arrive by themselves"`: mount `connected: true`; transaksi pending diselesaikan `check_pending/0` → `info(socket, {:service_changed, id})` → daftar terbarui.
  - Akun manual: test Fase 0 di file ini tetap lulus tanpa diubah.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/live/service_live_test.exs` → gagal.
- [ ] **Step 3: Implementasi.** Tombol Bayar, Cek tagihan, Cek status, dan Uang sudah dikembalikan memakai `phx-disable-with`.
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): the Layanan screen for api accounts`.

### Task 11: Struk tagihan dari inquiry

**Files:**
- Modify: `lib/zahlungs_web/controllers/service_receipt_html/show.html.heex`
- Test: `test/zahlungs_web/controllers/service_receipt_controller_test.exs`

- [ ] **Step 1: Tulis test yang gagal**: struk tagihan API memuat "PELANGGAN 3331", "AGU–OKT 2026", "3 lembar", referensi penyedia `"FAKE-…"`; struk Fase 0 tidak berubah (test lama tetap lulus).
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): bill receipts show the customer and the period`.

### Task 12: Admin: akun API dan kode produk vendor

**Files:**
- Modify: `lib/zahlungs_web/live/deposit_live/index.ex`, `lib/zahlungs_web/live/service_product_live/index.ex`
- Test: `test/zahlungs_web/live/deposit_live_test.exs`, `test/zahlungs_web/live/service_product_live_test.exs`

**Interfaces:**
- Consumes: `Provider.options/0`, `credential_fields/0` (lewat `Deposits`), `Deposits.credentials_saved?/1`, `ping/1`, `provider_balance/1`.
- Event baru di DepositLive: `"test_connection"`; `"fetch_balance"` (mengisi kolom saldo aplikasi pada form pencocokan).

- [ ] **Step 1: Tulis test yang gagal**:
  - form akun: mode API dan penyedia tiruan menampilkan field "Secret callback"; setelah disimpan, html tidak memuat nilai secret dan menampilkan "tersimpan"; URL callback `…/api/ppob/callback/<token>` tampil.
  - `"test_connection"` → flash "Koneksi ke penyedia berhasil."; `"fetch_balance"` → kolom saldo aplikasi berisi 1000000 dan pratinjau selisih tampil.
  - form produk: kolom "Kode produk vendor" tersimpan.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.** URL callback memakai `url(~p"/api/ppob/callback/#{token}")`.
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-fase-1): admin forms for api accounts and vendor codes`.

### Task 13: Dokumentasi dan pemeriksaan di browser

**Files:**
- Modify: `CLAUDE.md` (bagian PPOB: mode akun, Provider, Dispatcher, StatusChecker, callback, refund, config test), `docs/IA.md` (alur Cek tagihan, Perlu dikembalikan, callback), `docs/DEPLOYMENT.md` (URL callback harus bisa dijangkau vendor; `SECRET_KEY_BASE` jangan diganti karena kredensial terenkripsi dengannya)

- [ ] **Step 1: Tulis dokumentasi.**
- [ ] **Step 2: Jalankan** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, `mix test` → bersih.
- [ ] **Step 3: Periksa di browser** (dev server, adapter tiruan): akun deposit API, Cek tagihan → Bayar, transaksi pending selesai sendiri setelah ≤ 60 detik, layar terbarui tanpa reload. Membuat akun/produk uji di database dev **hanya dengan izin Anda**; bila tidak, cukup periksa tampilan form dan catat di laporan.
- [ ] **Step 4: Commit** `docs(layanan-ppob-fase-1): api mode, callbacks and the status checker`.
