# Piutang (kasbon) di Kasir Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Known customers take goods now and pay later (at once or in instalments), within a credit limit set by the admin, with a per-customer ledger and a receivables report.

**Architecture:** A new owned table `customers` and a per-store table `customer_payments`, in a new context `Zahlungs.Customers`. A credit sale is an ordinary `sale` with `payment_method: "credit"`, `customer_id`, `due_date`, and `amount_paid` = cash down payment. The balance is always computed (credit debt of counted notes − payments + overpayment refunds); allocation to notes (oldest first) is computed on read, never stored.

**Tech Stack:** Phoenix 1.8 / LiveView 1.2, Ecto + MyXQL, ExUnit with `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-10-31-kasir-piutang-design.md`

## Global Constraints

- No new dependencies. LiveViews and controllers call contexts only, never `Repo`/schemas.
- Money is `Decimal`; displayed with `format_money/1`. Dates for people via `Zahlungs.LocalTime` (`LocalTime.today(store)`), never `Date.utc_today/0`.
- Store, shift and user never come from params: always the acting user's open shift (`Shifts.lock_current_shift/1`).
- `customers` carries `organization_id` (Repo guard); `customer_payments` has none (per store, like `sales`).
- State changes lock rows (`FOR UPDATE`) and re-read from the database.
- Event handlers accept ids as integer or string (JSON numbers from `JS.push`).
- UI copy in Indonesian as in the spec; code, comments, commits in English. Commit format `type(kasir-piutang): subject` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests share the dev DB: find fixtures by unique name, never assert a table is empty.

## Review Focus

1. Two tablets selling on credit to the same customer at the same time — the second must be refused when the sum exceeds the limit (row lock on the customer inside the sale transaction). Test in Task 2 (sequential stale-struct test; the lock is reviewed).
2. A credit sale returned after its shift closed must refund only the down payment, not the total. Test in Task 3.
3. Down payment left blank — it must mean 0, not an error (the cashier's `CurrencyInput` sends plain digits or `""`). Test in Task 2.
4. Overdue uses the note's store's local date, not UTC: a note due "today" is not overdue at 23:30 WIB. Test in Task 3 with `LocalTime`.
5. A cashier crafting events (`update_customer`, `cancel_payment`, `refund_overpayment`) must be refused in the context, not just hidden. Tests in Tasks 1 and 3.

---

### Task 1: Customers — schema, migration, CRUD

**Files:**
- Create: `priv/repo/migrations/20261031090000_create_customers.exs`
- Create: `lib/zahlungs/customers.ex`, `lib/zahlungs/customers/customer.ex`, `lib/zahlungs/customers/payment.ex`
- Create: `test/support/fixtures/customers_fixtures.ex`, `test/zahlungs/customers_test.exs`
- Modify: `lib/zahlungs/sales/sale.ex` (fields only), `lib/zahlungs/shifts/cash_movement.ex` (field + category)

**Interfaces:**
- Produces:
  - Migration: `customers` (`organization_id` FK, `name` string 80 not null, `phone` 20, `note` 255, `credit_limit` decimal(12,2) default 0, `active` boolean default true, timestamps; unique index `[:organization_id, :name]`); `sales` add `customer_id` (FK customers, restrict, nullable, indexed) and `due_date` date; `customer_payments` (`customer_id` restrict, `store_id` restrict, `shift_id` restrict, `user_id` restrict, `amount` decimal(12,2), `payment_method` string 20, `note` 255, `cancelled_at` naive_datetime, `cancelled_by_id` FK users nilify, `cancel_reason` 255, timestamps; index `[:customer_id]`, `[:shift_id]`); `cash_movements` add `customer_id` (FK customers, nilify, nullable).
  - `Customer.changeset(customer, attrs)` casts `name, phone, note`; `Customer.admin_changeset(customer, attrs)` = changeset + `credit_limit` (≥ 0), `active`; both call `Organizations.put_organization/1`, `unsafe_validate_unique([:name, :organization_id], Repo)` and `unique_constraint(:name, name: :customers_organization_id_name_index)`.
  - `Payment` schema (`customer_payments`) with `changeset/2` (amount > 0, `payment_method` in `~w(cash qris card transfer)`, note ≤ 255) and `cancel_changeset(payment, user_id, reason)` (reason required, ≤ 255).
  - `Sale`: `belongs_to :customer`, `field :due_date, :date`; `"credit"` added to `@payment_methods`; changeset casts `customer_id`, `due_date`.
  - `CashMovement`: `"customer_refund" => "out"`, `belongs_to :customer`, cast `customer_id`.
  - `Customers.list_customers(opts)` → `[%Customer{}]` ordered by name; opts `q:` (name or phone contains), `active_only:` (default false).
  - `Customers.get_customer!(id)`; `Customers.create_customer(user, attrs)` → admin uses `admin_changeset`, anyone else `changeset` (limit forced 0); `Customers.update_customer(user, customer, attrs)` and `Customers.set_active(user, customer, bool)` → `{:error, :unauthorized}` unless `user.role == "admin"`.
  - `CustomersFixtures.customer_fixture(attrs \\ %{})` → inserted with `admin_changeset`, default `name: "Pelanggan #{System.unique_integer([:positive])}"`, `credit_limit: "1000000"`.

- [ ] **Step 1: Write the failing tests** in `test/zahlungs/customers_test.exs` (`use Zahlungs.DataCase, async: true`):
  - `"a cashier's new customer gets no credit"`: `create_customer(user_fixture(), %{"name" => "Bu Ani #{n}", "credit_limit" => "500000"})` → `{:ok, c}`, `Decimal.equal?(c.credit_limit, 0)`.
  - `"an admin sets the limit"`: admin (via `Accounts.set_user_role(user_fixture(), "admin")`) creates with `"credit_limit" => "500000"` → 500000.
  - `"names are unique per organization, ignoring case"`: second `"bu ani #{n}"` → `{:error, changeset}` with `errors_on(cs)[:name]`; same name in `organization_fixture/1` + `in_org/2` → ok.
  - `"only an admin updates or deactivates"`: cashier `update_customer` / `set_active` → `{:error, :unauthorized}`; admin → ok.
  - `"list searches name and phone, active only"`.
  - `"another organization's customer is not found"`: `get_customer!` inside `in_org(other, …)` of the default org's customer raises `Ecto.NoResultsError`.
- [ ] **Step 2: Run** `mix test test/zahlungs/customers_test.exs` — Expected: FAIL (module `Zahlungs.Customers` undefined).
- [ ] **Step 3: Implement** the migration, schemas, field additions and the CRUD functions above. Each function first calls `Repo.put_org_id(user.organization_id)` when given a user.
- [ ] **Step 4: Run** `mix test test/zahlungs/customers_test.exs test/zahlungs/sales_test.exs test/zahlungs/shifts_test.exs` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(kasir-piutang): customers with a credit limit set by the admin`.

### Task 2: Credit sale, balance, limit, shift cash

**Files:**
- Modify: `lib/zahlungs/customers.ex`, `lib/zahlungs/sales.ex` (`compute_totals/settle`, `do_create_sale`, `sales_report`), `lib/zahlungs/shifts.ex` (`expected_cash`, `shift_summary`, `cash_sales_total`)
- Test: `test/zahlungs/customers_test.exs`, `test/zahlungs/sales_test.exs`, `test/zahlungs/shifts_test.exs`

**Interfaces:**
- Consumes: Task 1 schemas and fixture.
- Produces:
  - `Customers.balance(customer_or_id) :: Decimal` = Σ(`total − amount_paid`) of sales with `customer_id`, `payment_method == "credit"`, `status == "completed"` − Σ `amount` of payments with `cancelled_at` nil + Σ `amount` of `cash_movements` with `category == "customer_refund"` and that `customer_id`.
  - `Customers.available_credit(customer) :: Decimal` = `credit_limit − balance`.
  - `Customers.lock_for_credit(customer_id, debt :: Decimal) :: {:ok, Customer} | {:error, :not_found | :customer_inactive | :over_credit_limit}` — locks the customer row `FOR UPDATE` (through the org guard), recomputes the balance.
  - `Sales.create_sale(user, cart, %{payment_method: "credit", customer_id: id, due_date: Date | "YYYY-MM-DD", amount_paid: dp})`: errors `:customer_required`, `:down_payment_too_high` (dp ≥ total), `:invalid_due_date` (unparsable or before `LocalTime.today(store)` of the shift's store), plus those of `lock_for_credit`. Sale saved with `amount_paid: dp`, `change_due: 0`, `customer_id`, `due_date`. Blank dp = 0. Non-credit sales ignore `customer_id`/`due_date` (saved nil).
  - `Shifts.expected_cash/1` and `shift_summary/1` add credit down payments of counted sales and the shift's uncancelled cash `customer_payments`. `shift_summary/1` gains keys `credit_total` (Σ total of counted credit sales), `credit_down_payment`, `payments_cash`, `payments_noncash`; `noncash_total` excludes credit sales.
  - `Sales.sales_report/3` gains `credit_total` (Σ total of completed credit sales in range).
  - `Customers.payments_totals(shift_id) :: %{cash: Decimal, noncash: Decimal}` (used by `Shifts`).

- [ ] **Step 1: Write the failing tests:**
  - customers_test `"balance and limit"`: customer limit 100000; credit sale total 60000 dp 10000 → `balance == 50000`, `available_credit == 50000`.
  - sales_test `"a credit sale at exactly the limit passes, one rupiah over fails"`: limit 50000; sale with debt 50000 ok; next sale debt 1 → `{:error, :over_credit_limit}` and stock unchanged.
  - `"limit 0 or inactive customer is refused"` → `:over_credit_limit` / `:customer_inactive`.
  - `"a stale customer struct doesn't help"`: load customer, raise its debt through another sale, then sell using the old struct's id → refused.
  - `"down payment rules"`: dp `""` → saved 0; dp == total → `:down_payment_too_high`; no `customer_id` → `:customer_required`.
  - `"due date in the past is refused"`: `Date.add(LocalTime.today(store), -1)` → `:invalid_due_date`; today → ok.
  - `"another organization's customer can't be sold to"` → `:not_found`.
  - shifts_test `"down payment and cash repayments count in the drawer"`: opening 0, credit sale total 60000 dp 10000 → `expected_cash == 10000`; `shift_summary` has `credit_total 60000`, `credit_down_payment 10000`, `noncash_total 0`. (Repayment part added in Task 3.)
  - sales_test `"credit sales count in the sales report"`: `sales_report(...).revenue` includes it, `credit_total == total`.
- [ ] **Step 2: Run** the three test files — Expected: FAIL (unknown payment method / undefined functions).
- [ ] **Step 3: Implement.** In `settle/2` add a `"credit"` clause; the customer lock runs in `do_create_sale` as a `Multi.run(:customer, …)` after `:store` (needs the store for the due-date check), before `:sale`.
- [ ] **Step 4: Run** `mix test test/zahlungs` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(kasir-piutang): sell on credit within the customer's limit`.

### Task 3: Repayments, cancel, return/void, overpayment, ledger

**Files:**
- Modify: `lib/zahlungs/customers.ex`, `lib/zahlungs/sales.ex` (`record_refund`)
- Test: `test/zahlungs/customers_test.exs`, `test/zahlungs/sales_test.exs`, `test/zahlungs/shifts_test.exs`

**Interfaces:**
- Consumes: Task 2 functions.
- Produces:
  - `Customers.receive_payment(user, customer_id, attrs) :: {:ok, Payment} | {:error, :no_open_shift | :not_found | :over_balance | Ecto.Changeset}` — attrs `"amount"`, `"payment_method"`, `"note"`; locks shift then customer; `amount ≤ balance`.
  - `Customers.get_payment!(scope, id)` — payment whose store is in the scope's organization's stores (`Stores.store_ids/0`) or the scope's store; preloads customer, user, store.
  - `Customers.cancel_payment(user, payment_id, reason) :: {:ok, Payment} | {:error, :unauthorized | :not_found | :already_cancelled | :shift_closed | Ecto.Changeset}`.
  - `Customers.refund_overpayment(user, customer_id, amount) :: {:ok, CashMovement} | {:error, :unauthorized | :no_open_shift | :over_overpayment}`; note `"Kelebihan bayar #{customer.name}"`.
  - `Customers.ledger(customer) :: [entry]`, oldest first, entry = `%{kind: :sale | :payment | :refund, at: NaiveDateTime, amount: Decimal, balance: Decimal, ...}`; sale entries add `sale`, `remaining`, `overdue?`, `status: :paid | :open | :cancelled`; payment entries add `payment`, `cancelled?`, `settles: [%{code, remaining}]`. Cancelled payments and returned/voided sales appear but don't move `balance`.
  - `Customers.open_notes(customer)` → `[%{sale, remaining, overdue?}]` with remaining > 0, oldest first (for the cashier panel).
  - Allocation algorithm (only non-obvious part): walk counted credit sales by `inserted_at, id`; a pool = Σ uncancelled payments − Σ customer_refund; each sale takes `min(pool, debt)`; for payment `settles`, replay payments in order against the same queue.
  - `Sales.return_sale/2`: for `"credit"` sales the cash refund amount is `amount_paid` (when > 0), otherwise unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `"partial then full repayment"`: debt 50000; pay 20000 cash → balance 30000; pay 30000 qris → 0; pay 1 → `:over_balance`.
  - `"repayment needs an open shift"` → `:no_open_shift`.
  - `"cash repayment counts in the receiving shift, non-cash doesn't"` (shifts_test): second store user on shift receives 20000 cash → their `expected_cash` +20000, `shift_summary.payments_cash 20000`; 5000 transfer → `payments_noncash 5000`, drawer unchanged; the payment's `store_id` is that user's store.
  - `"oldest note first"`: notes A (debt 30000) then B (20000); pay 40000 → `open_notes` = [B remaining 10000]; ledger payment `settles == [%{code: A.code, remaining: 0}, %{code: B.code, remaining: 10000}]`; ledger balances 30000, 50000, 10000.
  - `"overdue uses the store's local date"`: note with `due_date` = `LocalTime.today(store)` → not overdue; updated (via `Repo.update_all` in test) to yesterday → overdue.
  - `"only an admin cancels, while the shift is open"`: cashier → `:unauthorized`; admin → ok, balance restored, `expected_cash` back; again → `:already_cancelled`; after `Shifts.close_shift` → `:shift_closed`.
  - `"returning a paid-in-part note leaves an overpayment"`: debt 50000 dp 0; pay 20000; admin returns the sale → balance −20000; next credit sale debt 30000 → balance 10000.
  - `"refund_overpayment"`: balance −20000; cashier → `:unauthorized`; admin 25000 → `:over_overpayment`; 20000 → `{:ok, movement}` with category `customer_refund`, balance 0, admin's `expected_cash` −20000.
  - sales_test `"a credit sale returned after its shift closed refunds the down payment only"`: total 60000 dp 10000; close shift; admin with open shift returns → `refund` cash-out of 10000.
- [ ] **Step 2: Run** — Expected: FAIL (undefined functions; refund 60000).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix test test/zahlungs` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(kasir-piutang): repayments, cancellations and the customer ledger`.

### Task 4: Admin customer pages and receivables report

**Files:**
- Create: `lib/zahlungs_web/live/customer_live/index.ex`, `lib/zahlungs_web/live/customer_live/form_component.ex`, `lib/zahlungs_web/live/customer_live/show.ex`, `lib/zahlungs_web/live/report_live/receivables.ex`
- Modify: `lib/zahlungs/customers.ex` (reports), `lib/zahlungs_web/router.ex` (admin `live_session`), navigation in `lib/zahlungs_web/components/layouts.ex` next to Suppliers / reports links
- Test: `test/zahlungs/customers_test.exs`, `test/zahlungs_web/live/customer_live_test.exs`

**Interfaces:**
- Consumes: Task 1–3 functions.
- Produces:
  - Routes: `/admin/customers` (`:index`), `/admin/customers/new` (`:new`), `/admin/customers/:id/edit` (`:edit`), `/admin/customers/:id` (`CustomerLive.Show`), `/reports/receivables` (`ReportLive.Receivables`).
  - `Customers.receivables_report(opts) :: %{total: Decimal, rows: [%{customer, balance, oldest_open: Date | nil, overdue: Decimal, last_payment_at}]}` — customers with balance > 0, opt `overdue_only: true`.
  - `Customers.payments_report(scope, from :: Date, to :: Date) :: %{by_method: [{method, Decimal}], by_store: [{store_name, Decimal}], total: Decimal}` — uncancelled payments in the local-date range (`LocalTime.day_range/3`), stores limited to `Stores.store_ids/0` or the scope's store.
  - Show page events: `"cancel_payment"` (`id`, `reason`), `"refund_overpayment"` (`amount`); both call the context (which re-checks admin) and flash the error text.
  - Index lists name, phone, balance, limit, active, search box; form fields name, phone, note, credit_limit, active.

- [ ] **Step 1: Write the failing tests:** context `"receivables report: totals, overdue filter"`, `"payments report by method and store"`; LiveDriver: index lists a fixture customer with its balance; form saves a new limit; show page renders the ledger and `cancel_payment` works for admin; `get(conn, "/admin/customers")` and `"/reports/receivables"` as a cashier redirect (not 200).
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement**, following `SupplierLive` (index + form component) and `ReportLive.Services` (date range form). Also show `credit_total` as a "Piutang" line on the sales report page (`ReportLive.Index`).
- [ ] **Step 4: Run** `mix test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(kasir-piutang): customer pages and the receivables report`.

### Task 5: Cashier screen and receipts

**Files:**
- Modify: `lib/zahlungs_web/live/cashier_live.ex`, `lib/zahlungs_web/controllers/receipt_html/show.html.heex`, `lib/zahlungs_web/router.ex`
- Create: `lib/zahlungs_web/controllers/customer_payment_receipt_controller.ex`, `lib/zahlungs_web/controllers/customer_payment_receipt_html.ex`, `lib/zahlungs_web/controllers/customer_payment_receipt_html/show.html.heex`
- Test: `test/zahlungs_web/live/cashier_live_test.exs`, `test/zahlungs_web/controllers/customer_payment_receipt_controller_test.exs`

**Interfaces:**
- Consumes: `Customers.list_customers/1`, `create_customer/2`, `balance/1`, `available_credit/1`, `open_notes/1`, `receive_payment/3`, `get_payment!/2`; `Sales.create_sale/3` credit form.
- Produces:
  - Payment method buttons: `{"credit", "Piutang"}` is enabled alongside cash (QRIS/Kartu/Transfer stay disabled as today). `set_payment_method` guard accepts `"credit"`.
  - Assigns: `credit_customer` (nil | Customer), `credit_query`, `credit_results`, `down_payment` (string), `due_date` (string, default `Date.add(LocalTime.today(store), 30)` of the open shift's store), `receivable_open` (bool), `receivable_customer`, `receivable_notes`.
  - Events: `"credit_search"` (`q`), `"credit_pick"` (`id`), `"credit_new"` (`name`, `phone`), `"credit_clear"`, `"credit_fields"` (`down_payment`, `due_date`); `"toggle_receivable"`, `"receivable_search"` (`q`), `"receivable_pick"` (`id`), `"receive_payment"` (`amount`, `payment_method`, `note`).
  - `can_checkout` for credit: customer picked, `total − dp ≤ available_credit`, dp < total. Disabled reason text `"Melebihi limit piutang #{format_money(x)}."`; new customer flash `"Pelanggan ditambahkan. Limit piutang diatur admin."`.
  - Error messages in `error_message/1`: `:over_credit_limit` → `"Melebihi limit piutang pelanggan."`, `:customer_inactive` → `"Pelanggan nonaktif."`, `:customer_required` → `"Pilih pelanggan dulu."`, `:down_payment_too_high` → `"Uang muka harus kurang dari total; pakai bayar tunai."`, `:invalid_due_date` → `"Jatuh tempo tidak boleh sebelum hari ini."`, `:over_balance` → `"Melebihi sisa utang."`.
  - Repayment form offers all four methods (Tunai, QRIS, Kartu, Transfer), default amount = balance; success flash `"Pelunasan #{format_money(amount)} diterima."` with a link to `/customer_payments/:id/receipt`.
  - Route `get "/customer_payments/:id/receipt"` in the authenticated scope next to `/sales/:id/receipt`.
  - Sale receipt for credit: customer name, `Uang muka`, `Sisa utang nota ini`, `Jatuh tempo`, `Total utang` (current balance).

- [ ] **Step 1: Write the failing tests** (LiveDriver): pick Piutang + customer + checkout → sale with `payment_method "credit"`; over the limit → `can_checkout` false and the reason shown, checkout event → flash `"Melebihi limit piutang pelanggan."` and no sale; `credit_new` creates a customer with limit 0; repayment panel: pick a customer with debt, `receive_payment` 10000 → balance reduced and flash; controller: receipt renders for the store's user, another organization's payment → 404.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement.** On mobile both panels live inside the existing cart panel (`cart-panel-open`), same as Tunda. Show the new `shift_summary` keys in the close-shift dialog and in `ShiftLive.Index` detail: "Penjualan piutang Rp X (uang muka tunai Rp Y)" and "Pelunasan piutang: tunai Rp A, non-tunai Rp B".
- [ ] **Step 4: Run** `mix test` — Expected: PASS; then `mix credo` — no new issues.
- [ ] **Step 5: Docs** — `CLAUDE.md` (`customers.ex` bullet under Architecture, tables list adds `customers`, `customer_payments`; an invariant line "A credit sale needs a customer within its limit"), `docs/IA.md` (cashier Piutang, `/admin/customers`, `/reports/receivables`).
- [ ] **Step 6: Commit** `feat(kasir-piutang): sell on credit and take repayments at the cashier`.
