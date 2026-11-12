# Koreksi Layanan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin membetulkan status final transaksi layanan (berhasil ↔ gagal, api dan manual) dari Riwayat layanan dan Rekonsiliasi, dengan alasan dan jejak, lewat perpindahan yang sama dengan Peninjauan.

**Architecture:** Satu aturan "menunggu dikembalikan" (`Transaction.awaiting_refund/0` untuk query, `awaiting_refund?/1` murni) menggantikan empat salinan `channel == "api" and is_nil(refunded_at)`. `Services.correct_status/5` mengunci baris lalu menjalankan perpindahan `review(:refund)` / `review(:success)` dan mengisi tiga kolom jejak baru. Popup koreksi adalah komponen bersama (`ZahlungsWeb.ServiceCorrection`) yang dipakai `ServiceLive.History` dan `DepositLive.Reconcile`.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Ecto + MySQL/MariaDB, ExUnit + `ZahlungsWeb.LiveDriver` + `Sbi.StubClient`.

**Spec:** `docs/superpowers/specs/2026-11-12-koreksi-layanan-design.md`

## Global Constraints

- Kode, komentar, nama tes, dan commit dalam bahasa Inggris; teks layar dalam bahasa Indonesia, persis seperti tabel Pesan di spec.
- Commit hanya di `feat/koreksi-layanan`, format `type(koreksi-layanan): subject`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Tanpa push dan merge. `.claude/launch.json` tidak ikut.
- Tidak ada dependensi baru. Satu migrasi saja (tiga kolom).
- Tes tidak memanggil SBI. Semua nilai rekaan; nilai database dev tidak disalin ke mana pun.
- Pemeriksaan admin di konteks: peran dari `Accounts.get_user!/1`, transaksi disaring `t.store_id in ^Stores.store_ids()`.
- Alasan: di-trim, 1–200 karakter. SN: maks 64 karakter, kosong/spasi = tidak diisi.
- Kartu dan popup tidak melebar di 375 px. Handler menerima id dan indeks sebagai angka maupun teks.
- Heredoc bash di lingkungan ini memakan `\\`: tulis berkas Elixir dengan tool Write/Edit, bukan heredoc.

## Review Focus

1. Layanan manual yang dikoreksi menjadi gagal tampil di kartu "Perlu dikembalikan" di `/services`, dan tombol konfirmasinya bekerja (template tidak menyaring `channel == "api"`). Tes di Task 1.
2. Admin dengan pilihan "Semua toko" di navbar bisa mengoreksi transaksi cabang mana pun di organisasinya dari Riwayat layanan. Tes di Task 3.
3. Alasan tepat 200 karakter diterima, 201 ditolak, dan alasan berisi spasi saja ditolak. Tes di Task 2.
4. SN berisi spasi saja saat Jadikan berhasil tidak menimpa SN lama. Tes di Task 2.
5. Popup yang terbuka di Riwayat layanan saat transaksinya berubah lewat siaran (`{:service_changed, id}`) tidak menyimpan koreksi atas data usang: konteks membaca ulang di bawah kunci dan menjawab `:same_status`. Tes di Task 3.

---

### Task 1: Kolom jejak dan aturan "menunggu dikembalikan"

**Files:**
- Create: `priv/repo/migrations/20261112100000_add_correction_to_service_transactions.exs`
- Modify: `lib/zahlungs/services/transaction.ex` (field, `belongs_to :corrected_by`, `awaiting_refund/0`, `awaiting_refund?/1`)
- Modify: `lib/zahlungs/services.ex` (`shift_totals/1`, `list_refunds_due/1`, `refund/2`)
- Modify: `lib/zahlungs/monitoring.ex` (`refund_due/0`)
- Test: `test/zahlungs/services/correction_test.exs`

**Interfaces:**
- Produces: kolom `corrected_at :naive_datetime`, `corrected_by_id` (users, `on_delete: :nilify_all`), `correction_reason :string` (200), semuanya null.
- Produces: `Transaction.awaiting_refund() :: Ecto.Query.dynamic_expr()` = `status == "failed" and is_nil(refunded_at) and (channel == "api" or not is_nil(corrected_at))`, binding pertama `t`.
- Produces: `Transaction.awaiting_refund?(%Transaction{}) :: boolean`, aturan yang sama.

- [ ] **Step 1: Tes yang gagal**

`use Zahlungs.DataCase, async: true`. Setup seperti `reconciliation_test.exs`: kasir di shift, admin, produk, akun deposit dipasang ke `default_store()`. `service!(ctx, attrs)` = `Repo.insert!(%Transaction{...})` (kode unik, `price` 12.000, `payment_method: "cash"`, `shift_id` shift kasir).

`describe "awaiting refund"`:
- `"the rule"`: `awaiting_refund?` benar untuk api gagal tanpa `refunded_at`, dan untuk manual gagal dengan `corrected_at`; salah untuk manual gagal tanpa `corrected_at`, untuk yang `refunded_at` terisi, dan untuk berhasil.
- `"a manual service failed by a correction counts in its drawer until refunded"`: manual `status: "failed", corrected_at: ~N[...]` → `Shifts.expected_cash(shift)` = kas awal + 12.000; `Services.list_refunds_due(scope(cashier))` memuatnya; `Services.confirm_refund(tx, cashier)` → `{:ok, %{refunded_at: %NaiveDateTime{}}}` lalu `expected_cash` kembali ke kas awal.
- `"a manual service marked failed was handed back already"`: manual gagal tanpa `corrected_at` → tidak di laci, tidak di `list_refunds_due`, `confirm_refund` → `{:error, :not_refundable}`.
- `"the refunds-due card on the Layanan screen shows it"` (Review Focus 1): `ServiceLive.Index` lewat `mount_live` untuk kasir → HTML memuat kode transaksi manual yang dikoreksi dan tombol konfirmasi refund-nya. (Tes LiveDriver ini boleh di `test/zahlungs_web/live/service_live_test.exs`.)
- `Monitoring`: organisasi dengan satu manual gagal ber-`corrected_at` → baris overview-nya menghitung satu refund yang belum dikonfirmasi (nama field seperti tes Monitoring yang sudah ada).

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/services/correction_test.exs`
Expected: FAIL — `corrected_at` bukan field / `awaiting_refund?` belum ada.

- [ ] **Step 3: Migrasi, schema, dan aturan**

Migrasi `alter table(:service_transactions)` tiga kolom. Di keempat tempat, ganti salinan aturannya dengan `^Transaction.awaiting_refund()` (query) atau `Transaction.awaiting_refund?/1` (klausa `refund/2`, yang tetap menolak `review_reason` terisi lebih dulu). `list_refunds_due/1` dan `Monitoring.refund_due/0` tetap menambah `is_nil(t.review_reason)`. Ubah `@doc` `list_refunds_due/1` dan `confirm_refund/2` dari "failed api services" menjadi "services waiting for their money to go back".

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs/services/correction_test.exs test/zahlungs/services_api_test.exs test/zahlungs/monitoring_test.exs test/zahlungs_web/live/service_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

Ikutkan spec dan plan.

```bash
git add docs/superpowers/specs/2026-11-12-koreksi-layanan-design.md docs/superpowers/plans/2026-11-12-koreksi-layanan.md priv/repo/migrations/20261112100000_add_correction_to_service_transactions.exs lib/zahlungs/services/transaction.ex lib/zahlungs/services.ex lib/zahlungs/monitoring.ex test/zahlungs/services/correction_test.exs test/zahlungs_web/live/service_live_test.exs
git commit -m "feat(koreksi-layanan): one rule for money waiting to go back" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `Services.correct_status/5`

**Files:**
- Modify: `lib/zahlungs/services.ex` (bagian "## Reviews": `correct_status/5`, `correctable?/1`; perpindahan dibagi dengan `review/3`)
- Test: `test/zahlungs/services/correction_test.exs`

**Interfaces:**
- Consumes: `Transaction.awaiting_refund?/1` (Task 1).
- Produces: `Services.correct_status(%User{}, %Transaction{}, "failed" | "success", reason :: binary, opts :: [token_sn: binary]) :: {:ok, %Transaction{}} | {:error, :not_admin | :not_final | :same_status | :refunded | :in_review | :reason_required | :invalid_token_sn}`; transaksi di luar cabang organisasi admin → `Ecto.NoResultsError`.
- Produces: `Services.correctable?(%Transaction{}) :: boolean` = `review_reason` kosong dan (`status == "success"` atau `awaiting_refund?`).

- [ ] **Step 1: Tes yang gagal**

`describe "correct_status/5"` (setup Task 1):
- `"a success becomes a failure waiting for its money"`: api berhasil → `{:ok, tx}` dengan `status: "failed"`, `failure_reason == "Pulsa tidak masuk"`, `correction_reason == "Pulsa tidak masuk"`, `corrected_by_id == admin.id`, `corrected_at` terisi, `token_sn` tetap; `expected_cash` sama sebelum dan sesudah; setelah `confirm_refund(tx, cashier)` berkurang 12.000.
- `"on a closed shift the refund is booked where it is handed back"`: tutup shift asal (`Shifts.close_shift/3`), kasir lain buka shift di toko yang sama, koreksi → `failed_after_shift_close: true`; `confirm_refund(tx, other)` → ada `cash_movement` kategori `"refund"` 12.000 di shift kasir lain.
- `"a manual success can be failed too"`: manual berhasil → gagal, lalu `Transaction.awaiting_refund?` benar.
- `"a failure waiting for its money becomes a success"`: api gagal tanpa refund, `token_sn: "1111-2222"` → `status: "success"`, `failure_reason: nil`, `failed_after_shift_close: false`, `token_sn == "1111-2222"`; `Services.commission/1` dan `Services.deposit_used/1` naik.
- `"a blank SN keeps the old one"` (Review Focus 4): `token_sn: "   "` pada transaksi ber-SN `"9999"` → `"9999"`.
- `"refused without changing the row"`: untuk tiap kasus bandingkan `Repo.reload!(tx)` sebelum dan sesudah —
  kasir → `:not_admin`; `processing` → `:not_final`; berhasil → `"success"` `:same_status`; api gagal ber-`refunded_at` → `"success"` `:refunded`; manual gagal tanpa `corrected_at` → `:refunded`; `review_reason: "Uji"` → `:in_review`; alasan `"   "` dan 201 karakter → `:reason_required`; SN 65 karakter → `:invalid_token_sn`.
- `"a reason of 200 characters is fine"` (Review Focus 3).
- `"another organization's service"`: `assert_raise Ecto.NoResultsError`.
- `"a stale struct"`: koreksi dua kali dengan struct awal yang sama → kedua `:same_status`.
- `"a later contradicting answer goes to review"`: api berhasil dikoreksi gagal, lalu `Services.apply_result(tx.id, %{status: :success, token_sn: "1"})` → status tetap `"failed"`, `review_reason` terisi.
- `describe "correctable?/1"`: berhasil → true; api gagal belum refund → true; manual gagal tanpa koreksi → false; ber-`review_reason` → false; `processing` → false.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/services/correction_test.exs`
Expected: FAIL — `correct_status/5` belum ada.

- [ ] **Step 3: Implementasi**

Urutan: admin (DB) → `Repo.one!` dengan `Stores.store_ids()` → validasi alasan dan SN (sebelum mengunci) → `Repo.transaction` dengan `lock_transaction/1`, lalu pemeriksaan status pada baris terkunci dengan urutan `:in_review`, `:not_final`, `:same_status`, `:refunded` → `Repo.rollback/1` untuk galat → `broadcast/1` setelah commit. Perubahan status dibagi dengan `review/3`: ekstrak dua fungsi privat `fail_changes(transaction, reason)` dan `succeed_changes()` yang dipakai keduanya (`review/3` tetap mengisi `reviewed/2`, koreksi mengisi tiga kolom jejak). `@doc` menyebut bahwa SBI tidak ditanya, dan menunjuk aturan menunggu dikembalikan.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs/services/correction_test.exs test/zahlungs/services_review_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/services.ex test/zahlungs/services/correction_test.exs
git commit -m "feat(koreksi-layanan): an admin corrects a final status, with a reason" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Popup koreksi dan Riwayat layanan

**Files:**
- Create: `lib/zahlungs_web/components/service_correction.ex`
- Modify: `lib/zahlungs_web/live/service_live/history.ex`
- Test: `test/zahlungs_web/live/service_history_live_test.exs`

**Interfaces:**
- Consumes: `Services.correct_status/5`, `Services.correctable?/1`.
- Produces: `ZahlungsWeb.ServiceCorrection.modal(assigns)` — attrs `transaction` (`%Transaction{}`), `error` (binary | nil), `reason` (binary), `token_sn` (binary); event `cancel_correction`, submit `confirm_correction` dengan `%{"reason" => _, "token_sn" => _}`; fokus awal di Batal (urutan dan `autofocus` seperti popup `confirm-service` di `ServiceLive.Index`).
- Produces: `ServiceCorrection.button?(%User{}, %Transaction{}) :: boolean` (admin dan `correctable?`), `ServiceCorrection.message({:ok, tx} | {:error, reason}) :: {:info | :error, binary}` dengan teks tabel Pesan spec, dan `ServiceCorrection.keep_open?(reason) :: boolean` (benar untuk `:reason_required`, `:invalid_token_sn`).
- Produces (History): event `review_correction` (`%{"id" => _}`), `cancel_correction`, `confirm_correction`; assign `correcting` (`%Transaction{} | nil`), `correction_error`, `correction_reason`, `correction_token_sn`.

- [ ] **Step 1: Tes yang gagal**

`describe "correcting a status"` di `service_history_live_test.exs` (layanan api berhasil yang dibuat langsung dengan `Repo.insert!`, seperti Task 1):
- `"an admin sees the button, a cashier doesn't"`: HTML admin memuat `Koreksi status`; HTML kasir tidak.
- `"a cashier's event is refused"`: kasir `review_correction` lalu `confirm_correction` → status tetap `"success"`.
- `"saving needs the popup open"`: `confirm_correction` tanpa `review_correction` → status tetap.
- `"a blank reason keeps the popup open"`: → HTML memuat `Alasan wajib diisi (maks. 200 karakter).` dan `assigns.correcting` tidak nil.
- `"a saved correction"`: `review_correction` dengan `%{"id" => tx.id}` (angka) dan satu tes dengan `"#{tx.id}"` (teks), lalu `confirm_correction` alasan `"Pulsa tidak masuk"` → flash info `Status dikoreksi menjadi Gagal. Uang menunggu dikembalikan kasir.`, popup tertutup, HTML memuat `Dikoreksi` dan `Pulsa tidak masuk`.
- `"all stores"` (Review Focus 2): admin dengan `store: "all"` mengoreksi transaksi cabang lain di organisasinya → berhasil.
- `"a popup over a changed service"` (Review Focus 5): buka popup, lalu ubah transaksi lewat `Services.correct_status/5` di proses tes, kirim `info({:service_changed, tx.id})`, lalu `confirm_correction` → flash galat `Status transaksi sudah berubah. Muat ulang.`

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs_web/live/service_history_live_test.exs`
Expected: FAIL — event belum ada.

- [ ] **Step 3: Komponen dan halaman**

`ServiceCorrection` adalah modul function component (`use Phoenix.Component`, `import ZahlungsWeb.CoreComponents`) dengan `<.modal id="correct-service" show on_cancel={JS.push("cancel_correction")}>`. Isi popup sesuai bagian Popup di spec (Jadikan gagal + catatan uang; Jadikan berhasil + kolom `token_sn` `maxlength=64`; `reason` `maxlength=200` wajib). Di History: tombol `Koreksi status` (`phx-click="review_correction"`, `phx-value-id`) di kartu HP dan di kolom Status tabel bila `button?/2`; `review_correction` mengambil transaksi dengan `Services.get_transaction!(scope, id)`; `confirm_correction` mengabaikan bila `correcting` nil, lalu `message/1` + `keep_open?/1`. `outcome/1` menampilkan `Dikoreksi {nama admin}, {waktu}: {alasan}` bila `corrected_at` terisi (preload `:corrected_by` di `list_transactions/2`; waktu lewat `LocalTime.to_local(corrected_at, tx.store)`).

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs_web/live/service_history_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs_web/components/service_correction.ex lib/zahlungs_web/live/service_live/history.ex lib/zahlungs/services.ex test/zahlungs_web/live/service_history_live_test.exs
git commit -m "feat(koreksi-layanan): correct a status from the service history" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Koreksi dari Rekonsiliasi

**Files:**
- Modify: `lib/zahlungs_web/live/deposit_live/reconcile.ex`
- Test: `test/zahlungs_web/live/deposit_live/reconcile_test.exs`

**Interfaces:**
- Consumes: `ServiceCorrection` (Task 3), `Services.correct_status/5`, `Reconciliation.classify/2`.
- Produces: event `review_correction` (`%{"index" => _}`, posisi di `@rows`), `cancel_correction`, `confirm_correction`; assign `correcting` (`%{index: integer, transaction: %Transaction{}} | nil`) dan tiga assign pesan seperti Task 3.

- [ ] **Step 1: Tes yang gagal**

Di `reconcile_test.exs`, `describe "correcting from the report"`:
- `"a conflict corrected to match SBI"`: layanan berhasil, riwayat SBI gagal (status 11) → setelah `reconcile`, `review_correction` `%{"index" => 0}` lalu `confirm_correction` alasan `"Gagal di SBI"` → flash `Status dikoreksi menjadi Gagal. Uang menunggu dikembalikan kasir.`, HTML memuat `Lihat yang cocok (1)`, dan `StubClient.requests()` hanya berisi satu `history` (tanpa `status`).
- `"index as text"`: `%{"index" => "0"}` → popup terbuka.
- `"no button for a row in review"`: layanan ber-`review_reason` → kartu tanpa `Koreksi status`.
- `"an index that isn't a row"`: `"abc"`, `99` → `correcting` tetap nil.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs_web/live/deposit_live/reconcile_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implementasi**

Tombol `Koreksi status` di `row_card` bila `row.ours` dan `ServiceCorrection.button?(@current_user, row.ours)`; indeks diurai dengan `parse_index/2` yang sudah ada. Setelah `{:ok, tx}`: `List.replace_at(rows, i, Reconciliation.classify(tx, row.theirs))` dan `Services.reconciliation_summary/1`.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: perintah Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs_web/live/deposit_live/reconcile.ex test/zahlungs_web/live/deposit_live/reconcile_test.exs
git commit -m "feat(koreksi-layanan): correct a status from the reconciliation report" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Dokumen dan verifikasi akhir

**Files:**
- Modify: `CLAUDE.md`, `docs/IA.md`

- [ ] **Step 1: Dokumen**

- `CLAUDE.md`, bagian PPOB Fase 1 ("Failures are refunded by a person"): satu butir **Admin correction** — `Services.correct_status/5`, `correctable?/1`, kolom jejak, aturan `Transaction.awaiting_refund/0` (api, atau digagalkan lewat koreksi), manual yang gagal lewat `mark_failed` tidak bisa dijadikan berhasil, SBI tidak ditanya.
- `CLAUDE.md`, Invariants: butir baru "A service's final status changes only through review or an admin correction."
- `docs/IA.md`: tombol Koreksi status (admin) di `/services/history` dan Rekonsiliasi.

- [ ] **Step 2: Pemeriksaan penuh**

Run: `mix ecto.migrate` (dev, hanya menambah kolom kosong) lalu `mix format --check-formatted`
Expected: tanpa keluaran.

Run: `mix test`
Expected: 0 failures.

Run: `mix credo lib/zahlungs/services.ex lib/zahlungs_web/components/service_correction.ex lib/zahlungs_web/live/service_live/history.ex lib/zahlungs_web/live/deposit_live/reconcile.ex`
Expected: no issues.

- [ ] **Step 3: Periksa di browser**

Pengguna login sendiri sebagai admin di panel browser (jangan mengetik kata sandi). Di 1280 dan 375 px, buka Riwayat layanan: tombol Koreksi status muncul dan popup tidak melebar. **Jangan menyimpan koreksi pada transaksi sungguhan di database dev**; cukup buka popup lalu Batal. Bila belum login, laporkan sebagai belum diperiksa.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/IA.md
git commit -m "docs(koreksi-layanan): an admin's correction of a service status" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
