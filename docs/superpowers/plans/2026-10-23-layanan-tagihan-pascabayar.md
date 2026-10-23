# Layanan PPOB — tagihan pascabayar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kasir menerima pembayaran BPJS Kesehatan, PDAM, Telkom/IndiHome dan Gas PGN lewat satu kategori "Tagihan" (termasuk PLN), dengan jumlah bulan 1–12 untuk produk yang memintanya.

**Architecture:** Kategori `tagihan_pln` menjadi `tagihan` (data dimigrasi); semua aturan tagihan yang ada (inquiry, ref dipakai ulang, harga dari total penyedia, biaya tambahan per bulan) berlaku untuk kategori itu. Produk baru bisa `ask_months`; `Services.inquire/4` menerima jumlah bulan, menyimpannya di inquiry, dan adapter SBI mengirimnya sebagai `periode` saat inquiry dan payment.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MyXQL. Tanpa dependensi baru.

**Spec:** `docs/superpowers/specs/2026-10-23-layanan-tagihan-pascabayar-design.md`

## Global Constraints

- Branch `feat/layanan-tagihan`, dibuat dari `feat/layanan-ppob-fase-1`. Commit: `type(layanan-tagihan): subjek`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tidak ada dependensi baru. Test tidak pernah memanggil SBI (`Sbi.StubClient`).
- LiveView hanya memanggil fungsi konteks. Uang `Decimal`.
- Jumlah bulan sah: bilangan bulat 1–12. Akun manual tidak menanyakan jumlah bulan.
- Teks UI berbahasa Indonesia: kategori "Tagihan"; "N bulan" menggantikan "N lembar"; centang "Tanyakan jumlah bulan saat cek tagihan"; pilihan "Jumlah bulan".
- Setiap task selesai bila `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, dan `mix test` bersih.

## Review Focus

1. **Jumlah bulan diubah di layar setelah Cek tagihan, lalu Bayar ditekan**: hasil cek dibuang di layar; di server, harga dan `periode` bayar selalu dari inquiry, bukan dari params → test di Task 2 dan Task 4.
2. **Jumlah bulan dari form berupa teks** (`"3"`, `""`, `"abc"`, `"13"`): `"3"` diterima, `""` menjadi 1 untuk produk `ask_months`, sisanya `{:error, :invalid_months}` tanpa memanggil penyedia → test di Task 2.
3. **Jawaban SBI menyebut `Jml bulan` yang berbeda dari pilihan kasir**: yang dipakai jawaban SBI (yang ditagih penyedia), bukan pilihan kasir → test di Task 2.
4. **Produk `ask_months` dijual lewat akun manual**: tidak ada jumlah bulan, nominal diketik, satu lembar → test di Task 2.
5. **Transaksi dan produk lama `tagihan_pln`** setelah migrasi: terhitung di baris "Tagihan" laporan layanan, struknya tetap menampilkan jumlah bulan → test di Task 1.

---

### Task 1: Kategori "Tagihan" menggantikan "Tagihan PLN"

**Files:**
- Create: `priv/repo/migrations/20261023100000_tagihan_category_and_months.exs`
- Modify: `lib/zahlungs/services/product.ex`, `lib/zahlungs/services/inquiry.ex`, `lib/zahlungs/services.ex` (`@category_labels`, `checkable/1`, `bill_details/4`, `note_vendor_price/2`), `lib/zahlungs/services/provider/sbi.ex` (`category_hint/2`, moduledoc), `lib/zahlungs_web/live/service_product_live/index.ex`, `lib/zahlungs_web/live/service_live/index.ex`, `lib/zahlungs_web/controllers/service_receipt_html/show.html.heex`, `test/support/fixtures/services_fixtures.ex`, dan test yang menyebut `"tagihan_pln"` / `"lembar"`
- Test: `test/zahlungs/services_test.exs`, `test/zahlungs/services_catalog_test.exs`, `test/zahlungs_web/controllers/service_receipt_controller_test.exs`

**Interfaces:**
- Produces:
  - Migrasi: `service_products.ask_months` boolean default false not null; `service_inquiries.months` integer null; `execute("UPDATE service_products SET category = 'tagihan' WHERE category = 'tagihan_pln'", "UPDATE service_products SET category = 'tagihan_pln' WHERE category = 'tagihan'")` dan sama untuk `service_transactions`.
  - `Product.categories/0` → `~w(pulsa paket_data token_pln tagihan)`; `Product.bill?/1` benar untuk `"tagihan"`; `ask_months` di-cast. `Services.categories/0` → `{"tagihan", "Tagihan"}` menggantikan `{"tagihan_pln", "Tagihan PLN"}`.
  - `Inquiry` field `months :integer`.
  - Katalog SBI: setiap item grup `"PPOB"` → `category_hint: "tagihan"`.
  - "lembar" → "bulan" di kartu tagihan layar Layanan, label biaya tambahan di form produk, dan struk.

- [ ] **Step 1: Tulis test yang gagal**:
  - `Services.create_product(%{name: "X", category: "tagihan_pln", cost: "0"})` → error di `:category`; `category: "tagihan"` → ok dan `Product.bill?/1` benar; `ask_months: true` tersimpan.
  - laporan: transaksi tagihan (fixture `tagihan`) muncul dengan `category: "tagihan"` di `report/3`.
  - katalog: daftar contoh dengan grup `"PPOB"` berisi `BPJSKS`, `PDAMSLTG`, `TELKOM`, `PGN`, `PLN` → semuanya `category_hint: "tagihan"`.
  - struk tagihan 3 bulan memuat `"3 bulan"` dan tidak memuat `"lembar"`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_test.exs test/zahlungs/services_catalog_test.exs test/zahlungs_web/controllers/service_receipt_controller_test.exs` → gagal.
- [ ] **Step 3: Implementasi** migrasi, schema, dan penggantian `"tagihan_pln"` → `"tagihan"` di semua kode dan test (`grep -rn tagihan_pln lib test` harus kosong setelahnya); "lembar" → "bulan".
- [ ] **Step 4: Jalankan** test → lulus; `mix test` → lulus. Periksa di database dev: `mix ecto.migrations` menunjukkan migrasi `up`; tidak ada baris `tagihan_pln` di `service_products`/`service_transactions` (skrip baca-saja); `mix ecto.rollback --step 1` mengembalikannya, lalu `mix ecto.migrate` lagi.
- [ ] **Step 5: Commit** `feat(layanan-tagihan): one Tagihan category for every bill`.

### Task 2: Jumlah bulan di inquiry dan pencatatan

**Files:**
- Modify: `lib/zahlungs/services.ex` (`inquire/4`, `ask_provider/3`, `provider_request/1`), `lib/zahlungs/services/inquiry.ex` (`answer_changeset/2`), `lib/zahlungs/services/provider.ex` (doc permintaan), `lib/zahlungs/services/provider/sbi/reply.ex` (`months/1` → nil bila tak ada `Jml bulan:`)
- Test: `test/zahlungs/services_api_test.exs`, `test/zahlungs/services/provider/sbi_reply_test.exs`

**Interfaces:**
- Consumes: Task 1 `ask_months`, `Inquiry.months`.
- Produces:
  - `Services.inquire(user, product_id, customer_ref, opts \\ []) :: {:ok, Inquiry.t()} | {:error, reason}` — `opts[:months]` (integer atau string). Produk `ask_months`: `nil`/`""` → 1; bilangan 1–12 (string boleh) → itu; selain itu `{:error, :invalid_months}` sebelum memanggil penyedia. Produk tanpa `ask_months`: diabaikan, `months` nil.
  - Permintaan inquiry ke adapter menambah `months: pos_integer | nil`.
  - `answer_changeset/2`: `sheets` = `answer.sheets` bila jawaban menyebut jumlah bulan; adapter yang tidak tahu mengembalikan `sheets: nil` → `sheets` = `months || 1`. (SBI `Reply.inquiry/2` mengembalikan `sheets: nil` bila tidak ada `Jml bulan:` — ubah default dari 1 ke nil; Fake tetap mengisi sheets.)
  - `provider_request/1` menambah `months` dari inquiry kind `"bill"` (nil bila tidak ada).

- [ ] **Step 1: Tulis test yang gagal** (akun SBI + `StubClient`, produk `api_product_fixture(%{ask_months: true, provider_code: "BPJSKS", api_extra_fee: "1000"})`):
  - `inquire(cashier, bpjs.id, "8888803136606896", months: "3")` → `inquiry.months == 3` (bahwa SBI menerima `periode` diuji di Task 3).
  - `Reply.inquiry/2` dengan `msg` tanpa `Jml bulan:` → `sheets: nil`; dengan `Jml bulan:2` → 2 (`sbi_reply_test.exs`).
  - jawaban SBI tanpa `Jml bulan` (`total_payment: "570000"`) → `sheets == 3`, `inquiry_price(inquiry).price == 573000`.
  - jawaban dengan `"msg" => "... Jml bulan:2/..."` dan `months: "3"` → `sheets == 2` (Review Focus 3).
  - `months: "0"`, `"13"`, `"abc"` → `{:error, :invalid_months}`, `StubClient.requests() == []` (Review Focus 2); `months: ""` → 1.
  - produk tanpa `ask_months` dengan `months: "3"` → `inquiry.months == nil`.
  - `record/3` dengan `"months" => "6"` di attrs tidak mengubah harga dari inquiry (Review Focus 1); `provider_request(tx).months == 3`.
  - akun manual: produk `ask_months` direkam dengan `bill_amount` diketik, `sheets 1` (Review Focus 4).
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_api_test.exs test/zahlungs/services/provider/sbi_reply_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-tagihan): bills can ask how many months, and pay what was checked`.

### Task 3: SBI mengirim `periode`

**Files:**
- Modify: `lib/zahlungs/services/provider/sbi.ex` (`inquiry/2`, `pay/2`)
- Test: `test/zahlungs/services/provider/sbi_test.exs`, `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Consumes: Task 2 `months` di permintaan inquiry dan bayar.
- Produces: body `inquiry` dan `payment` menyertakan `"periode" => Integer.to_string(months)` bila `months` ada; `topup` tidak pernah. `sign` tidak berubah.

- [ ] **Step 1: Tulis test yang gagal**: inquiry `%{kind: :bill, months: 3, ...}` → body `"periode" => "3"`; tanpa `months` → tidak ada kunci `"periode"`; `pay` dengan `inquiry_ref` dan `months: 3` → action `"payment"` berisi `"periode" => "3"`; `sign` sama dengan tanpa periode. Di `services_api_test.exs`: inquiry BPJS `months: "3"` → `StubClient.requests()` berisi `"periode" => "3"`, dan bayarnya juga.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services/provider/sbi_test.exs test/zahlungs/services_api_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-tagihan): SBI gets the months as periode`.

### Task 4: Layar — pilihan jumlah bulan dan centang di form produk

**Files:**
- Modify: `lib/zahlungs_web/live/service_live/index.ex` (form Cek tagihan, `"inquire"`, `drop_stale_inquiry/1`, `@blank_form`, `error_message(:invalid_months)`), `lib/zahlungs_web/live/service_product_live/index.ex`
- Test: `test/zahlungs_web/live/service_live_test.exs`, `test/zahlungs_web/live/service_product_live_test.exs`

**Interfaces:**
- Consumes: Task 2 `inquire/4`, `Inquiry.months`; Task 1 `ask_months`.
- Produces: `@blank_form` menambah `"months" => "1"`; form Cek tagihan menampilkan `<select name="service[months]">` 1–12 ("Jumlah bulan") hanya bila produk `ask_months`; `"inquire"` meneruskan `months: form["months"]`; `drop_stale_inquiry/1` juga membuang hasil cek bila `form["months"]` berbeda dari `inquiry.months` (untuk inquiry dengan `months`); kartu: "N bulan"; `error_message(:invalid_months)` → "Jumlah bulan harus 1–12."; form produk kategori Tagihan: `<.input field={@form[:ask_months]} type="checkbox" label="Tanyakan jumlah bulan saat cek tagihan" />`.

- [ ] **Step 1: Tulis test yang gagal**: produk `ask_months` → html memuat "Jumlah bulan" dan `name="service[months]"`; produk tagihan biasa → tidak; `inquire` dengan `"months" => "3"` → kartu "3 bulan"; `change` dengan `"months" => "2"` setelah cek → `assigns.inquiry == nil` (Review Focus 1); form produk Tagihan menampilkan dan menyimpan "Tanyakan jumlah bulan saat cek tagihan"; kategori lain tidak menampilkannya.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/live/service_live_test.exs test/zahlungs_web/live/service_product_live_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-tagihan): the cashier picks the months for a bill that asks`.

### Task 5: Dokumentasi dan pemeriksaan di browser

**Files:**
- Modify: `CLAUDE.md` (kategori `tagihan`, `ask_months`, `months`/`periode`), `docs/IA.md` (tab Tagihan, jumlah bulan, centang di form produk)

- [ ] **Step 1: Tulis dokumentasi.**
- [ ] **Step 2: Jalankan** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, `mix test` → bersih.
- [ ] **Step 3: Periksa di browser** (dev server, akun "API Uji" penyedia tiruan): tab "Tagihan" menampilkan "Tagihan PLN (uji API)" hasil migrasi, Cek tagihan → "N bulan"; form produk kategori Tagihan menampilkan centang jumlah bulan. Data uji baru **hanya dengan izin**.
- [ ] **Step 4: Commit** `docs(layanan-tagihan): one Tagihan category and the months`.
