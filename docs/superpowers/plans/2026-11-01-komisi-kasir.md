# Komisi Kasir Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cashiers earn a commission (percent of margin, per category) on every successful service (PPOB) transaction they record; admins set the percents and read a per-cashier report, cashiers see their own.

**Architecture:** One owned table `service_commission_rates` (percent per category) and one column `service_transactions.commission_percent`, copied at `Services.record/3` (0 unless the recorder's role in the database is `cashier`). The commission amount is never stored: it is `FLOOR(GREATEST(price − cost, 0) × percent / 100)` for `success` rows, computed on read in Elixir and in SQL. The logic lives in a new module `Zahlungs.Services.Commissions`; `Zahlungs.Services` delegates the public names the spec uses.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MySQL (myxql), ExUnit with `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-11-01-komisi-kasir-design.md`

## Global Constraints

- Branch `feat/komisi-kasir` (from `master`). Commits `type(komisi-kasir): subject`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Code, comments and commit messages in English; UI text in Indonesian as the spec gives it.
- No new dependencies. LiveViews call context functions only (never `Repo` or schemas).
- `commission_percent` is never cast from attrs/params; the cashier's own report is always `scope.user`, never a `user_id` from params.
- Percent: `decimal(5,2)`, 0–100; blank = 0; a category without a row = 0.
- Amount: whole rupiah, rounded down, per transaction; only `status == "success"`; negative margin = 0.
- Periods by `inserted_at` through `LocalTime.day_range/3` with the scope's store; "all stores" = `Stores.store_ids/0`.
- Migration timestamp after `20261031120000` (feat/promo's, already on the shared dev DB): use `20261101090000`.
- Tests that write `service_products` are `async: false` only where the file already is; each test runs in its own default organization.
- `JS.push` values arrive as JSON numbers: handlers accept integer and string ids.

## Review Focus

1. A transaction whose status changes after recording through a path the tests don't drive (dispatcher, `check_pending/1`, callback) — the commission must follow the final status and cost with no code on that path. Covered indirectly by `apply_result/2` tests in Task 3.
2. An admin who opens a shift and records services, then is demoted to cashier mid-shift: only transactions recorded after the change earn commission (role read at record time). Task 2 pins the reverse direction.
3. A cashier on the admin report URL or sending a crafted `select_cashier` event: the route is admin-only (Task 5 access test); the cashier page ignores any user id (Task 6).
4. Invalid dates in the report filter (`"2026-13-01"`, empty) must show "Pilih rentang tanggal yang valid." rather than crash (Tasks 5 and 6).
5. An admin in "Semua cabang" must never see another organization's cashiers (Task 3 `in_org/2` test).

---

### Task 1: Rates — table, schema, settings functions

**Files:**
- Create: `priv/repo/migrations/20261101090000_create_service_commissions.exs`
- Create: `lib/zahlungs/services/commission_rate.ex`
- Create: `lib/zahlungs/services/commissions.ex`
- Modify: `lib/zahlungs/services.ex` (defdelegates, near `## Products`)
- Test: `test/zahlungs/services_commission_test.exs` (new, `use Zahlungs.DataCase, async: true`)

**Interfaces:**
- Produces: `Services.commission_rates() :: [%{category: String.t(), label: String.t(), percent: Decimal.t()}]` in `Services.categories/0` order; `Services.save_commission_rates(%User{}, %{String.t() => String.t()}) :: {:ok, rates} | {:error, :unauthorized} | {:error, %{String.t() => String.t()}}` (errors keyed by category, message in Indonesian); `Services.commission_percent(category) :: Decimal.t()`.

- [ ] **Step 1: Write the failing tests** (`describe "rates"`)

```elixir
test "a category without a rate is 0%" do
  assert Enum.all?(Services.commission_rates(), &Decimal.equal?(&1.percent, 0))
  assert Enum.map(Services.commission_rates(), & &1.category) ==
           Enum.map(Services.categories(), &elem(&1, 0))
  assert Decimal.equal?(Services.commission_percent("pulsa"), 0)
end

test "an admin saves every category at once; blank is 0", %{admin: admin} do
  assert {:ok, _} =
           Services.save_commission_rates(admin, %{"pulsa" => "10", "tagihan" => "12.5", "token_pln" => ""})
  assert Decimal.equal?(Services.commission_percent("pulsa"), "10")
  assert Decimal.equal?(Services.commission_percent("tagihan"), "12.5")
  assert Decimal.equal?(Services.commission_percent("token_pln"), 0)
  # Saved again: updated, not duplicated.
  assert {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "20"})
  assert Decimal.equal?(Services.commission_percent("pulsa"), "20")
end

test "one wrong value saves nothing", %{admin: admin} do
  for bad <- ["-1", "101", "abc", "1.234"] do
    assert {:error, %{"paket_data" => _}} =
             Services.save_commission_rates(admin, %{"pulsa" => "10", "paket_data" => bad})
    assert Decimal.equal?(Services.commission_percent("pulsa"), 0)
  end
end

test "a cashier can't save" do
  assert Services.save_commission_rates(user_fixture(), %{"pulsa" => "10"}) == {:error, :unauthorized}
end

test "another organization's rates are not ours", %{admin: admin} do
  in_org(organization_fixture(), fn ->
    {:ok, other} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    {:ok, _} = Services.save_commission_rates(other, %{"pulsa" => "50"})
  end)
  assert Decimal.equal?(Services.commission_percent("pulsa"), 0)
end
```

Setup: `{:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")`.

- [ ] **Step 2: Run** `mix test test/zahlungs/services_commission_test.exs` — Expected: FAIL (`Services.commission_rates/0` undefined).

- [ ] **Step 3: Implement**
  - Migration: `create table(:service_commission_rates)` with `organization_id` (references organizations, `on_delete: :restrict`, null false), `category` string size 20 null false, `percent` decimal precision 5 scale 2 null false default 0, timestamps; `unique_index([:organization_id, :category])`. Same migration: `alter table(:service_transactions) add :commission_percent, :decimal, precision: 5, scale: 2, null: false, default: 0`.
  - `Zahlungs.Services.CommissionRate` schema (`belongs_to :organization`), changeset: cast `[:category, :percent]`, `validate_inclusion(:category, Product.categories())`, `validate_number(:percent, >= 0, <= 100)`, a 2-decimal check (`Decimal.round(p, 2) == p`), `Organizations.put_organization/1`, `unique_constraint` on the index.
  - `Commissions.save_rates/2`: parse each known category's value (blank → "0"; `Decimal.parse/1` must consume the whole string), build changesets, return `{:error, %{category => message}}` before writing if any is invalid; otherwise upsert each inside `Repo.transaction` (`on_conflict: {:replace, [:percent, :updated_at]}, conflict_target: [:organization_id, :category]`). Unknown keys ignored.
  - `Services`: `defdelegate commission_rates, to: Commissions, as: :rates` etc.

- [ ] **Step 4: Run** the same test file — Expected: PASS.

- [ ] **Step 5: Commit** `feat(komisi-kasir): commission percent per service category`

---

### Task 2: Copy the percent when a service is recorded; `commission/1`

**Files:**
- Modify: `lib/zahlungs/services/transaction.ex` (field `commission_percent, :decimal, default: Decimal.new(0)`; not in any `cast`)
- Modify: `lib/zahlungs/services.ex` (`insert_transaction/3`: set `commission_percent`)
- Modify: `lib/zahlungs/services/commissions.ex`
- Test: `test/zahlungs/services_commission_test.exs` (`describe "recording"`, `describe "commission/1"`)

**Interfaces:**
- Consumes: `Commissions.percent(category)` (Task 1).
- Produces: `Commissions.percent_for(%User{}, category) :: Decimal.t()` (role read from DB: `cashier` → rate, else 0); `Services.commission(%Transaction{}) :: Decimal.t()` (whole rupiah).

- [ ] **Step 1: Write the failing tests**

Setup: `assign_account(default_store(), deposit_account_fixture())`, `cashier = user_on_shift_fixture()`, admin as in Task 1, `{:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10", "tagihan" => "12.5"})`, `pulsa = service_product_fixture()` (price 12.000, cost 10.150, margin 1.850).

```elixir
test "a cashier's service carries the category's percent", ctx do
  tx = service_fixture(ctx.cashier, ctx.pulsa)
  assert Decimal.equal?(tx.commission_percent, "10")
end

test "the role is read from the database, not the struct", ctx do
  {:ok, _} = Zahlungs.Accounts.set_user_role(ctx.cashier, "admin")
  tx = service_fixture(ctx.cashier, ctx.pulsa)   # stale struct still says cashier
  assert Decimal.equal?(tx.commission_percent, 0)
end

test "the percent can't come from the caller", ctx do
  tx = service_fixture(ctx.cashier, ctx.pulsa, %{"commission_percent" => "99"})
  assert Decimal.equal?(tx.commission_percent, "10")
end

test "a later change of percent leaves recorded services alone", ctx do
  tx = service_fixture(ctx.cashier, ctx.pulsa)
  {:ok, _} = Services.save_commission_rates(ctx.admin, %{"pulsa" => "50"})
  assert Decimal.equal?(Repo.get!(Services.Transaction, tx.id).commission_percent, "10")
end
```

`describe "commission/1"` (on structs, no DB): `%Transaction{status: "success", price: 12000, cost: 10150, commission_percent: 10}` → 185; `price 12000, cost 10001, percent 12.5` → 249; status `"processing"` / `"failed"` → 0; `cost > price` → 0. All with `Decimal.equal?`.

- [ ] **Step 2: Run** — Expected: FAIL (no `commission_percent` field / `commission/1` undefined).

- [ ] **Step 3: Implement** — in `insert_transaction/3` add `commission_percent: Commissions.percent_for(user, product.category)` to the struct; `percent_for/2` reads `select: u.role` for `user.id`. `commission/1`: `price |> Decimal.sub(cost) |> Decimal.max(0) |> Decimal.mult(percent) |> Decimal.div(100) |> Decimal.round(0, :floor)` for `"success"`, else `Decimal.new(0)`.

- [ ] **Step 4: Run** `mix test test/zahlungs/services_commission_test.exs test/zahlungs/services_test.exs` — Expected: PASS.

- [ ] **Step 5: Commit** `feat(komisi-kasir): services carry the cashier's commission percent`

---

### Task 3: Shift total, commission report, details, service report figures

**Files:**
- Modify: `lib/zahlungs/services/commissions.ex`, `lib/zahlungs/services.ex` (`report/3` adds `commission`, `net_margin`; delegates)
- Test: `test/zahlungs/services_commission_test.exs` (`describe "report"`), `test/zahlungs/services_test.exs` (`report/3` describe: one assertion block)

**Interfaces:**
- Produces:
  - `Services.shift_commission(%Shift{}) :: Decimal.t()`
  - `Services.commission_report(%Scope{}, Date.t(), Date.t()) :: %{rows: [%{user_id, name, count, margin, commission}], count, margin, commission}` (rows by name; only `success` with `commission_percent > 0`; cashier scope → own row only)
  - `Services.commission_details(%Scope{}, user_id, Date.t(), Date.t()) :: [%{id, code, inserted_at, product_name, category, margin, percent, commission}]` newest first; cashier scope → `user_id` ignored, own rows
  - `report/3` map gains `commission` and `net_margin`.

- [ ] **Step 1: Write the failing tests**

Setup: rates pulsa 10%, two cashiers on shift (`a`, `b`), an admin on a shift (`admin_on_shift = user_on_shift_fixture()` then `set_user_role(..., "admin")` → use returned struct), deposit account assigned. Successes via `Services.mark_success(tx, user, nil)`: `a` ×2 pulsa, `b` ×1 pulsa, admin ×1 pulsa; `a` one failed (`mark_failed`), `a` one processing. `today = LocalTime.today()`.

```elixir
test "per cashier: successful services only; admins earn none", ctx do
  report = Services.commission_report(store_scope(), ctx.today, ctx.today)
  assert Enum.map(report.rows, &{&1.user_id, &1.count}) |> Enum.sort() ==
           Enum.sort([{ctx.a.id, 2}, {ctx.b.id, 1}])
  row_a = Enum.find(report.rows, &(&1.user_id == ctx.a.id))
  assert Decimal.equal?(row_a.commission, 370) and Decimal.equal?(row_a.margin, 3700)
  assert Decimal.equal?(report.commission, 555) and report.count == 3
end

test "the total is the sum of the details", ctx do
  details = Services.commission_details(store_scope(), ctx.a.id, ctx.today, ctx.today)
  assert length(details) == 2
  assert Enum.reduce(details, Decimal.new(0), &Decimal.add(&1.commission, &2)) |> Decimal.equal?(370)
end

test "a cashier sees only themself", ctx do
  scope = Zahlungs.Scope.for_user(ctx.a)
  assert [%{user_id: id}] = Services.commission_report(scope, ctx.today, ctx.today).rows
  assert id == ctx.a.id
  assert Services.commission_details(scope, ctx.b.id, ctx.today, ctx.today) |> length() == 2
end

test "another day is empty", ctx do
  assert Services.commission_report(store_scope(), ~D[2001-01-01], ~D[2001-01-31]).rows == []
end

test "shift_commission/1 adds up a shift's", ctx do
  assert Decimal.equal?(Services.shift_commission(Zahlungs.Shifts.current_shift(ctx.a)), 370)
end
```

Plus, in a separate `describe "the final status and cost"` with the api setup of `services_review_test.exs` (api account, cashier `shift_fixture`, pulsa `provider_code: "TSEL10"`, rate pulsa 10%, tx to `081234567899`):
  - `apply_result(tx.id, success(%{actual_cost: d("10500")}))` → `commission(fresh(tx))` = 150 (margin 1.500).
  - success then `apply_result(%{status: :refunded, ...})` then `resolve_review(fresh(tx), admin, :refund)` → commission 0 and not in `commission_report`.

And "all stores leaves other organizations out": an admin with `Scope.for_user(admin)` with store nil (`%{scope | store: nil}` as other "all stores" tests do — copy their construction) sees `a` and `b`, not a cashier who succeeded inside `in_org(organization_fixture(), ...)`.

In `services_test.exs` `report/3` describe, after saving pulsa 10% *before* the setup records (add the `save_commission_rates` call at the top of that setup): `report.commission` = 185 (one pulsa success by the cashier; token PLN 0%), `net_margin` = `margin − 185`.

- [ ] **Step 2: Run** — Expected: FAIL (functions undefined).

- [ ] **Step 3: Implement** — one private `commission_expr` via `dynamic`/`fragment("FLOOR(GREATEST(? - ?, 0) * ? / 100)", t.price, t.cost, t.commission_percent)` used by report, details, shift total and `report/3`; Commissions gets its own 5-line `for_store/2` (same as Services'). Report groups by `t.user_id` joined to `users` for the name (`skip_org_id` not needed: root is `service_transactions`). Sums through `coalesce(..., 0)`, converted with `Decimal.new/1` when the driver returns integers.

- [ ] **Step 4: Run** `mix test test/zahlungs/services_commission_test.exs test/zahlungs/services_test.exs test/zahlungs/services_review_test.exs` — Expected: PASS.

- [ ] **Step 5: Commit** `feat(komisi-kasir): commission per cashier, per shift and in the service report`

---

### Task 4: Admin page for the percents

**Files:**
- Create: `lib/zahlungs_web/live/service_commission_live.ex` (`ZahlungsWeb.ServiceCommissionLive`)
- Modify: `lib/zahlungs_web/router.ex` (admin live_session: `live "/admin/services/commission", ServiceCommissionLive, :index` above `/admin/services/new`)
- Modify: `lib/zahlungs_web/live/service_product_live/index.ex` (header action link "Komisi kasir")
- Test: `test/zahlungs_web/live/service_commission_live_test.exs`

**Interfaces:**
- Consumes: `Services.commission_rates/0`, `Services.save_commission_rates/2` (Task 1).
- Events: `"save"` with `%{"rates" => %{category => value}}`.

- [ ] **Step 1: Write the failing tests**
  - cashier `get("/admin/services/commission")` → redirected to `"/"`; admin → 200 containing "Komisi kasir".
  - `mount_live(ServiceCommissionLive, admin)` html has `name="rates[pulsa]"` … for all four categories and the text "Perubahan berlaku untuk transaksi berikutnya".
  - `event("save", %{"rates" => %{"pulsa" => "10"}})` → `flash(socket, :info) == "Persen komisi disimpan."` and `Services.commission_percent("pulsa")` = 10.
  - `event("save", %{"rates" => %{"pulsa" => "101"}})` → html shows the error message next to Pulsa, nothing saved.
  - `ServiceProductLive.Index` html contains `href="/admin/services/commission"`.

- [ ] **Step 2: Run** — Expected: FAIL.

- [ ] **Step 3: Implement** — assigns `rates` (from `commission_rates/0`), `values` (category → string), `errors` (map). Form `phx-submit="save"`, per category a number input `name={"rates[#{c}]"}` `step="0.01" min="0" max="100"`, the error under it, one Simpan button. On `{:error, errors}` keep the typed values. `<.header>` "Komisi kasir" with subtitle "Persen dari margin transaksi layanan yang sukses (khusus admin)" and the explanatory sentence from the spec.

- [ ] **Step 4: Run** the new test file and `test/zahlungs_web/live/service_product_live_test.exs` — Expected: PASS.

- [ ] **Step 5: Commit** `feat(komisi-kasir): admins set the commission percent per category`

---

### Task 5: Admin commission report and the service report cards

**Files:**
- Create: `lib/zahlungs_web/live/report_live/commissions.ex` (`ZahlungsWeb.ReportLive.Commissions`)
- Modify: `lib/zahlungs_web/router.ex` (`live "/reports/commissions", ReportLive.Commissions, :index` in the admin live_session)
- Modify: `lib/zahlungs_web/components/layouts.ex` (`admin_links/0`: `{"Komisi kasir", ~p"/reports/commissions"}` after "Laporan layanan")
- Modify: `lib/zahlungs_web/live/report_live/services.ex` (cards "Komisi kasir", "Margin bersih"; grid `lg:grid-cols-7`)
- Test: `test/zahlungs_web/live/report_commissions_live_test.exs`, `test/zahlungs_web/live/report_live_test.exs` (or wherever the services report is tested — grep `ReportLive.Services`)

**Interfaces:**
- Consumes: `commission_report/3`, `commission_details/4` (Task 3).
- Events: `"filter"` `%{"from", "to"}` (ISO dates, like `ReportLive.Services`); `"select_cashier"` `%{"id" => id}` (integer or string).

- [ ] **Step 1: Write the failing tests**
  - cashier `get("/reports/commissions")` → redirected to `"/"`.
  - with the Task 3 style setup (rate 10%, cashier one pulsa success): mount → html has the cashier's email/name and "Rp 185,00"; `event("filter", %{"from" => "2001-01-01", "to" => "2001-01-31"})` → no cashier row, "Belum ada komisi" shown; `event("filter", %{"from" => "x", "to" => ""})` → "Pilih rentang tanggal yang valid."; `event("select_cashier", %{"id" => cashier.id})` → html shows the transaction's `code`; same with `"#{cashier.id}"`.
  - services report: html contains "Komisi kasir" and "Margin bersih".

- [ ] **Step 2: Run** — Expected: FAIL.

- [ ] **Step 3: Implement** — mirror `ReportLive.Services` (mount dates, `load_report/1` with `Date.from_iso8601`); table `id="commissions-by-cashier"` (Kasir, Transaksi, Margin, Komisi) with a total row; the name is a `phx-click={JS.push("select_cashier", value: %{id: row.user_id})}` link; details table `id="commission-details"` under it (Waktu via `LocalTime`, Kode, Produk, Margin, Persen, Komisi). Changing the filter keeps the selected cashier and reloads the details.

- [ ] **Step 4: Run** both test files — Expected: PASS.

- [ ] **Step 5: Commit** `feat(komisi-kasir): the commission report for admins`

---

### Task 6: "Komisi saya", the Layanan screen line, docs

**Files:**
- Create: `lib/zahlungs_web/live/commission_live.ex` (`ZahlungsWeb.CommissionLive`)
- Modify: `lib/zahlungs_web/router.ex` (authenticated live_session: `live "/commissions", CommissionLive, :index`)
- Modify: `lib/zahlungs_web/components/layouts.ex` (cashier menu: "Komisi saya" for `role == "cashier"` only — `cashier_links/0` is shared, so add it where the Kasir group is built: `cashier_links() ++ if(@current_user.role == "cashier", do: [{"Komisi saya", ~p"/commissions"}], else: [])`)
- Modify: `lib/zahlungs_web/live/service_live/index.ex` (`load_transactions/1` also assigns `commission: Services.shift_commission(shift)` for a cashier, nil otherwise; render "Komisi shift ini: {format_money(@commission)}" near "Riwayat shift ini" when not nil)
- Modify: `docs/IA.md` (three routes and who sees them), `CLAUDE.md` (table list + a "Commission" bullet in the PPOB section)
- Test: `test/zahlungs_web/live/commission_live_test.exs`, `test/zahlungs_web/live/service_live_test.exs`

**Interfaces:**
- Consumes: `commission_report/3`, `commission_details/4`, `shift_commission/1` (Task 3).
- Events: `"filter"` as in Task 5. No user id is accepted anywhere.

- [ ] **Step 1: Write the failing tests**
  - cashier `get("/commissions")` → 200 with "Komisi saya"; admin → redirected to `"/reports/commissions"` (mount does `push_navigate`; assert via `live_redirect(mount_live(CommissionLive, admin))` or the `get` redirect — use whichever the existing admin-redirect LiveViews' tests use).
  - two cashiers each with a success (rate 10%): cashier A's page shows A's transaction code and "Rp 185,00" total, not B's code; invalid dates → "Pilih rentang tanggal yang valid.".
  - Layanan: cashier with a success → html has "Komisi shift ini" and "Rp 185,00"; after `info(socket, {:service_changed, tx.id})` it is reloaded; an admin's Layanan html has no "Komisi shift ini".

- [ ] **Step 2: Run** — Expected: FAIL.

- [ ] **Step 3: Implement** as listed under Files; `CommissionLive` reuses the report shape with `Zahlungs.Scope` of the current user (no store switch for cashiers), showing totals then details.

- [ ] **Step 4: Run** `mix test` (whole suite), `mix format --check-formatted`, `mix credo --strict` — Expected: all tests pass; no new credo issue in touched files.

- [ ] **Step 5: Commit** `feat(komisi-kasir): cashiers see their own commission` (docs in the same commit)
