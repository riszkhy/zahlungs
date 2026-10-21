# Layanan PPOB — adapter SBI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zahlungs menjual pulsa, paket data, token PLN dan tagihan PLN lewat Smart Biller Indonesia (SBI) sungguhan, dengan salinan lengkap di setiap transaksi, katalog dari SBI, dan peninjauan untuk jawaban SBI yang bertentangan.

**Architecture:** `Provider.Sbi` mengimplementasikan behaviour Fase 1 (`Zahlungs.Services.Provider`) di atas `Sbi.Client` (`:httpc`, bisa diganti di test), `Sbi.Sign` dan `Sbi.Reply`. Hasil adapter diperkaya dengan kunci opsional (`actual_cost`, `payload`, status `:refunded`); `Services.apply_result/2` tetap satu-satunya jalan ke hasil dan kini menandai **Perlu ditinjau** untuk jawaban yang bertentangan. Callback tanpa token dikenali dari `ref_1`.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MyXQL, `:httpc` + `:public_key` (OTP 27), ETS. Tanpa dependensi baru.

**Spec:** `docs/superpowers/specs/2026-10-21-layanan-ppob-sbi-design.md` (di atas spec Fase 1 `2026-10-19-layanan-ppob-fase-1-design.md`)

## Global Constraints

- Branch `feat/layanan-ppob-sbi`, dibuat dari `feat/layanan-ppob-fase-1`. Commit: `type(layanan-ppob-sbi): subjek`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tidak ada dependensi baru. HTTP lewat `:httpc`; TLS dengan `cacerts: :public_key.cacerts_get()`, `verify: :verify_peer`, `customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]`.
- **Test tidak pernah memanggil SBI.** `config/test.exs` memakai client tiruan; daftar harga tidak diunduh di test.
- **Timeout, putus koneksi, HTTP 5xx, atau isi bukan JSON saat `pay`/`status` = pending, bukan gagal.**
- Kredensial tidak pernah dikirim ke browser, ditulis ke log, atau disimpan di `provider_payload`.
- LiveView dan controller hanya memanggil fungsi konteks. Uang `Decimal`, kolom `decimal(15, 2)`.
- Proses tanpa user (Dispatcher, StatusChecker, callback) memasuki organisasi dari toko transaksi (`enter_store_organization/1` yang sudah ada).
- Alur akun manual tetap persis Fase 0; test Fase 0 dan Fase 1 tetap lulus (fixture tagihan API boleh disesuaikan dengan aturan harga baru, Task 2).
- Teks UI berbahasa Indonesia; handler menerima id integer maupun string.
- Setiap task selesai bila `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, dan `mix test` bersih.

## Keputusan di luar spec (dicatat di sini, bukan rahasia)

- `service_transactions.customer_details` (string ≤ 120) menampung tarif/daya dari cek pelanggan token PLN — spec meminta "nama pelanggan dan detail disalin ke transaksi" tetapi tidak menyebut kolomnya.
- Permintaan inquiry ke adapter membawa `kind: :bill | :customer`; adapter yang memilih kode vendor (SBI: kode produk untuk `:bill`, `"CPLNPRA"` untuk `:customer`).
- `Provider.options/0` menurunkan pilihan dari adapter yang terdaftar: `[{"Smart Biller Indonesia (SBI)", "sbi"}, {"Penyedia tiruan (uji coba)", "fake"}]` disaring ke kunci di `adapters/0`. `config/prod.exs` mendaftarkan hanya `%{"sbi" => Provider.Sbi}`; dev memakai keduanya.
- Client hanya menerima `base_url` berawalan `https://`, kecuali `allow_http: true` di config (hanya `config/test.exs`, untuk test client terhadap server lokal).
- Client tiruan `Zahlungs.Services.Provider.Sbi.StubClient` (test/support) menyimpan jawaban per proses test di ETS, dicari dari `self()` lalu `Process.get(:"$callers")`, sehingga jawaban terlihat dari `Task.async` di `inquire/3`.

## Review Focus

1. **Callback SBI berhasil, lalu jawaban `pay` yang terlambat juga berhasil**: transaksi tetap berhasil dan **tidak** ditandai Perlu ditinjau (jawaban sama dengan status final diabaikan) → test di Task 3.
2. **Cek status menjawab `status: 2` (pending) untuk transaksi yang sudah final**: diabaikan, tanpa Perlu ditinjau → test di Task 3.
3. **Angka SBI dalam bentuk campur** (`"302750"`, `302750`, `-283695`, `""`, `null`): dibaca benar atau dianggap tidak ada, tanpa crash; saldo negatif tetap tampil → test di Task 5.
4. **`status: 1` tanpa `SN:` di `msg`** (atau `SN:` kosong): berhasil dengan `token_sn` kosong, tidak crash dan tidak pending → test di Task 5.
5. **Callback tanpa token dengan `ref_1` milik transaksi manual, ref inquiry (`Q…`) yang belum menjadi transaksi, atau `ref_1` kosong**: 404 tanpa crash, tidak ada yang berubah → test di Task 8.

---

### Task 1: Kolom baru dan format ref

**Files:**
- Create: `priv/repo/migrations/20261021090000_add_sbi_fields_to_services.exs`, `lib/zahlungs/services/ref.ex`
- Modify: `lib/zahlungs/services/inquiry.ex`, `lib/zahlungs/services/product.ex`, `lib/zahlungs/services/transaction.ex`
- Test: `test/zahlungs/services/ref_test.exs`, `test/zahlungs/services_test.exs`

**Interfaces:**
- Produces:
  - Kolom (satu migrasi): `service_inquiries`: `ref_id` string(32) unik, `provider_admin` decimal(15,2), `provider_total` decimal(15,2), `details` string(120), `kind` string(16) default `"bill"`. `service_products`: `api_extra_fee` decimal(15,2) default 0 not null, `provider_price` decimal(15,2), `provider_status` string(20), `provider_checked_at` naive_datetime. `service_transactions`: `provider_code` string(60), `quoted_cost` decimal(15,2), `provider_payload` text, `customer_details` string(120), `review_reason` string(255), `reviewed_at` naive_datetime, `reviewed_by_id` references users.
  - `Zahlungs.Services.Ref.generate(prefix :: "Z" | "Q", store_id :: pos_integer, now \\ NaiveDateTime.utc_now()) :: String.t()` → `prefix <> "#{store_id}" <> yymmddHHMMSS <> 6 hex kapital` (≤ 26 karakter).
  - `Product.changeset/2` meng-cast `api_extra_fee` (≥ 0); `Product.provider_statuses/0` → `~w(normal gangguan kosong tidak_ditemukan)`.
  - `Inquiry.kinds/0` → `~w(bill customer)`.

- [ ] **Step 1: Tulis test yang gagal**: `Ref.generate("Z", 12, ~N[2026-10-21 15:30:00])` cocok `~r/^Z12261021153000[0-9A-F]{6}$/`; dua panggilan berbeda; `Ref.generate("Q", 123_456, ...)` ≤ 26 karakter. `Services.create_product(%{... "api_extra_fee" => "-1"})` → error di `:api_extra_fee`; `"2500"` tersimpan.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services/ref_test.exs test/zahlungs/services_test.exs` → gagal.
- [ ] **Step 3: Implementasi** migrasi, field schema, `Ref.generate/3` (`:crypto.strong_rand_bytes(3) |> Base.encode16()`).
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): columns for vendor copies, reviews and refs`.

### Task 2: Ref inquiry dipakai ulang, salinan kode vendor, harga tagihan baru

**Files:**
- Modify: `lib/zahlungs/services.ex` (`inquire/3`, `inquiry_price/1`, `ask_provider/3`, `insert_transaction/3`, `bill_details/4`, `provider_request/1`), `lib/zahlungs/services/inquiry.ex` (`answer_changeset/2`), `lib/zahlungs/services/provider.ex` (typespec), `lib/zahlungs/services/provider/fake.ex`, `test/support/fixtures/services_fixtures.ex`
- Test: `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Consumes: Task 1 kolom dan `Ref.generate/3`.
- Produces:
  - Permintaan inquiry ke adapter: `%{ref_id, product_code, customer_ref, kind: :bill | :customer}`. Jawaban ok menambah `provider_admin`, `provider_total`, `details` (boleh `nil`); `bill_amount` boleh `nil` untuk `:customer`.
  - `inquire/3` menyimpan `ref_id` (`Ref.generate("Q", store.id)`), `provider_admin`, `provider_total`, `details`, `kind`.
  - `record/3`: transaksi API mendapat `ref_id` = `Ref.generate("Z", store.id)`, kecuali tagihan dari inquiry → `inquiry.ref_id`; transaksi manual tetap `ref_id = code`. `provider_code` disalin dari produk; `quoted_cost` = `cost` saat dicatat.
  - Tagihan API: `inquiry_price/1` → `%{price: provider_total + api_extra_fee × sheets, cost: provider_total}`. `price_for/3` (manual) tidak berubah.
  - `provider_request/1` membaca `product_code` dari `transaction.provider_code`.
  - Fake: inquiry `:bill` menambah `provider_admin: Decimal.new(0)`, `provider_total: bill_amount`, `details: nil`.
  - `api_product_fixture/1` menambah `api_extra_fee: "3000"` (harga 3 lembar tetap `Rp 744.000`; modal kini 735000).

- [ ] **Step 1: Tulis test yang gagal** di `services_api_test.exs`:
  - "the bill is paid with the inquiry's ref": `{:ok, inq} = inquire(...)`; `inq.ref_id =~ ~r/^Q/`; `{:ok, tx} = record(... "inquiry_id" => inq.id)`; `tx.ref_id == inq.ref_id`; Fake menerima `{:fake_provider, :pay, ^ref}` dengan ref itu.
  - "a bill costs the provider's total plus the shop's fee per sheet": produk `api_extra_fee: "2000"`, 3 lembar → `price` 741000, `cost` 735000, `quoted_cost` 735000.
  - "the vendor code is copied and used": catat pulsa (`provider_code: "TSEL10"`), ubah produk ke `"TSEL20"`, `check_status` → `provider_request(tx).product_code == "TSEL10"`; `tx.provider_code == "TSEL10"`.
  - "api refs are unique across organizations": `tx.ref_id =~ ~r/^Z#{store.id}/`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_api_test.exs` → gagal.
- [ ] **Step 3: Implementasi** sesuai Interfaces; perbarui test Fase 1 yang menyebut modal tagihan lama.
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): bills reuse the inquiry's ref; vendor code and quoted cost are copied`.

### Task 3: Modal sebenarnya, jawaban mentah, dan Perlu ditinjau

**Files:**
- Modify: `lib/zahlungs/services.ex` (`apply_result/2`, `result_changes/2`, baru `resolve_review/3`, `list_in_review/1`), `lib/zahlungs/services/provider.ex` (typespec `result`)
- Test: `test/zahlungs/services_review_test.exs`

**Interfaces:**
- Consumes: Task 1 kolom; Task 2 `quoted_cost`.
- Produces:
  - `result` boleh membawa `actual_cost :: Decimal.t()`, `payload :: String.t()`; status baru `:refunded` (`%{status: :refunded, message}`).
  - `apply_result/2`:
    - `processing` + success/failed/pending → seperti Fase 1, plus `cost` ← `actual_cost` bila ada, `provider_payload` ← `payload` (dipotong 4.000) bila ada; `processing` + `:refunded` → failed.
    - `success` + `:refunded` → status tetap, `review_reason: "SBI melaporkan refund: <message>"`; `failed` + `:success` → status tetap, `review_reason: "SBI melaporkan berhasil setelah transaksi gagal"`; keduanya disiarkan dan mengembalikan `{:ok, transaction}`.
    - Jawaban yang sama dengan status final, atau `:pending` pada status final → `{:ok, :already_final}` tanpa perubahan.
    - Bila `actual_cost` > `cost` produk: `provider_price` produk ← `actual_cost`.
  - `Services.resolve_review(transaction, %User{role: "admin"} = admin, :refund | :keep) :: {:ok, Transaction.t()} | {:error, :forbidden | :not_in_review}` — mengunci baris; `:refund` hanya untuk `success` (selain itu `:not_in_review`) → `status: "failed"`, `failure_reason: review_reason`; `:keep` → `review_reason: nil`; keduanya `reviewed_at`, `reviewed_by_id`; disiarkan.
  - `Services.list_in_review(%Deposits.Account{}) :: [Transaction.t()]` — transaksi akun itu dengan `review_reason` terisi, terbaru dulu.

- [ ] **Step 1: Tulis test yang gagal** (`services_review_test.exs`, akun tiruan, `apply_result/2` dipanggil langsung):
  - actual cost: `apply_result(id, %{status: :success, token_sn: "SN1", provider_ref: "R", actual_cost: Decimal.new("10500"), payload: "{...}"})` → `cost` 10500, `quoted_cost` tetap, `provider_payload == "{...}"`, `Services.deposit_used(account)` memakai 10500.
  - Review Focus 1: success lalu success lagi → `{:ok, :already_final}`, `review_reason` nil.
  - Review Focus 2: success lalu `%{status: :pending}` → `{:ok, :already_final}`, `review_reason` nil.
  - refund setelah success → status `"success"`, `review_reason =~ "refund"`, `list_in_review(account)` berisi tx; `:refunded` pada processing → `"failed"`.
  - success setelah failed → status `"failed"`, `review_reason =~ "berhasil setelah"`.
  - `resolve_review(tx, cashier, :keep)` → `{:error, :forbidden}`; admin `:keep` → `review_reason` nil, `reviewed_by_id == admin.id`; `:keep` lagi → `{:error, :not_in_review}`.
  - `:refund` di shift terbuka → `"failed"`, muncul di `list_refunds_due/1`, `Shifts.expected_cash(shift)` tetap menghitung harga sampai `confirm_refund/2`; setelah shift ditutup lalu `confirm_refund` dari shift baru → kas keluar `refund` di shift baru, shift lama tetap menghitungnya (aturan Fase 1).
  - `actual_cost` 10500 > produk `cost` 10150 → `provider_price` produk 10500.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_review_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): actual costs, raw answers and reviews for conflicting answers`.

### Task 4: Token PLN wajib cek pelanggan; produk bermasalah ditolak

**Files:**
- Modify: `lib/zahlungs/services.ex` (`inquire/3`, `bill_with_code/1`, `bill_details/4`, `sellable_through/2`), `lib/zahlungs/services/inquiry.ex`, `lib/zahlungs/services/provider/fake.ex`
- Test: `test/zahlungs/services_api_test.exs`

**Interfaces:**
- Consumes: Task 2 permintaan inquiry dengan `kind`.
- Produces:
  - `inquire/3` menerima produk `tagihan_pln` (kind `"bill"`) dan `token_pln` (kind `"customer"`); kategori lain → `{:error, :product_unavailable}`. `Inquiry.answer_changeset/2` mewajibkan `bill_amount > 0` hanya untuk `"bill"`.
  - Fake `:customer`: `{:ok, %{customer_name: "PELANGGAN " <> 4 digit terakhir, details: "R1/900VA", period: nil, sheets: 1, bill_amount: nil, provider_admin: nil, provider_total: nil, inquiry_ref: "CUS-" <> number}}`; digit 6 → `:not_found`, 7 → `:unavailable`.
  - `record/3` untuk `token_pln` di akun API: butuh `"inquiry_id"` kind `"customer"` yang berlaku, belum dipakai, produk dan toko sama, kalau tidak `{:error, :inquiry_expired}`; `customer_ref`, `customer_name`, `customer_details` dari inquiry; `ref_id` transaksi **bukan** ref inquiry; harga = `price_for/3` biasa.
  - `sellable_through("api", product)`: `provider_status` terisi dan bukan `"normal"` → `{:error, :product_unavailable}`.

- [ ] **Step 1: Tulis test yang gagal**: token tanpa `inquiry_id` → `:inquiry_expired`; dengan inquiry customer → transaksi `customer_name == "PELANGGAN 4441"`, `customer_details == "R1/900VA"`, `ref_id != inquiry.ref_id`; inquiry dipakai dua kali → `:inquiry_expired`; inquiry pulsa → `:product_unavailable`; produk `provider_status: "gangguan"` → `record` `{:error, :product_unavailable}`, `provider_status: nil` → boleh; akun manual tetap tanpa cek.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_api_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): token PLN is checked with the provider first`.

### Task 5: `Sbi.Sign` dan `Sbi.Reply`

**Files:**
- Create: `lib/zahlungs/services/provider/sbi/sign.ex`, `lib/zahlungs/services/provider/sbi/reply.ex`
- Test: `test/zahlungs/services/provider/sbi_reply_test.exs`

**Interfaces:**
- Produces:
  - `Sbi.Sign.sign(mmid, product_code, customer_id, ref_1, pin, password) :: String.t()` (nil → `""`).
  - `Sbi.Reply.transaction(map) :: {:ok, Provider.result()} | {:error, :not_found}` — `map` adalah objek `data` jawaban atau isi callback. Pemetaan persis tabel "Bayar, topup, status, callback" di spec; `actual_cost` dari `total_payment` (atau `HRG:` di `msg`); `token_sn` dari `msg` `SN:` sampai sebelum ` REFID`/akhir (dipangkas, kosong → nil); `provider_ref` = `ref_2`; `message` dari `KET:` atau `msg`; `payload` = `Jason.encode!(map)` dipotong 4.000. RC 91/92/93/95 → `message: "Periksa kredensial / IP server di SBI"`.
  - `Sbi.Reply.envelope(http_status, body) :: {:data, map} | {:rc, String.t(), String.t()} | :unknown` — `{:data, ...}` bila `body["data"]` objek; `{:rc, kode, pesan}` dari `RC:<kode>` di `message`/`msg`; selain itu `:unknown`.
  - `Sbi.Reply.inquiry(map, kind) :: {:ok, answer} | {:error, reason}` — pemetaan tabel inquiry spec. Tagihan: `customer_name` dari `detail.data_1` (dipangkas) atau `Nama:` di `msg`; `sheets` dari `Jml bulan:` (default 1); `period` dari `Blth:` (default nil); `bill_amount` = `price`; `provider_admin` = `admin`; `provider_total` = `total_payment`; `inquiry_ref` = `ref_2`; `details` = `detail.data_2` dipangkas.
  - `Sbi.Reply.money(value) :: Decimal.t() | nil` — menerima string angka, integer, float; `""`/nil/selain angka → nil.

- [ ] **Step 1: Tulis test yang gagal**:
  - `Sign.sign("MM123", "T1", "089652137194", "Z1261021153000A1B2C3", "1234", "rahasia") == "8GaWqL-wPFtQPzwk3naUFgFV52M"`; `Sign.sign("MM123", nil, nil, nil, "1234", "rahasia") == "I7rFuxRBQUEMuHpUZPouA2dU1VY"`.
  - Contoh topup Postman (`status: 1`, `msg: "TRX T1.089652137194 SUKSES, HRG:2000 SN:7867867686876 REFID:13896521371941."`) → success, `token_sn == "7867867686876"`, `actual_cost == 2000`, `provider_ref == "2406070150146356"`.
  - `status: 2` → pending; `status: 11`, `msg: "GAGAL, RC:14. TRX TP15.082236929165 KET:Nomor tujuan salah. ..."` → failed `"Nomor tujuan salah."`.
  - `envelope/2`: `{:rc, "94", _}`, `{:rc, "08", _}`, RC tak dikenal → dipetakan pending oleh `Sbi` (Task 6); di sini cukup `envelope` mengenali kodenya.
  - `msg` berisi `RC:31` → `:refunded`.
  - Review Focus 3: `money("302750")`, `money(302750)`, `money(-283695)` → Decimal; `money("")`, `money(nil)`, `money("abc")` → nil.
  - Review Focus 4: `status: 1`, `msg` tanpa `SN:` → success, `token_sn == nil`; `"SN: REFID:x"` → nil.
  - Inquiry PLN Postman → nama `"Anto"`, `bill_amount` 300000, `provider_admin` 2750, `provider_total` 302750, `sheets` 1; `msg` PDF `"... Jml bulan:2/Blth:JUL 24, AGU 24/..."` → `sheets` 2, `period == "JUL 24, AGU 24"`.
  - Inquiry gagal: RC 14 → `:not_found`; 88 → `:already_paid`; 83 → `{:rejected, "Tagihan belum tersedia."}`; 16 → `{:rejected, "Nomor meter diblokir."}`; 84 → `:unavailable`; 30 → `{:rejected, keterangan}`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services/provider/sbi_reply_test.exs` → gagal.
- [ ] **Step 3: Implementasi** (fungsi murni, tanpa jaringan dan database).
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): sign requests and read SBI's answers`.

### Task 6: Adapter `Provider.Sbi` dengan client tiruan

**Files:**
- Create: `lib/zahlungs/services/provider/sbi.ex`, `test/support/sbi_stub_client.ex`
- Modify: `lib/zahlungs/services/provider.ex` (callback opsional, `options/0`), `config/config.exs`, `config/test.exs`, `config/prod.exs`
- Test: `test/zahlungs/services/provider/sbi_test.exs`

**Interfaces:**
- Consumes: Task 5 `Sign`, `Reply`.
- Produces:
  - Behaviour: `@optional_callbacks balance: 1, catalog: 1, prices: 2, callback_ref: 1`; `@callback catalog(config :: keyword) :: {:ok, [catalog_item]} | {:error, term}`; `@callback prices(credentials, [String.t()]) :: {:ok, %{String.t() => %{price: Decimal.t() | nil, status: String.t()}}} | {:error, term}`; `@callback callback_ref(params :: map) :: {:ok, String.t()} | :error`.
  - Client contract (Task 7 mewujudkannya): `post(action :: String.t(), body :: map, headers :: [{String.t(), String.t()}], timeout_ms) :: {:ok, http_status, map | String.t()} | {:error, :timeout | :network}`; `get_json(url, timeout_ms)` sama bentuknya.
  - `Provider.Sbi`: `credential_fields/0` → `[{"member_id", "Member ID"}, {"pin", "PIN"}, {"password", "Password"}]`; `inquiry/2` (`"inquiry"`, kode `"CPLNPRA"` untuk `:customer`, 15 s); `pay/2` (`"payment"` bila `inquiry_ref` ada, selain itu `"topup"`, 45 s); `status/2` (`"status"`, 15 s); `ping/1` (`balance` ok → `:ok`, selain itu `{:error, pesan}`); `balance/1` (`data.saldo`); `prices/2` (`"price"` per kode, `Task.async_stream` `max_concurrency: 5`; `data.gangguan == "Ya"` → `"gangguan"`, `kosong == "Ya"` → `"kosong"`, RC 97/89 → `"tidak_ditemukan"`, selain itu `"normal"`); `catalog/1` (`Task 9`); `callback_ref/1` (`params["ref_1"]` string tak kosong); `verify_callback/3` (Task 8).
  - Body setiap permintaan: `mmid`, `ref_1`, `product_code`, `customer_id`, plus `ref_2` untuk `payment`; header `{"sign", Sign.sign(...)}` dan `{"content-type", "application/json"}`. `status`/`balance` memakai string kosong untuk field yang tidak ada (asumsi spec).
  - Pemetaan jawaban: `{:error, :timeout | :network}`, HTTP ≥ 500, `:unknown` → `{:error, :timeout}` untuk `pay`/`status`; `{:rc, "94" | "08" | tak dikenal}` → `{:ok, %{status: :pending, ...}}`; `{:rc, gagal-pasti}` → failed; `{:data, map}` → `Reply.transaction/1`.
  - Config: `config :zahlungs, Zahlungs.Services.Provider.Sbi, base_url: "https://apisbi.mesinr1.com/V1", client: Zahlungs.Services.Provider.Sbi.Client, callback_ips: ["183.91.82.154"], pricelist_url: "https://api.billerindonesia.com/V1/ppob/h2h_umum/pricelist"`; test: `client: Zahlungs.Services.Provider.Sbi.StubClient`, `allow_http: true`; `:provider_adapters` test: `fake`, `broken`, `sbi`; prod: hanya `sbi`.
  - `StubClient.expect(action, {:ok, status, body} | {:error, reason})` (antrean per proses test) dan `StubClient.requests()` (daftar `{action, body, headers}` yang dikirim). `StubClient.get_json/2` memakai action `"pricelist"`.

- [ ] **Step 1: Tulis test yang gagal** (`sbi_test.exs`, async):
  - topup berhasil → `{:ok, %{status: :success, token_sn: "7867867686876"}}`; `StubClient.requests()` berisi `{"topup", %{"mmid" => "MM123", "ref_1" => ref, ...}, headers}` dengan `sign` = `Sign.sign/6` dari kredensial.
  - payment memakai `ref_2` dari `inquiry_ref` dan action `"payment"`; token `:customer` memakai `product_code: "CPLNPRA"`.
  - `{:error, :timeout}`, HTTP 500, body `"<html>"` → `{:error, :timeout}`; `RC:94` dan `RC:08` → pending; `RC:96` → failed; RC:91 → failed pesan `"Periksa kredensial / IP server di SBI"`.
  - `balance/1` → `{:ok, Decimal.new("-283695")}`; `ping/1` dengan `RC:93` → `{:error, _}`.
  - `prices/2` untuk tiga kode → status `"normal"`, `"gangguan"`, `"tidak_ditemukan"`.
  - `Provider.options()` di test berisi `{"Smart Biller Indonesia (SBI)", "sbi"}`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services/provider/sbi_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): the SBI adapter`.

### Task 7: `Sbi.Client` sungguhan lewat `:httpc`

**Files:**
- Create: `lib/zahlungs/services/provider/sbi/client.ex`
- Modify: `mix.exs` (`extra_applications: [:logger, :runtime_tools, :inets, :ssl]`)
- Test: `test/zahlungs/services/provider/sbi_client_test.exs`

**Interfaces:**
- Consumes: kontrak client Task 6.
- Produces: `Sbi.Client.post/4`, `Sbi.Client.get_json/2` dengan `:httpc.request(:post, {url, headers, ~c"application/json", json}, [timeout: t, connect_timeout: 10_000, ssl: tls_opts], body_format: :binary)`. Body JSON dibaca dengan `Jason.decode/1`; gagal decode → `{:ok, status, raw_string}`. `{:error, :timeout}` untuk timeout `:httpc`; error lain → `{:error, :network}`. `base_url` bukan `https://` tanpa `allow_http` → `raise ArgumentError`.

- [ ] **Step 1: Tulis test yang gagal** dengan server lokal `Plug.Cowboy.http(TestPlug, [], port: 0)` (port dibaca dari `:ranch.get_port/1`): POST JSON kembali didecode dan header `sign` sampai; endpoint yang tidur 300 ms dengan timeout 100 → `{:error, :timeout}`; body bukan JSON → `{:ok, 200, "oke"}`; status 500 → `{:ok, 500, _}`; port tertutup → `{:error, :network}`; `base_url: "http://..."` dengan `allow_http: false` → `ArgumentError`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services/provider/sbi_client_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): an HTTPS client on :httpc`.

### Task 8: Callback tanpa token, IP pengirim, verifikasi SBI

**Files:**
- Modify: `lib/zahlungs_web/router.ex`, `lib/zahlungs_web/controllers/ppob_callback_controller.ex`, `lib/zahlungs/services.ex` (baru `handle_ref_callback/2`), `lib/zahlungs/services/provider/sbi.ex` (`verify_callback/3`), `config/runtime.exs` (`TRUSTED_PROXIES`)
- Create: `lib/zahlungs_web/client_ip.ex`
- Test: `test/zahlungs_web/controllers/ppob_callback_controller_test.exs`, `test/zahlungs/services/provider/sbi_test.exs`

**Interfaces:**
- Consumes: Task 6 `callback_ref/1`, `Reply.transaction/1`.
- Produces:
  - Route `post "/ppob/callback", PpobCallbackController, :create_by_ref` (di scope `/api` yang sama).
  - `ZahlungsWeb.ClientIp.of(conn) :: String.t()` — `conn.remote_ip`, kecuali alamat itu ada di `Application.get_env(:zahlungs, :trusted_proxies, [])` → alamat paling kanan di `x-forwarded-for` yang bukan proxy terpercaya. Controller menaruhnya di header `"x-zahlungs-client-ip"`, menimpa nilai dari luar (kedua route).
  - `Services.handle_ref_callback(params, headers) :: {:ok, :applied | :already_final} | {:error, :unknown_ref | :invalid_signature}` — untuk setiap adapter dengan `callback_ref/1`: ref → transaksi `channel: "api"` dengan `ref_id` itu (tanpa saringan organisasi; `service_transactions` tidak punya `organization_id`) → akun transaksi harus memakai adapter itu → `enter_store_organization/1` → `Deposits.connection/1` → `adapter.verify_callback/3` → `apply_result/2`.
  - `Sbi.verify_callback(credentials, params, headers)`: `Plug.Crypto.secure_compare(headers["rqid"] || "", credentials["password"] || "")` **dan** `headers["x-zahlungs-client-ip"] in callback_ips` → `{:ok, params["ref_1"], result}` (hasil dari `Reply.transaction/1`), selain itu `{:error, :invalid_signature}`.
  - `config/runtime.exs` (prod): `trusted_proxies` dari `TRUSTED_PROXIES` (dipisah koma), default `[]`.
  - Jawaban: 200 `{"ok": true}`, 401 `{"ok": false}`, 404 `{"ok": false}`.

- [ ] **Step 1: Tulis test yang gagal**:
  - `post(conn, "/api/ppob/callback", body)` dengan header `rqid` benar dan `remote_ip` `{183, 91, 82, 154}` → 200, transaksi berhasil, `token_sn` dari `msg`; ulangi → 200, tidak berubah.
  - `rqid` salah → 401; IP `{1, 2, 3, 4}` → 401; header `x-forwarded-for: 183.91.82.154` dari `remote_ip` yang bukan proxy terpercaya → 401; dengan `trusted_proxies` berisi `"127.0.0.1"` dan `remote_ip` 127.0.0.1 → 200 (test `async: false` untuk env ini).
  - Review Focus 5: `ref_1` milik transaksi manual, ref `Q…` milik inquiry, `ref_1` kosong/hilang → 404, tidak ada perubahan.
  - Transaksi di organisasi lain dengan password lain: `rqid` milik akun organisasi pertama → 401.
  - Route bertoken Fase 1 tetap lulus test lamanya.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/controllers/ppob_callback_controller_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): callbacks found by ref, checked by rqid and SBI's address`.

### Task 9: Katalog SBI dan pembaruan harga

**Files:**
- Create: `lib/zahlungs/services/catalog_cache.ex`
- Modify: `lib/zahlungs/services/provider/sbi.ex` (`catalog/1`), `lib/zahlungs/services.ex` (baru `search_catalog/2`, `catalog_account/0`, `price_update/1`, `apply_price_update/2`), `lib/zahlungs/application.ex`
- Test: `test/zahlungs/services_catalog_test.exs`

**Interfaces:**
- Consumes: Task 6 `catalog/1`, `prices/2`; Task 1 kolom produk.
- Produces:
  - `Sbi.catalog(config)` → `get_json(pricelist_url, 30_000)`; item `%{code, name, category_hint, price, admin, commission, status}`: `category_hint` `"pulsa"` (grup `"Pulsa Reguler"`), `"paket_data"` (grup berakhiran `"Data"`), `"token_pln"` (grup `"PLN Prabayar"`), `"tagihan_pln"` (grup `"PPOB"` dengan kode `"PLN"`), selain itu nil; `price` = `harga`; `admin` = `admin_amount`; `commission` = `komisi`; `status` `"gangguan"` bila `gangguan == "Ya"`, `"kosong"` bila `tersedia == "Tidak"`, selain itu `"normal"`.
  - `Zahlungs.Services.CatalogCache` — GenServer pemilik tabel ETS `:service_catalog`; `fetch(adapter_key, loader :: (-> {:ok, list} | {:error, term}), ttl_ms \\ 600_000)`. Didaftarkan di pohon supervisi sebelum Endpoint.
  - `Services.catalog_account() :: Deposits.Account.t() | nil` — akun deposit API aktif pertama di organisasi yang adapternya punya `catalog/1`.
  - `Services.search_catalog(account, query :: String.t()) :: {:ok, [item]} | {:error, :unavailable}` — cocok bila semua kata query (huruf kecil) ada di `name` atau `code`; maksimal 30 hasil.
  - `Services.price_update(account) :: {:ok, [%{product, old_cost, new_cost, new_price, status}]} | {:error, :unavailable}` — produk berkode vendor; tagihan hanya status.
  - `Services.apply_price_update(account, rows) :: {:ok, count}` — dalam satu transaksi: `cost` (bukan tagihan), `provider_price`, `provider_status`, `provider_checked_at`.

- [ ] **Step 1: Tulis test yang gagal**: katalog contoh (3 item dari daftar harga, lewat `StubClient.expect("pricelist", ...)`) → `search_catalog(account, "pln 20")` menemukan `PLN20` dengan `category_hint: "token_pln"`, `price` 20775; cache: panggilan kedua tidak meminta ulang (`StubClient.requests/0`); `price_update` produk `TSEL10` cost 10150 → `new_cost` 10300, `new_price` = 10300 + margin; produk `XX99` → `"tidak_ditemukan"`; `apply_price_update` menyimpan, lalu `record` produk `tidak_ditemukan` → `:product_unavailable`; tanpa akun API → `catalog_account() == nil`.
- [ ] **Step 2: Jalankan** `mix test test/zahlungs/services_catalog_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): pick products from SBI and refresh their prices`.

### Task 10: Admin — akun deposit SBI dan Perlu ditinjau

**Files:**
- Modify: `lib/zahlungs_web/live/deposit_live/index.ex`
- Test: `test/zahlungs_web/live/deposit_live_test.exs`

**Interfaces:**
- Consumes: Task 3 `list_in_review/1`, `resolve_review/3`; Task 6 `options/0`, `credential_fields/0`; Task 8 route tanpa token.
- Produces: URL callback = `url(~p"/api/ppob/callback")` bila adapter akun punya `callback_ref/1`, selain itu URL bertoken Fase 1. Halaman akun menampilkan bagian `id="in-review"` "Perlu ditinjau" dengan tombol `JS.push("resolve_review", value: %{transaction_id: id, decision: "refund" | "keep"})`; flash "Transaksi dibatalkan dan masuk Perlu dikembalikan." / "Transaksi tetap berhasil.".

- [ ] **Step 1: Tulis test yang gagal**: form mode API + penyedia `sbi` menampilkan "Member ID", "PIN", "Password"; setelah disimpan, edit tidak memuat nilai password dan menampilkan `/api/ppob/callback` tanpa token; akun SBI dengan transaksi dalam tinjauan → html memuat "Perlu ditinjau" dan alasan; `resolve_review` `"refund"` → flash, transaksi failed; `"keep"` dengan id string → flash; kasir tidak bisa membuka halaman ini (sudah dijaga route admin).
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/live/deposit_live_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): SBI deposit accounts and their reviews`.

### Task 11: Admin — pemilih produk SBI, biaya tambahan, Perbarui dari SBI

**Files:**
- Modify: `lib/zahlungs_web/live/service_product_live/index.ex`
- Test: `test/zahlungs_web/live/service_product_live_test.exs`

**Interfaces:**
- Consumes: Task 9 `catalog_account/0`, `search_catalog/2`, `price_update/1`, `apply_price_update/2`.
- Produces: event `"search_catalog"` (`%{"q" => q}`) menampilkan kode, nama, harga, status (tagihan: admin dan komisi SBI), `"pick_catalog"` (`%{"code" => code}`) mengisi `name`, `provider_code`, `cost` (bukan tagihan), `category` (bila `category_hint` ada); kolom form "Biaya tambahan toko (akun API)" untuk tagihan; tombol `"price_update"` menampilkan ringkasan `id="price-update"`, `"apply_price_update"` menyimpan (flash "<n> produk diperbarui."); daftar produk menampilkan "Gangguan", "Kosong", "Tidak ditemukan" dan "Modal SBI naik" (`provider_price > cost`).

- [ ] **Step 1: Tulis test yang gagal**: tanpa akun SBI tidak ada kotak "Cari di daftar SBI"; dengan akun SBI (stub katalog) → `search_catalog "pln 20"` menampilkan `PLN20`; `pick_catalog "PLN20"` → form berisi `provider_code` `PLN20`, kategori token PLN, modal 20775; tagihan menampilkan "Biaya tambahan toko (akun API)" dan menyimpannya; `price_update` → ringkasan memuat modal lama dan baru; `apply_price_update` → flash dan produk diperbarui; produk dengan `provider_price` lebih besar → "Modal SBI naik".
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/live/service_product_live_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): pick SBI products and refresh their prices`.

### Task 12: Layar kasir dan struk

**Files:**
- Modify: `lib/zahlungs_web/live/service_live/index.ex`, `lib/zahlungs_web/controllers/service_receipt_html/show.html.heex`
- Test: `test/zahlungs_web/live/service_live_test.exs`, `test/zahlungs_web/controllers/service_receipt_controller_test.exs`

**Interfaces:**
- Consumes: Task 2 `inquiry_price/1`; Task 4 inquiry `"customer"`; Task 3 `review_reason`.
- Produces: token PLN di akun API memakai form `phx-submit="inquire"` dengan tombol "Cek pelanggan" dan kartu `id="inquiry"` (nama, daya); event `inquire` yang sudah ada dipakai untuk keduanya. Kartu tagihan: "Tagihan", "Admin penyedia" (`provider_admin`), "Tambahan toko", "Total". Riwayat menampilkan "Perlu ditinjau — admin akan meninjau" bila `review_reason` terisi. Struk token: token dikelompokkan 4 digit (`group_digits/1`), nama, daya.

- [ ] **Step 1: Tulis test yang gagal**: akun tiruan API, produk token PLN → "Cek pelanggan" tampil, `phx-submit="record"` tidak ada sebelum cek; setelah `inquire` nomor `"14123344441"` → "PELANGGAN 4441", "R1/900VA", form bayar muncul; `record` → transaksi berhasil; tagihan 3 lembar dengan `api_extra_fee` 3000 → "Admin penyedia", "Tambahan toko", "Rp 744.000,00"; transaksi dengan `review_reason` → "Perlu ditinjau"; struk token memuat token berkelompok 4 digit dan "R1/900VA".
- [ ] **Step 2: Jalankan** `mix test test/zahlungs_web/live/service_live_test.exs test/zahlungs_web/controllers/service_receipt_controller_test.exs` → gagal.
- [ ] **Step 3: Implementasi.**
- [ ] **Step 4: Jalankan** → lulus; `mix test` → lulus.
- [ ] **Step 5: Commit** `feat(layanan-ppob-sbi): check the meter's owner before a token, and show the provider's fees`.

### Task 13: Dokumentasi dan pemeriksaan di browser

**Files:**
- Modify: `CLAUDE.md` (bagian PPOB: SBI, ref, modal sebenarnya, peninjauan, callback tanpa token, client tiruan di test, `TRUSTED_PROXIES`), `docs/IA.md` (Cek pelanggan token, Perlu ditinjau, pemilih SBI, Perbarui dari SBI), `docs/DEPLOYMENT.md` (daftar uji coba deposit kecil dari spec, IP tetap + whitelist SBI, `TRUSTED_PROXIES`, URL callback)

- [ ] **Step 1: Tulis dokumentasi.**
- [ ] **Step 2: Jalankan** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, `mix test` → bersih.
- [ ] **Step 3: Periksa di browser** (dev server, akun "API Uji" dengan penyedia tiruan yang sudah ada): cek pelanggan token PLN, kartu tagihan baru, form akun SBI (tanpa menyimpan kredensial sungguhan). Tidak ada panggilan ke SBI. Data uji baru di database dev **hanya dengan izin**.
- [ ] **Step 4: Commit** `docs(layanan-ppob-sbi): SBI, reviews and the small-deposit trial`.
