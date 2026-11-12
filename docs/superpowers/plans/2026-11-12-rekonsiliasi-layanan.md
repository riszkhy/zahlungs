# Rekonsiliasi Layanan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin mencocokkan layanan api satu akun deposit dengan riwayat transaksi SBI (`/api/history`) untuk satu tanggal, melihat yang tidak cocok, dan membetulkannya lewat cek status.

**Architecture:** Adapter SBI mendapat `history/3`; `Sbi.Reply.history_row/1` membaca baris dengan aturan `Reply.transaction/1`. Modul murni `Services.Reconciliation` menggolongkan pasangan layanan dan baris SBI; `Services.reconcile/3` mengambil semua halaman dan layanan akun itu. Perbaikan (`Services.recheck_row/2`) bertanya status ke SBI lalu `apply_result/2`, tanpa pernah mengirim. Halaman `DepositLive.Reconcile` hanya memanggil SBI saat "Cocokkan" ditekan. Tidak ada tabel atau migrasi baru.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Ecto + MySQL/MariaDB, ExUnit + `Sbi.StubClient` + `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-11-12-rekonsiliasi-layanan-design.md`

## Global Constraints

- Kode, komentar, nama tes, dan pesan commit dalam bahasa Inggris; teks layar dalam bahasa Indonesia.
- Commit hanya di `feat/rekonsiliasi-layanan`, format `type(rekonsiliasi-layanan): subject`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Tanpa push dan tanpa merge. `.claude/launch.json` tidak ikut.
- Tidak ada dependensi baru, tabel baru, atau migrasi.
- Tes tidak pernah memanggil SBI: `Sbi.StubClient` (`expect/2`, `requests/0`). Semua nilai rekaan; database dev berisi transaksi pelanggan sungguhan dan nilainya tidak disalin ke kode, tes, dokumen, atau commit.
- Tidak ada jalur yang mengirim pembayaran dari fitur ini: tidak memanggil `send_payment`, `check_status/1`, atau `pay/2`.
- Status layanan hanya berubah lewat `Services.apply_result/2`.
- Hari memakai zona bawaan: `LocalTime` tanpa cabang (`LocalTime.today()`, `LocalTime.day_range(date, date)`).
- Kartu, bukan tabel; tidak melebar di 375 px. Handler menerima id sebagai angka maupun teks.

## Review Focus

1. Satu ref di riwayat SBI milik layanan akun deposit lain (atau organisasi lain): baris itu "Hanya di SBI", tidak pernah dipasangkan dengan layanan akun lain. Tes di Task 3.
2. "Ikuti SBI" ditekan dua kali: tekanan kedua tidak mengubah apa pun dan tidak menggandakan refund atau kas. Tes di Task 4.
3. Tanggal tanpa transaksi di kedua sisi: ringkasan nol dan pesan "Tidak ada transaksi pada tanggal ini.", bukan halaman kosong. Tes di Task 5.
4. Jawaban SBI tanpa `meta` atau `last_page`: dianggap satu halaman bila `data.data` berupa daftar; selain itu galat. Tes di Task 1.
5. Baris SBI dengan `ref_1` kosong: masuk "Hanya di SBI" dan tidak pernah cocok dengan layanan mana pun. Tes di Task 2.

---

### Task 1: Riwayat SBI di adapter

**Files:**
- Modify: `lib/zahlungs/services/provider.ex` (callback opsional)
- Modify: `lib/zahlungs/services/provider/sbi.ex` (`history/3`, tabel di `@moduledoc`)
- Modify: `lib/zahlungs/services/provider/sbi/reply.ex` (`history_row/1`)
- Test: `test/zahlungs/services/provider/sbi_reply_test.exs`, `test/zahlungs/services/provider/sbi_test.exs`

**Interfaces:**
- Produces: `@callback history(credentials, Date.t(), pos_integer) :: {:ok, %{rows: [history_row], last_page: pos_integer}} | {:error, :timeout | :unavailable}`, ditambahkan ke `@optional_callbacks`.
- Produces: `Reply.history_row(map) :: %{ref: binary | nil, status: :success | :failed | :refunded | :pending, inquiry?: boolean, cost: Decimal.t() | nil, product_code: binary | nil, customer_id: binary | nil, at: NaiveDateTime.t() | nil}`; `at` dalam UTC.
- Produces: `Sbi.history(credentials, Date.t(), pos_integer)`.

- [ ] **Step 1: Tes `history_row/1` yang gagal**

Di `sbi_reply_test.exs`, `describe "history_row/1"`. Baris rekaan, contoh dasar:

```elixir
@row %{
  "ref_1" => "Z1261112090000A1B2C3", "ref_2" => "2411120900001",
  "product_code" => "T5", "customer_id" => "089900001111",
  "status" => 1, "total_payment" => "5150",
  "created_at" => "2026-11-12 09:00:05.000000",
  "msg" => "TRX T5.089900001111 SUKSES, HRG:5150 SN:1111222233 REFID:Z1261112090000A1B2C3."
}
```

- `"a success keeps the ref, the cost and the time in UTC"`: `ref == "Z1261112090000A1B2C3"`, `status == :success`, `inquiry? == false`, `Decimal.equal?(cost, 5150)`, `at == ~N[2026-11-12 02:00:05]` (WIB → UTC dengan offset bawaan 7), `product_code == "T5"`, `customer_id == "089900001111"`.
- `"status 11 is a failure and 2 is pending"`.
- `"an RC in the message decides"`: msg dengan `RC:31` → `:refunded`; msg dengan `RC:94` dan status 1 → `:pending`.
- `"an inquiry row is marked"`: msg `"INQ PLN SUKSES"` → `inquiry? == true`; msg `"... CEK TAGIHAN ..."` → `true`.
- `"numbers as text, unreadable ones nil"`: `"total_payment" => "abc"` tanpa `HRG:` → `cost == nil`; `"created_at" => "kemarin"` → `at == nil`; `"ref_1" => ""` → `ref == nil`.

- [ ] **Step 2: Tes `Sbi.history/3` yang gagal**

Di `sbi_test.exs`, `describe "history/3"`, dengan `ok/1` dan `@credentials` yang sudah ada:

```elixir
test "asks for one day's page with rqid, without sign" do
  StubClient.expect("history", ok(%{"data" => [@row_data], "meta" => %{"last_page" => 3}}))

  assert {:ok, %{rows: [%{ref: "Z1261112090000A1B2C3"}], last_page: 3}} =
           Sbi.history(@credentials, ~D[2026-11-12], 2)

  assert [{"history", body, headers}] = StubClient.requests()
  assert body == %{"mmid" => "MM123", "date" => "2026-11-12", "page" => 2, "per_page" => 1000, "status" => ""}
  assert {"rqid", "rahasia"} in headers
  refute List.keymember?(headers, "sign", 0)
end
```

Ditambah:
- `"no meta is one page"`: `ok(%{"data" => []})` → `{:ok, %{rows: [], last_page: 1}}`.
- `"anything else is unavailable"`: `ok(%{"data" => "x"})`, `{:ok, 500, "<html>"}`, dan `error("RC:91 ...")` → `{:error, :unavailable}`.
- `"no answer is a timeout"`: `{:error, :timeout}` dari klien → `{:error, :timeout}`.

- [ ] **Step 3: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/services/provider/sbi_reply_test.exs test/zahlungs/services/provider/sbi_test.exs`
Expected: FAIL, `history_row/1` dan `history/3` belum ada.

- [ ] **Step 4: Implementasi**

- `history_row/1` memakai `transaction/1` untuk `status` dan `actual_cost` (jadi `cost`), dan `inquiry_row?/1` yang sudah ada untuk `inquiry?`, sehingga aturannya satu. Baris INQ tetap mendapat `inquiry?: true` walau `transaction/1` menganggapnya pending. `at`: `NaiveDateTime.from_iso8601/1`, lalu dikurangi `LocalTime.offset_seconds()`, dan dibulatkan ke detik. Teks kosong menjadi `nil`.
- `history/3` tidak memakai `call/4` (yang selalu menambah `sign`): kirim langsung lewat `client().post("history", body, [{"rqid", credentials["password"]}, {"content-type", "application/json"}], 15_000)`. `Reply.envelope/2` → `{:data, %{"data" => list}}` dengan `list` berupa daftar adalah jawaban; `last_page` dari `meta`, bawaan 1. `{:error, :timeout}` dari klien tetap `:timeout`; galat jaringan lain dan semua jawaban lain `:unavailable`.
- Baris `| Rekonsiliasi | `history` (header rqid, tanpa sign) |` di tabel `@moduledoc`.

- [ ] **Step 5: Jalankan, pastikan lulus**

Run: perintah Step 3.
Expected: PASS.

- [ ] **Step 6: Commit**

Ikutkan spec dan plan, karena keduanya belum di-commit.

```bash
git add docs/superpowers/specs/2026-11-12-rekonsiliasi-layanan-design.md docs/superpowers/plans/2026-11-12-rekonsiliasi-layanan.md lib/zahlungs/services/provider.ex lib/zahlungs/services/provider/sbi.ex lib/zahlungs/services/provider/sbi/reply.ex test/zahlungs/services/provider/sbi_reply_test.exs test/zahlungs/services/provider/sbi_test.exs
git commit -m "feat(rekonsiliasi-layanan): read a day of SBI's transaction history" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Menggolongkan

**Files:**
- Create: `lib/zahlungs/services/reconciliation.ex`
- Test: `test/zahlungs/services/reconciliation_test.exs`

**Interfaces:**
- Consumes: bentuk `history_row` (Task 1).
- Produces (semua murni):
  - `Reconciliation.compare(ours :: [%Transaction{}], day :: [history_row], next_day :: [history_row]) :: %{rows: [row], summary: summary}`
  - `Reconciliation.classify(ours :: %Transaction{} | nil, theirs :: history_row | nil) :: row`
  - `Reconciliation.summarize([row]) :: summary`
  - `row :: %{kind: :follow | :conflict | :pending_there | :ours_only | :cost_diff | :theirs_only | :matched, ref: binary | nil, ours: %Transaction{} | nil, theirs: history_row | nil, in_review?: boolean}`
  - `summary :: %{counts: %{kind => non_neg_integer}, cost_difference: Decimal.t(), theirs_only_total: Decimal.t()}`, dengan setiap kind ada di `counts`.

- [ ] **Step 1: Tes yang gagal**

`use ExUnit.Case, async: true`, tanpa database. `ours(attrs)` membangun `%Transaction{channel: "api", status: "processing", ref_id: ..., sent_at: ~N[...], cost: Decimal, inserted_at: ...}`; `theirs(attrs)` membangun peta `history_row`.

`describe "classify/2"`, satu `assert` per baris tabel golongan spec:

| ours | theirs | kind |
|---|---|---|
| success, cost 5150 | success, cost 5150 | `:matched` |
| success, cost 5150 | success, cost `nil` | `:matched` |
| failed | failed | `:matched` |
| failed | refunded | `:matched` |
| processing | pending | `:matched` |
| processing | success / failed / refunded | `:follow` |
| success | failed / refunded | `:conflict` |
| failed | success | `:conflict` |
| success / failed | pending | `:pending_there` |
| success, cost 5150 | success, cost 5200 | `:cost_diff` |
| sent, any status | `nil` | `:ours_only` |
| `nil` | any | `:theirs_only` |

Ditambah: `"a service in review keeps its kind and is marked"` (`review_reason: "Uji"`, success vs failed → `kind: :conflict, in_review?: true`).

`describe "compare/3"`:
- `"inquiry rows are left out"`: ours bill ref `"Q1"`, day = baris INQ ref `"Q1"` + baris bayar sukses ref `"Q1"` → satu row `:matched`; baris INQ saja tanpa ours → tidak ada row.
- `"the latest of two rows for one ref is used"`: dua baris non-INQ ref sama, `at` berbeda (gagal lalu sukses) → dipakai yang sukses.
- `"a service never sent is left out"`: `sent_at: nil` → tidak ada row.
- `"the next day only finds ours"`: ours ref `"Z1"` tidak ada di day, ada di next_day → row sesuai baris next_day; baris next_day lain tidak muncul.
- `"a blank ref never matches"`: day row `ref: nil` → `:theirs_only`; ours dengan `ref_id: nil` dan `sent_at` terisi → `:ours_only`; keduanya tidak dipasangkan.
- `"unmatched first, by kind then time"`: urutan kind `[:follow, :conflict, :pending_there, :ours_only, :cost_diff, :theirs_only, :matched]`, lalu waktu (`ours.inserted_at`, atau `theirs.at`), lalu ref.

`describe "summarize/1"`: counts tiap kind (yang tak ada = 0); `cost_difference` = jumlah `theirs.cost − ours.cost` pada `:cost_diff` (5200 − 5150 + 900 − 1000 = −50); `theirs_only_total` = jumlah `cost` baris `:theirs_only` berstatus `:success` (yang gagal tidak dihitung, `nil` dianggap 0).

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/services/reconciliation_test.exs`
Expected: FAIL, modul belum ada.

- [ ] **Step 3: Implementasi**

`@moduledoc` menyebut modul ini dipanggil lewat `Services` dan murni di bagian ini. Refund dianggap gagal. `compare/3` membuang `inquiry?`, mengelompokkan baris per ref dengan baris `at` terbesar (`nil` terkecil), dan memasangkan ours (yang `sent_at`-nya terisi) dengan day lalu next_day. Baris day yang ref-nya bukan milik ours mana pun menjadi `:theirs_only`.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: perintah Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/services/reconciliation.ex test/zahlungs/services/reconciliation_test.exs
git commit -m "feat(rekonsiliasi-layanan): sort services and SBI rows into what matches and what doesn't" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Laporan satu akun dan satu tanggal

**Files:**
- Modify: `lib/zahlungs/services/reconciliation.ex` (`run/4`)
- Modify: `lib/zahlungs/services.ex` (`reconcile/3,4`, `reconciliation_summary/1`)
- Test: `test/zahlungs/services/reconciliation_test.exs` (`describe "reconcile/3"`, `use` diganti `Zahlungs.DataCase, async: true` untuk berkas ini)

**Interfaces:**
- Consumes: `Sbi.history/3` (Task 1), `compare/3`, `summarize/1` (Task 2), `Deposits.connection/1`, `Accounts.get_user!/1`, `LocalTime.today/0`, `LocalTime.day_range/2`.
- Produces: `Services.reconcile(%User{}, %Account{}, %Date{}, today \\ LocalTime.today()) :: {:ok, %{rows: [row], summary: summary, date: Date.t()}} | {:error, :not_admin | :future_date | :unsupported | :credentials | :unavailable}`.
- Produces: `Services.reconciliation_summary([row]) :: summary` (meneruskan ke `summarize/1`).

- [ ] **Step 1: Tes yang gagal**

Setup: admin (`set_user_role(user_fixture(), "admin")`), akun `deposit_account_fixture(%{mode: "api", provider: "sbi", credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => "pw"}})` dipasang ke `default_store()`, kasir di shift, produk layanan. `service!(attrs)` memakai `Repo.insert!(%Transaction{...})` dengan `ref_id`, `sent_at`, `status`, `channel: "api"`, `cost`, dan `inserted_at` (UTC, contoh `~N[2026-11-12 03:00:00]` = 10.00 WIB). `page(rows, last_page)` = `{:ok, 200, %{"data" => %{"data" => rows, "meta" => %{"last_page" => last_page}}}}`. `@today ~D[2026-11-13]`.

- `"reads every page and matches by ref"`: tiga halaman (`expect` tiga kali), ref tersebar di halaman 1 dan 3 → row cocok untuk keduanya; `StubClient.requests()` berisi `page` 1, 2, 3.
- `"one failed page fails the whole report"`: halaman 2 `{:error, :timeout}` → `{:error, :unavailable}`.
- `"more than 20 pages is refused"`: `last_page: 21` → `{:error, :unavailable}` dan hanya satu permintaan.
- `"the next day is asked only when something is missing"`: semua ours ketemu → satu permintaan `date` `"2026-11-12"`; satu ours terkirim yang belum ketemu → permintaan kedua dengan `"date" => "2026-11-13"`.
- `"a service of another day is matched by its ref"`: layanan `inserted_at ~N[2026-11-11 16:59:00]` (23.59 WIB tanggal 11), ref ada di riwayat tanggal 12 → row `:matched`, bukan `:theirs_only`.
- `"only this account's services"`: layanan akun lain (organisasi yang sama) dan layanan organisasi lain (`in_org`) dengan ref yang ada di riwayat → baris SBI itu `:theirs_only`; layanan itu tidak muncul. (Review Focus 1.)
- `"the day is the default zone's"`: layanan `inserted_at ~N[2026-11-11 17:00:00]` (00.00 WIB tanggal 12) ikut; `~N[2026-11-11 16:59:59]` tanpa ref di riwayat tidak ikut.
- `"refused before asking SBI"`: kasir → `:not_admin`; `~D[2026-11-14]` dengan `@today` → `:future_date`; akun manual dan akun `provider: "fake"` → `:unsupported`; `StubClient.requests() == []` pada semuanya.
- `"credentials that can't be read"`: akun api SBI yang `credentials`-nya diganti biner acak lewat `Repo.update!(Ecto.Changeset.change(account, credentials: "x"))` → `{:error, :credentials}`.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/services/reconciliation_test.exs`
Expected: FAIL pada `describe "reconcile/3"`.

- [ ] **Step 3: Implementasi**

Urutan pemeriksaan: admin (peran dari `Accounts.get_user!/1`), tanggal (`Date.compare(date, today) == :gt` → `:future_date`), `account.mode == "api"`, lalu `Deposits.connection/1` (`:credentials`), lalu `Code.ensure_loaded?(adapter) and function_exported?(adapter, :history, 3)` (`:unsupported`). Halaman diambil berurutan sampai `last_page`; `last_page > 20` → `:unavailable`; galat apa pun → `:unavailable`. Layanan: `Transaction` dengan `deposit_account_id == ^account.id and channel == "api"` dan (`inserted_at` dalam `LocalTime.day_range(date, date)` atau `ref_id in ^refs_hari_itu`). Hari berikutnya diambil (semua halamannya) hanya bila ada layanan hari itu yang terkirim dan ref-nya tidak ada di baris hari itu. `Services.reconcile/4` meneruskan ke `Reconciliation.run/4`.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: perintah Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/services/reconciliation.ex lib/zahlungs/services.ex test/zahlungs/services/reconciliation_test.exs
git commit -m "feat(rekonsiliasi-layanan): a day's report for one deposit account" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Perbaikan satu baris

**Files:**
- Modify: `lib/zahlungs/services.ex` (`recheck_row/2`, di bagian Status checks)
- Test: `test/zahlungs/services/reconciliation_test.exs` (`describe "recheck_row/2"`)

**Interfaces:**
- Consumes: `classify/2` (Task 2); `ask_status/1` dan `apply_result/2` yang sudah ada; `Stores.store_ids/0`.
- Produces: `Services.recheck_row(%User{}, row) :: {:ok, row} | {:error, :not_admin | :not_api | :not_sent}`. Bekerja pada `row.ours.id`; mengembalikan `classify(layanan_terbaru, row.theirs)`. Layanan yang bukan milik cabang organisasi admin → `Ecto.NoResultsError`.

- [ ] **Step 1: Tes yang gagal**

Memakai setup Task 3. `status_answer(status)` = `ok(%{"ref_1" => ref, "ref_2" => "R1", "status" => status, "total_payment" => "5150", "msg" => "..."})`.

- `"a processing service follows SBI"`: layanan processing terkirim, `expect("status", status_answer(1))` → `{:ok, %{kind: :matched, ours: %{status: "success"}}}`.
- `"a contradiction goes to review without changing the status"`: layanan success, `status_answer(11)` → `{:ok, %{kind: :conflict, in_review?: true, ours: %{status: "success"}}}`.
- `"pressed twice changes nothing more"`: layanan processing, SBI menjawab gagal dua kali → panggilan kedua mengembalikan row yang sama; `refunded_at` tetap `nil`, status `"failed"`, dan uang laci shift (`Shifts.expected_cash/1`) sama setelah panggilan pertama dan kedua. (Review Focus 2.)
- `"never sends"`: layanan `sent_at: nil` → `{:error, :not_sent}`, `StubClient.requests() == []`.
- `"a manual service"`: `channel: "manual"` → `{:error, :not_api}`.
- `"a cashier"`: `{:error, :not_admin}`, tanpa permintaan.
- `"another organization's service"`: layanan di cabang organisasi lain → `assert_raise Ecto.NoResultsError`.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/services/reconciliation_test.exs`
Expected: FAIL pada `describe "recheck_row/2"`.

- [ ] **Step 3: Implementasi**

Peran dari `Accounts.get_user!/1`. Layanan diambil dengan `Repo.one!(from t in Transaction, where: t.id == ^id and t.store_id in ^Stores.store_ids())`. Pemeriksaan `:not_api` lalu `:not_sent`, lalu `ask_status/1` (yang tidak mengirim), lalu baca ulang baris dan `Reconciliation.classify/2`. `@doc` menyebut bahwa fungsi ini tidak pernah mengirim pembayaran, berbeda dari `check_status/1`.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: perintah Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/services.ex test/zahlungs/services/reconciliation_test.exs
git commit -m "feat(rekonsiliasi-layanan): fix one row by asking SBI again, never sending" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Halaman rekonsiliasi

**Files:**
- Create: `lib/zahlungs_web/live/deposit_live/reconcile.ex`
- Modify: `lib/zahlungs_web/router.ex` (setelah `live "/admin/deposits/:id/edit"`)
- Modify: `lib/zahlungs_web/live/deposit_live/index.ex` (tautan di bagian `:show`, hanya akun `mode == "api"`)
- Test: `test/zahlungs_web/live/deposit_live/reconcile_test.exs`

**Interfaces:**
- Consumes: `Services.reconcile/3`, `Services.recheck_row/2`, `Services.reconciliation_summary/1`, `Deposits.get_account!/1`.
- Produces: rute `live "/admin/deposits/:id/reconcile", DepositLive.Reconcile, :index`; event `reconcile` (`%{"date" => iso}`), `recheck` (`%{"index" => _}`, posisi baris dalam `@rows`), `toggle_matched`.

Teks layar:

| Tempat | Teks |
|---|---|
| Judul, subjudul | `Rekonsiliasi`, `{nama akun} · cocokkan layanan dengan riwayat SBI satu hari.` |
| Form | `Tanggal`, tombol `Cocokkan` |
| Golongan | `Ikuti SBI`, `Bertentangan`, `Belum final di SBI`, `Hanya di Zahlungs`, `Selisih modal`, `Hanya di SBI`, `Cocok` |
| Tombol | `Ikuti SBI` (`:follow`), `Tinjau` (`:conflict`), `Cek status` (`:pending_there`, `:ours_only`) |
| Tanda | `Sedang ditinjau` |
| Ringkasan | `Selisih modal`, `Potongan tanpa transaksi Zahlungs` |
| Cocok | `Lihat yang cocok ({n})`, `Sembunyikan yang cocok` |
| Kosong | `Tidak ada transaksi pada tanggal ini.` |
| Galat | `Rekonsiliasi hanya untuk akun api SBI.`, `Riwayat SBI belum bisa diambil, coba lagi.`, `Kredensial penyedia tidak bisa dibaca. Isi ulang di halaman akun deposit.`, `Tanggal tidak valid atau belum terjadi.` |
| Hasil tombol | `:matched` → `Sudah cocok dengan SBI.`; `in_review?` → `Masuk Peninjauan. Putuskan di halaman akun deposit.`; lainnya → `SBI belum menjawab, coba lagi.` |
| Tautan di halaman akun | `Rekonsiliasi per tanggal` |

- [ ] **Step 1: Tes yang gagal**

`use ZahlungsWeb.ConnCase, async: true`, `setup` memanggil `default_org()` (pelajaran dari fitur Monitoring). Data dan jawaban stub seperti Task 3.

- `describe "access"`: tamu → `/users/log_in`; kasir → `/`; admin → 200 dan memuat `Rekonsiliasi`.
- `"opening the page doesn't ask SBI"`: setelah `mount_live`, `StubClient.requests() == []`, tanpa daftar.
- `"reconciling shows the summary and the rows that don't match first"`: satu `:follow` dan satu `:matched` → HTML memuat `Ikuti SBI` dan `Lihat yang cocok (1)`, tanpa kode layanan yang cocok sebelum `toggle_matched`.
- `"an empty day"`: riwayat kosong, tanpa layanan → `Tidak ada transaksi pada tanggal ini.` (Review Focus 3.)
- `"errors show a message and no rows"`: halaman SBI `{:error, :timeout}` → `Riwayat SBI belum bisa diambil, coba lagi.`; akun manual → `Rekonsiliasi hanya untuk akun api SBI.`; tanggal besok atau `"abc"` → `Tanggal tidak valid atau belum terjadi.` tanpa permintaan.
- `"a button updates its row only"`: setelah `reconcile`, `expect("status", ...)` lalu `event("recheck", %{"index" => 0})` dan `%{"index" => "0"}` (dua tes) → flash `Sudah cocok dengan SBI.`, ringkasan diperbarui, dan hanya satu permintaan `history` di `requests()`.
- `"an index that isn't a row changes nothing"`: `"abc"` dan `99` → HTML sama.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs_web/live/deposit_live/reconcile_test.exs`
Expected: FAIL, rute dan modul belum ada.

- [ ] **Step 3: Rute dan tautan**

Rute di `live_session` admin yang sama dengan `/admin/deposits`. Tautan `<.link navigate={~p"/admin/deposits/#{@account}/reconcile"}>` dekat form "Cocokkan dengan aplikasi penyedia", hanya bila `@account.mode == "api"`.

- [ ] **Step 4: Implementasi LiveView**

Assign: `account`, `date` (ISO kemarin WIB), `rows` (nil sebelum dicocokkan), `summary`, `error`, `show_matched` false, `page_title` `"Rekonsiliasi"`. `recheck` membaca baris dari `@rows` dengan indeks (angka atau teks, `Integer.parse/1`), memanggil `Services.recheck_row/2`, mengganti baris itu, lalu `Services.reconciliation_summary/1`. Kartu: `rounded-lg border border-gray-200 p-4`, `flex flex-wrap`, `min-w-0 break-words`. Uang `format_price/1`, waktu `LocalTime.to_local/1` dengan format `%d %b %Y %H:%M`. Tombol `phx-disable-with`.

- [ ] **Step 5: Jalankan, pastikan lulus**

Run: perintah Step 2, lalu `mix test test/zahlungs_web/live/deposit_live_test.exs`.
Expected: PASS keduanya.

- [ ] **Step 6: Commit**

```bash
git add lib/zahlungs_web/live/deposit_live/reconcile.ex lib/zahlungs_web/router.ex lib/zahlungs_web/live/deposit_live/index.ex test/zahlungs_web/live/deposit_live/reconcile_test.exs
git commit -m "feat(rekonsiliasi-layanan): the reconciliation page of a deposit account" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Dokumen dan verifikasi akhir

**Files:**
- Modify: `CLAUDE.md` (bagian "PPOB through Smart Biller Indonesia (SBI)")
- Modify: `docs/IA.md` (bagian akun deposit)
- Modify: `docs/DEPLOYMENT.md` (daftar periksa uji pertama SBI)

- [ ] **Step 1: Perbarui dokumen**

- `CLAUDE.md`: satu butir **Reconciliation**: `/admin/deposits/:id/reconcile`, `Services.reconcile/3` (riwayat `history` dengan header `rqid`, tanpa `sign`, semua halaman, paling banyak 20, D+1 hanya bila perlu, satu halaman gagal = laporan gagal), `Services.Reconciliation` (golongan, murni), `Services.recheck_row/2` (cek status lalu `apply_result`, tidak pernah mengirim), tanpa tabel.
- `docs/IA.md`: halaman baru, siapa yang bisa membuka, dan golongannya.
- `docs/DEPLOYMENT.md`: satu langkah sesudah uji pulsa kecil: buka Rekonsiliasi untuk hari itu dan pastikan keempat asumsi di spec (header `rqid`, tanggal WIB, `total_payment`, `ref_1`).

- [ ] **Step 2: Pemeriksaan penuh**

Run: `mix format --check-formatted`
Expected: tanpa keluaran.

Run: `mix test`
Expected: 0 failures.

Run: `mix credo lib/zahlungs/services/reconciliation.ex lib/zahlungs_web/live/deposit_live/reconcile.ex`
Expected: no issues.

- [ ] **Step 3: Periksa di browser**

Perlu admin: minta pengguna login sendiri di panel browser; jangan mengetik kata sandi. Di 1280 px dan 375 px, buka halaman Rekonsiliasi sebuah akun: tidak melebar, tautan dari halaman akun deposit muncul. **Jangan menekan "Cocokkan" pada akun SBI sungguhan tanpa persetujuan pengguna**, karena itu memanggil SBI; tombol perbaikan tidak ditekan sama sekali. Bila belum login atau tidak disetujui, laporkan bagian itu sebagai belum diperiksa.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/IA.md docs/DEPLOYMENT.md
git commit -m "docs(rekonsiliasi-layanan): reconciling services with SBI's history" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
