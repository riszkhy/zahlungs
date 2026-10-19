# Layanan PPOB Fase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Toko bisa mencatat penjualan pulsa, paket data, token PLN, dan tagihan PLN (diproses manual di aplikasi penyedia), dengan status berhasil/gagal, kas shift yang tetap cocok, dan perkiraan saldo deposit yang bisa dicocokkan.

**Architecture:** Dua konteks baru: `Zahlungs.Deposits` (akun deposit, catatan isi ulang/koreksi, perkiraan saldo) dan `Zahlungs.Services` (produk layanan, harga, transaksi layanan, laporan). `Zahlungs.Shifts` hanya memanggil `Services` untuk kas layanan dan penolakan tutup shift. Penjualan barang (`Sales`, `Catalog`) tidak disentuh.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MyXQL, Tailwind. Tanpa dependensi baru.

**Spec:** `docs/superpowers/specs/2026-10-16-layanan-ppob-fase-0-design.md`

## Global Constraints

- Tidak ada dependensi baru (hex.pm tidak terjangkau dari mesin ini).
- LiveView dan controller hanya memanggil fungsi konteks, tidak pernah `Repo` atau schema langsung.
- Uang selalu `Decimal`, kolom `decimal(15, 2)`, ditampilkan dengan `format_money/1`.
- Tanggal bisnis lewat `Zahlungs.LocalTime` dengan toko yang relevan; jangan `Date.utc_today/0`.
- Fungsi per toko menerima `%Zahlungs.Scope{}` dan menyaring dengan `Scope.store_id/1`; untuk "semua toko" dengan `Stores.store_ids/0`. Toko tidak pernah diambil dari parameter.
- Tabel milik pemilik membawa `organization_id` dan memakai `Zahlungs.Organizations.put_organization/1` di changeset.
- Teks UI berbahasa Indonesia.
- Event `JS.push(value: ...)` mengirim id sebagai angka JSON: handler menerima integer maupun string.
- Test LiveView lewat `ZahlungsWeb.LiveDriver` (`mount_live/3`, `event/3`, `html/1`, `flash/2`); akses lewat `get/2`. Database dev dipakai bersama test: cari data berdasarkan nilai unik, jangan menganggap tabel kosong.
- Line ending LF.
- Commit: `type(layanan-ppob): subjek`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Setiap task selesai bila `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, dan `mix test` bersih.

## Review Focus

1. **Nomor tujuan diketik dengan spasi, strip, titik, atau `+62`** ("0812-3456 7890", "+62 812…") harus tersimpan sebagai angka saja, dan huruf ditolak → test di Task 3.
2. **Nominal dengan pemisah ribuan** dari input ("245.000") harus dibaca 245000, bukan 245 → test di Task 7 (layar membuang pemisah sebelum memanggil konteks).
3. **Produk dinonaktifkan atau dihapus** saat layar kasir masih terbuka; mencatatnya harus ditolak, bukan memakai harga lama → test di Task 3.
4. **Tombol "Catat dan terima uang" ditekan dua kali** tidak boleh mudah menghasilkan dua transaksi → `phx-disable-with` di tombol, dicek di Task 7.
5. **Akun deposit toko diganti atau dinonaktifkan saat masih ada transaksi diproses**: transaksi lama tetap di akun lamanya, perkiraan saldo kedua akun benar, dan toko dengan akun nonaktif tidak bisa mencatat → test di Task 6.

---

### Task 1: Akun deposit dan pilihannya di toko

**Files:**
- Create: `priv/repo/migrations/20261016090000_create_deposit_accounts.exs`
- Create: `lib/zahlungs/deposits.ex`, `lib/zahlungs/deposits/account.ex`
- Create: `test/support/fixtures/services_fixtures.ex`
- Modify: `lib/zahlungs/stores/store.ex` (belongs_to + cast + validasi)
- Test: `test/zahlungs/deposits_test.exs`

**Interfaces:**
- Produces:
  - Tabel `deposit_accounts` (`organization_id` NOT NULL FK, `name` string 80 NOT NULL, `active` boolean default true, timestamps; unik `(organization_id, name)`); `stores.deposit_account_id` FK nullable.
  - `Zahlungs.Deposits.Account` schema; `changeset/2` cast `name`, `active`.
  - `Deposits.list_accounts() :: [Account.t()]` (urut nama), `list_active_accounts()`, `account_options() :: [{name, id}]` (aktif saja), `get_account!(id)`, `active_account?(id) :: boolean`, `create_account(attrs)`, `update_account(account, attrs)`, `change_account(account, attrs \\ %{})`.
  - `Store.changeset/2` cast `deposit_account_id`; ditolak dengan pesan "akun deposit tidak aktif" bila `Deposits.active_account?/1` false.
  - `ServicesFixtures.deposit_account_fixture(attrs \\ %{})` dan `ServicesFixtures.assign_account(store, account) :: Store.t()`.

- [ ] **Step 1: Tulis test yang gagal** di `test/zahlungs/deposits_test.exs` (`use Zahlungs.DataCase, async: true`):
  - `"creates and renames an account; names are unique per organization"`: `create_account(%{name: "Pusat"})` → `{:ok, _}`; nama sama lagi → `{:error, changeset}` dengan error di `:name`; nama sama di `organization_fixture()` lain lewat `in_org/2` → `{:ok, _}`.
  - `"another organization's accounts are invisible"`: akun dibuat di org lain tidak muncul di `list_accounts()` dan `get_account!/1` raise `Ecto.NoResultsError`.
  - `"a store takes only an active account of its own organization"`: `Stores.update_store(store, %{deposit_account_id: active.id})` → ok; akun nonaktif → error "akun deposit tidak aktif"; akun org lain → error yang sama.
  - `"account_options lists active accounts only"`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/deposits_test.exs` → gagal karena `Zahlungs.Deposits` belum ada.
- [ ] **Step 3: Implementasi** migrasi, schema `Account` (dengan `belongs_to :organization` dan `put_organization/1`, `unique_constraint(:name, name: :deposit_accounts_organization_id_name_index)`), konteks `Deposits`, dan perubahan `Store` (`belongs_to :deposit_account, Zahlungs.Deposits.Account`; `validate_change(:deposit_account_id, ...)`). Fixture membuat akun dengan nama unik.
- [ ] **Step 4: Jalankan** test file itu dan `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): deposit accounts, and the one each store uses`.

### Task 2: Produk layanan dan harganya

**Files:**
- Create: `priv/repo/migrations/20261016090001_create_service_products.exs`
- Create: `lib/zahlungs/services.ex`, `lib/zahlungs/services/product.ex`
- Modify: `test/support/fixtures/services_fixtures.ex`
- Test: `test/zahlungs/services_test.exs`

**Interfaces:**
- Produces:
  - Tabel `service_products` (`organization_id` NOT NULL, `name` 160 NOT NULL, `category` NOT NULL, `operator` 60, `cost` decimal(15,2) NOT NULL default 0, `margin_type` NOT NULL default "amount", `margin_value` decimal(15,2) NOT NULL default 0, `active` default true, `deleted_at`, timestamps; indeks `(organization_id, category)`).
  - `Services.Product`: kategori `~w(pulsa paket_data token_pln tagihan_pln)`, `margin_type` `~w(amount percent)`; `cost` > 0 untuk tiga kategori bernominal tetap, ≥ 0 untuk `tagihan_pln`; `margin_value` ≥ 0.
  - `Services.categories() :: [{"pulsa", "Pulsa"}, {"paket_data", "Paket data"}, {"token_pln", "Token PLN"}, {"tagihan_pln", "Tagihan PLN"}]`.
  - `Services.list_products(opts \\ [])` (opsi `:category`, `:active`; tanpa yang dihapus; urut nama), `get_product!(id)` (tanpa yang dihapus), `create_product/1`, `update_product/2`, `delete_product/1` (isi `deleted_at`), `change_product/2`.
  - `Services.price_for(%Product{}, bill_amount :: Decimal.t() | nil) :: {:ok, %{price: Decimal.t(), cost: Decimal.t()}} | {:error, :bill_required}`.
  - `ServicesFixtures.service_product_fixture(attrs \\ %{})` (default: kategori "pulsa", nama unik, cost 10150, margin amount 1850).

- [ ] **Step 1: Tulis test yang gagal** di `test/zahlungs/services_test.exs`, describe `"price_for/2"`, dengan angka dari spec:
  - token PLN, cost 50150, margin amount 2350 → `%{price: 52500, cost: 50150}`.
  - pulsa, cost 10150, margin percent 15 → price 11673 (11672,5 dibulatkan ke atas), cost 10150.
  - tagihan PLN, cost (biaya penyedia) 1500, margin amount 3000, tagihan 245000 → price 248000, cost 246500.
  - tagihan PLN, margin percent 1, tagihan 245000 → price 247450, cost 245000 + cost produk.
  - tagihan PLN dengan `nil` atau 0 → `{:error, :bill_required}`.
  - Bandingkan dengan `Decimal.equal?/2`.
- [ ] **Step 2: Tulis test yang gagal**, describe `"products"`: validasi (kategori tak dikenal, margin negatif, cost 0 untuk pulsa ditolak tapi diterima untuk tagihan); `delete_product/1` menyembunyikan dari `list_products/1` dan `get_product!/1`; produk org lain tidak terlihat.
- [ ] **Step 3: Jalankan** `mix test test/zahlungs/services_test.exs` → gagal.
- [ ] **Step 4: Implementasi.** `price_for/2`: basis = `cost` (bernominal tetap) atau `bill_amount` (tagihan); margin = `margin_value` atau `basis × margin_value / 100` dibulatkan `Decimal.round(_, 0, :ceiling)`; price = basis + margin; cost = `cost` (tetap) atau `bill_amount + cost` (tagihan).
- [ ] **Step 5: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 6: Commit** `feat(layanan-ppob): service products priced by a rupiah or percent margin`.

### Task 3: Mencatat transaksi layanan

**Files:**
- Create: `priv/repo/migrations/20261016090002_create_service_transactions.exs`
- Create: `lib/zahlungs/services/transaction.ex`
- Modify: `lib/zahlungs/services.ex`, `test/support/fixtures/services_fixtures.ex`
- Test: `test/zahlungs/services_test.exs`

**Interfaces:**
- Consumes: `Shifts.lock_current_shift/1`, `Stores.get_store!/1`, `Deposits.active_account?/1`, `Services.price_for/2`.
- Produces:
  - Tabel `service_transactions` dengan kolom persis seperti spec (bagian Data); FK ke `stores`, `cashier_shifts`, `users` (`user_id`, `resolved_by_id`), `service_products`, `deposit_accounts`; unik `(store_id, code)`; indeks `(shift_id, status)`, `(deposit_account_id, status)`.
  - `Services.Transaction`, status `~w(processing success failed)`, cara bayar = `Zahlungs.Sales.Sale.payment_methods()`.
  - `Services.record(%User{}, product_id, attrs) :: {:ok, Transaction.t()} | {:error, :no_open_shift | :no_deposit_account | :product_unavailable | :bill_required | :insufficient_payment | Ecto.Changeset.t()}`. `attrs` berkunci string: `"customer_ref"`, `"bill_amount"`, `"payment_method"` (default "cash"), `"amount_paid"`.
  - Kode: `"#{store.code}-LYN#{yymmddHHMMSS waktu toko}#{4 hex}"`.
  - `ServicesFixtures.service_fixture(user, product, attrs \\ %{})` (default nomor "081234567890", tunai dibayar pas).

- [ ] **Step 1: Tulis test yang gagal**, describe `"record/3"` (pakai `user_on_shift_fixture/0` dan `assign_account(default_store(), deposit_account_fixture())`):
  - `"records a processing transaction in the shift's store, with the price and cost of the moment"`: status `"processing"`, `store_id`/`shift_id` dari shift, `deposit_account_id` dari toko, `price`/`cost` sesuai `price_for/2`, `product_name`/`category` tersalin, kode cocok `~r/^#{store.code}-LYN\d{12}[0-9A-F]{4}$/`. Mengubah margin produk setelahnya tidak mengubah transaksi.
  - `"cash must cover the price; change is worked out"`: dibayar 20000 untuk harga 12000 → `change_due` 8000; dibayar 10000 → `{:error, :insufficient_payment}`; QRIS → `amount_paid` = price, kembalian 0.
  - `"tagihan PLN needs the bill"`: tanpa `"bill_amount"` → `{:error, :bill_required}`; dengan 245000 → `bill_amount` tersimpan.
  - `"the customer number keeps its digits only"`: "0812-3456 7890" → "081234567890"; "+62 812.3456.7890" → "6281234567890"; "0812abc" dan "123" → changeset error di `:customer_ref` (Review Focus 1).
  - `"refuses without an open shift, without an active deposit account, and for a product no longer for sale"`: tanpa shift → `:no_open_shift`; toko tanpa akun atau akun dinonaktifkan → `:no_deposit_account`; produk nonaktif atau dihapus → `:product_unavailable` (Review Focus 3).
  - `"the store comes from the shift, not from the caller"`: `attrs` berisi `"store_id"` toko lain diabaikan.
- [ ] **Step 2: Jalankan** test → gagal.
- [ ] **Step 3: Implementasi** `record/3` dalam satu `Repo.transaction`: `Repo.put_org_id(user.organization_id)`; kunci shift; toko dari shift; akun dari `store.deposit_account_id` bila aktif; produk via `get_product!` yang aktif (selain itu `:product_unavailable`); harga dari `price_for/2`; changeset `Transaction` membersihkan `customer_ref` (buang `[\s\-\.\+]`, validasi `~r/^\d{6,20}$/`).
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): record a service when the money is taken`.

### Task 4: Menandai berhasil atau gagal

**Files:**
- Modify: `lib/zahlungs/services.ex`
- Test: `test/zahlungs/services_test.exs`

**Interfaces:**
- Produces:
  - `Services.mark_success(%Transaction{}, %User{}, token_sn :: String.t() | nil) :: {:ok, Transaction.t()} | {:error, :not_processing | :forbidden | Ecto.Changeset.t()}`.
  - `Services.mark_failed(%Transaction{}, %User{}, reason :: String.t()) :: same` (alasan wajib, ≤ 255).
  - Keduanya mengisi `resolved_by_id`, `resolved_at`.
  - `Services.get_transaction!(%Scope{}, id)` (transaksi toko lain → `Ecto.NoResultsError`).
  - `Services.list_shift_transactions(%Shift{}) :: [Transaction.t()]` (terbaru dulu).
  - `Services.count_processing(%Shift{}) :: non_neg_integer`.

- [ ] **Step 1: Tulis test yang gagal**, describe `"marking the result"`:
  - `"success keeps the token; failure needs a reason"`: token "5821 0344 9917 2268 4410" tersimpan apa adanya (≤ 64); gagal tanpa alasan → changeset error; dengan alasan → status `"failed"`.
  - `"a result is final"`: menandai lagi transaksi yang sudah berhasil/gagal → `{:error, :not_processing}`.
  - `"a stale struct cannot win twice"`: dua salinan struct yang sama; `mark_success` pada salinan pertama, lalu `mark_failed` pada salinan kedua → `{:error, :not_processing}`, status tetap `"success"`.
  - `"only the cashier who recorded it, or an admin, may mark it"`: kasir lain di toko yang sama → `:forbidden`; admin → ok.
  - `"another store's transaction is not found"`: `get_transaction!(store_scope(other_store), id)` raise.
- [ ] **Step 2: Jalankan** test → gagal.
- [ ] **Step 3: Implementasi** dengan `Repo.transaction` + `lock: "FOR UPDATE"` pada baris transaksi, memeriksa status di database dan hak (`tx.user_id == user.id or user.role == "admin"`).
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): mark a service as done or failed, once`.

### Task 5: Layanan di kas shift dan penutupan shift

**Files:**
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs/shifts.ex`
- Test: `test/zahlungs/shifts_test.exs`

**Interfaces:**
- Consumes: `Services.count_processing/1`.
- Produces:
  - `Services.shift_totals(%Shift{}) :: %{count: integer, total: Decimal.t(), cash_total: Decimal.t()}`, menghitung status `processing` dan `success` saja; `cash_total` hanya cara bayar `"cash"`.
  - `Shifts.expected_cash/1` = rumus lama + `cash_total` layanan.
  - `Shifts.shift_summary/1` menambah kunci `:service_count`, `:service_total`, `:service_cash_total`; `:expected_cash` ikut memuat kas layanan.
  - `Shifts.close_shift/3` → `{:error, :services_processing}` bila `count_processing(shift) > 0`, diperiksa setelah baris shift dikunci.

- [ ] **Step 1: Tulis test yang gagal**, describe `"services in the drawer"`:
  - `"processing and successful cash services count; failed and non-cash ones do not"`: kas awal 50000; layanan tunai 12000 (berhasil), 52500 (diproses), 26500 (gagal), QRIS 11800 (berhasil) → `expected_cash` = 50000 + 12000 + 52500 = 114500; `shift_summary` `service_count` 3, `service_cash_total` 64500.
  - `"a shift with a service still processing cannot be closed"`: `close_shift/3` → `{:error, :services_processing}`, shift tetap `"open"`; setelah ditandai → bisa ditutup dan `expected_cash` tersimpan memuat layanan.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/shifts_test.exs` → gagal.
- [ ] **Step 3: Implementasi** di `Services` dan `Shifts` sesuai Interfaces.
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Mutation check**: (a) hitung juga status `failed` di `shift_totals/1` → test kas gagal; (b) lewati pemeriksaan di `close_shift/3` → test tutup shift gagal. Kembalikan, test lulus lagi.
- [ ] **Step 6: Commit** `feat(layanan-ppob): service cash in the drawer; no closing over unfinished services`.

### Task 6: Catatan deposit dan perkiraan saldo

**Files:**
- Create: `priv/repo/migrations/20261016090003_create_deposit_entries.exs`
- Create: `lib/zahlungs/deposits/entry.ex`
- Modify: `lib/zahlungs/deposits.ex`, `lib/zahlungs/shifts/cash_movement.ex`, `lib/zahlungs_web/live/shift_live/index.ex` (label kategori)
- Test: `test/zahlungs/deposits_test.exs`

**Interfaces:**
- Consumes: `Shifts.lock_current_shift/1`, `Shifts.add_cash_movement/2`, tabel `service_transactions`.
- Produces:
  - Tabel `deposit_entries` dengan kolom persis seperti spec; FK `deposit_account_id`, `cash_movement_id` (nullable), `recorded_by_id`.
  - Kategori kas `"deposit_topup" => "out"` (tidak masuk daftar input manual di `CashierLive`); `ShiftLive` memberinya label "Isi deposit".
  - `Deposits.record_topup(%User{} = admin, %Account{}, %{"amount", "source", "note"}) :: {:ok, Entry.t()} | {:error, :no_open_shift | Ecto.Changeset.t()}`; `"source"` `"drawer"` menulis juga pengeluaran kas di shift terbuka admin, dengan catatan "Isi deposit: <nama akun>", dalam satu transaksi.
  - `Deposits.record_correction(admin, account, %{"amount", "note"})` (≠ 0, alasan wajib).
  - `Deposits.estimated_balance(%Account{}) :: Decimal.t()` = Σ entri − Σ `cost` transaksi `processing`/`success` di akun itu.
  - `Deposits.reconcile(admin, account, actual_balance, note \\ nil) :: {:ok, :matched} | {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}`; koreksi bercatatan "Pencocokan: saldo aplikasi Rp X" (+ catatan admin).
  - `Deposits.list_entries(%Account{}) :: [Entry.t()]` (terbaru dulu); `Deposits.list_accounts_with_balance() :: [%{account: Account.t(), balance: Decimal.t()}]`.

- [ ] **Step 1: Tulis test yang gagal**, describe `"deposit entries"`:
  - `"the estimate is top-ups and corrections minus the cost of processing and successful services"`: isi ulang 500000 (luar laci); layanan modal 10150 berhasil, 50150 diproses, 26000 gagal → `estimated_balance` 439700.
  - `"a top-up from the drawer is also a cash-out on the admin's shift"`: admin dengan shift terbuka; entri punya `cash_movement_id`; `Shifts.list_cash_movements/1` memuat kategori `"deposit_topup"` 200000; `expected_cash` turun 200000. Tanpa shift terbuka → `{:error, :no_open_shift}` dan tidak ada entri.
  - `"a correction needs a reason and may be negative"`.
  - `"reconciling records the difference, and the next one starts from there"`: perkiraan 439700, saldo aplikasi 430000 → entri −9700; `estimated_balance` → 430000; pencocokan lagi dengan 430000 → `{:ok, :matched}` tanpa entri baru.
  - `"a store's account can change; old services stay with the old account"` (Review Focus 5): transaksi diproses di akun A; toko dipindah ke akun B; perkiraan A tetap memotong modalnya, B tidak; menonaktifkan B membuat `Services.record/3` di toko itu → `:no_deposit_account`.
  - `"another organization's entries are invisible"`.
- [ ] **Step 2: Jalankan** test → gagal.
- [ ] **Step 3: Implementasi** migrasi, schema `Entry` (`put_organization/1`), dan fungsi `Deposits` sesuai Interfaces.
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Mutation check**: hilangkan transaksi `processing` dari `estimated_balance/1` → test perkiraan gagal; kembalikan.
- [ ] **Step 6: Commit** `feat(layanan-ppob): deposit top-ups, corrections and the estimated balance`.

### Task 7: Layar kasir "Layanan"

**Files:**
- Create: `lib/zahlungs_web/live/service_live/index.ex`
- Modify: `lib/zahlungs_web/router.ex` (`live "/services", ServiceLive.Index, :index` di live_session terautentikasi), `lib/zahlungs_web/components/layouts.ex` (`{"Layanan", ~p"/services"}` setelah Cashier di `cashier_links/0`)
- Test: `test/zahlungs_web/live/service_live_test.exs`

**Interfaces:**
- Consumes: `Shifts.current_shift/1`, `Stores.get_store!/1`, `Services.list_products/1`, `price_for/2`, `record/3`, `mark_success/3`, `mark_failed/3`, `list_shift_transactions/1`.
- Produces: `ServiceLive.Index.group_digits(String.t()) :: String.t()` ("081234567890" → "0812 3456 7890", kelompok 4 dari kiri).
  - Event: `"set_category"` `%{"category"}`; `"select"` `%{"id"}`; `"change"` dan `"record"` `%{"service" => %{"customer_ref", "bill_amount", "payment_method", "amount_paid"}}`; `"mark_success"` `%{"id", "token_sn"}`; `"mark_failed"` `%{"id", "reason"}`.
  - Pesan galat: `:no_open_shift` "Buka shift dulu di Cashier."; `:no_deposit_account` "Toko ini belum punya akun deposit aktif. Minta admin mengaturnya."; `:product_unavailable` "Produk ini sudah tidak tersedia."; `:bill_required` "Isi nominal tagihan."; `:insufficient_payment` "Uang diterima kurang dari harga."; `:not_processing` "Transaksi ini sudah ditandai."; `:forbidden` "Hanya kasir yang mencatat atau admin yang bisa menandai."; changeset nomor "Nomor tujuan harus 6–20 angka.".
  - Setelah gagal ditandai: flash "Kembalikan Rp X ke pelanggan." (X = harga).

- [ ] **Step 1: Tulis test yang gagal**:
  - akses: tamu `get("/services")` → `/users/log_in`; kasir login → 200.
  - `"without a shift it sends the cashier to open one"`: html memuat `href="/cashier"` dan tidak ada form.
  - `"records a service and lists it as processing"`: pilih kategori dan produk, `"record"` dengan nomor "0812-3456-7890" dan dibayar "20.000" → daftar diproses memuat "0812 3456 7890" dan transaksi di DB dibayar 20000 (Review Focus 2).
  - `"tagihan PLN reads the bill with thousand separators"`: `"bill_amount" => "245.000"` → `bill_amount` 245000.
  - `"marking success shows the receipt link; failing tells how much to return"`.
  - `"the record button can't be pressed twice"`: tombol punya `phx-disable-with` (Review Focus 4).
  - `"group_digits/1"`: "081234567890" → "0812 3456 7890"; "6281234567890" → "6281 2345 6789 0".
  - handler menerima id integer dan string.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/live/service_live_test.exs` → gagal.
- [ ] **Step 3: Implementasi** LiveView sesuai mockup di spec (chip, tile, form kanan, daftar "Sedang diproses", riwayat shift). Toko = toko shift; buang semua non-angka dari `bill_amount` dan `amount_paid` sebelum memanggil konteks; pratinjau harga dan kembalian dari `price_for/2`.
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): the cashier's Layanan screen`.

### Task 8: Struk layanan

**Files:**
- Create: `lib/zahlungs_web/controllers/service_receipt_controller.ex`, `service_receipt_html.ex`, `service_receipt_html/show.html.heex`
- Modify: `lib/zahlungs_web/router.ex` (`get "/services/:id/receipt"` di scope terautentikasi, di sebelah struk penjualan)
- Test: `test/zahlungs_web/controllers/service_receipt_controller_test.exs`

**Interfaces:**
- Consumes: `Services.get_transaction!/2`.

- [ ] **Step 1: Tulis test yang gagal**: struk memuat kode, nama produk, nomor tujuan, token, nominal tagihan (bila ada), harga, dibayar, kembalian, status "Berhasil"; waktu memakai zona toko; transaksi toko lain → 404; tamu → login.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi** mengikuti `ReceiptController` (tanpa layout, cetak saat dibuka).
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): printable service receipt with the token`.

### Task 9: Tutup shift di layar Cashier

**Files:**
- Modify: `lib/zahlungs_web/live/cashier_live.ex`
- Test: `test/zahlungs_web/live/cashier_live_test.exs`

**Interfaces:**
- Consumes: `shift_summary/1` kunci `:service_cash_total`; `{:error, :services_processing}`; `Services.count_processing/1`.

- [ ] **Step 1: Tulis test yang gagal**: ringkasan tutup shift memuat "Layanan tunai" dengan jumlahnya; `"close_shift"` saat ada yang diproses → flash "Selesaikan dulu 1 layanan yang masih diproses." dan html memuat `href="/services"`; shift tetap terbuka.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi** baris ringkasan dan cabang galat baru.
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): closing a shift shows service cash and waits for unfinished services`.

### Task 10: Admin produk layanan

**Files:**
- Create: `lib/zahlungs_web/live/service_product_live/index.ex`, `form_component.ex`
- Modify: `lib/zahlungs_web/router.ex` (`/admin/services`, `/admin/services/new`, `/admin/services/:id/edit` di live_session admin), `lib/zahlungs_web/components/layouts.ex` (`{"Produk layanan", ~p"/admin/services"}` di `admin_links/0`)
- Test: `test/zahlungs_web/live/service_product_live_test.exs`

**Interfaces:**
- Consumes: `Services.list_products/1`, `create_product/1`, `update_product/2`, `delete_product/1`, `price_for/2`, `categories/0`.

- [ ] **Step 1: Tulis test yang gagal**: kasir → `/`; admin → daftar dengan harga terhitung; filter kategori; hapus menyembunyikan; form untuk tagihan berlabel "Biaya penyedia" dan "Biaya admin"; pratinjau harga berubah saat margin diganti Rp ↔ %.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi** mengikuti pola `ProductLive.Index` dan form component-nya.
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): admin page for service products`.

### Task 11: Admin deposit dan akun di form toko

**Files:**
- Create: `lib/zahlungs_web/live/deposit_live/index.ex`
- Modify: `lib/zahlungs_web/router.ex` (`/admin/deposits`, `/admin/deposits/new`, `/admin/deposits/:id`, `/admin/deposits/:id/edit` di live_session admin), `layouts.ex` (`{"Deposit", ~p"/admin/deposits"}`), `store_live/form_fields.ex` (attr `deposit_account_options`, select "Akun deposit" dengan pilihan kosong "— Belum ada —"), `store_live/index.ex` dan `store_live/register.ex` (meneruskan `Deposits.account_options()`)
- Test: `test/zahlungs_web/live/deposit_live_test.exs`, `test/zahlungs_web/live/store_live_test.exs`

**Interfaces:**
- Consumes: `Deposits.list_accounts_with_balance/0`, `create_account/1`, `update_account/2`, `record_topup/3`, `record_correction/3`, `reconcile/4`, `list_entries/1`, `account_options/0`, `Shifts.current_shift/1`.
- Event di `:show`: `"topup"` `%{"topup" => %{"amount", "source", "note"}}`; `"reconcile_preview"` dan `"reconcile"` `%{"actual_balance", "note"}`.

- [ ] **Step 1: Tulis test yang gagal**: kasir → `/`; daftar akun dengan perkiraan saldo; isi ulang "dari luar laci" menambah saldo; pilihan "Kas laci shift saya" hanya tampil bila admin punya shift terbuka; pratinjau pencocokan menampilkan selisih, menyimpan membuat koreksi, dan selisih 0 menampilkan "Cocok"; riwayat entri terbaru di atas. Form toko menawarkan akun aktif saja dan menyimpan pilihannya.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob): admin page for deposits, and the account in the store form`.

### Task 12: Laporan layanan dan dokumentasi

**Files:**
- Create: `lib/zahlungs_web/live/report_live/services.ex`
- Modify: `lib/zahlungs/services.ex`, `lib/zahlungs_web/router.ex` (`/reports/services` di live_session admin), `layouts.ex` (`{"Laporan layanan", ~p"/reports/services"}`), `lib/zahlungs_web/live/report_live/index.ex` (catatan "Layanan ada di Laporan layanan" dengan tautan), `CLAUDE.md`, `docs/IA.md`
- Test: `test/zahlungs/services_test.exs`, `test/zahlungs_web/live/report_live_test.exs`

**Interfaces:**
- Produces: `Services.report(%Scope{}, %Date{} = from, %Date{} = to) :: %{success_count: integer, failed_count: integer, value: Decimal.t(), cost: Decimal.t(), margin: Decimal.t(), by_category: [%{category: String.t(), count: integer, value: Decimal.t(), cost: Decimal.t(), margin: Decimal.t()}]}`; rentang tanggal lewat `LocalTime.day_range/3` dengan toko scope; nilai, modal, dan margin dari transaksi `success` saja.

- [ ] **Step 1: Tulis test yang gagal**: dua berhasil (pulsa 12000/10150, token 52500/50150) dan satu gagal → `success_count` 2, `failed_count` 1, `value` 64500, `cost` 60300, `margin` 4200, rincian per kategori; transaksi toko lain tidak ikut untuk scope satu toko, ikut untuk "semua toko" admin di organisasi yang sama, dan tidak pernah dari organisasi lain; di luar rentang tanggal tidak ikut. Halaman: kasir → `/`, admin melihat angka-angka itu; laporan penjualan memuat tautan ke `/reports/services`.
- [ ] **Step 2: Jalankan** → gagal.
- [ ] **Step 3: Implementasi** laporan dan halaman mengikuti pola `ReportLive.Index`.
- [ ] **Step 4: Dokumentasi**: `CLAUDE.md` mendapat bagian "Layanan (PPOB)" berisi kedua konteks, aturan status, kas shift, perkiraan saldo, dan tabel baru di daftar tabel; `docs/IA.md` mendapat halaman `/services`, `/admin/services`, `/admin/deposits`, `/reports/services` dan siapa yang boleh membukanya.
- [ ] **Step 5: Jalankan** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, `mix test` → semua bersih.
- [ ] **Step 6: Periksa di browser** (dev server): layar Layanan di lebar tablet tegak dan mendatar; bila tautan "Layanan" membuat bilah atas tidak muat di tablet tegak, pindahkan ke menu saja dan catat di laporan akhir.
- [ ] **Step 7: Commit** `feat(layanan-ppob): service report, and the docs`.
