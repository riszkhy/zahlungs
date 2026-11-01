# Promo potongan per produk/kategori Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admins define percent/rupiah discounts on products or categories for a date range and chosen stores; the cashier and the sale apply them per line automatically, and reports show what each promotion took off.

**Architecture:** New owned tables `promotions`, `promotion_targets`, `promotion_stores` in a new context `Zahlungs.Promotions`, whose pure `apply/2` is the one rule both the cashier screen and `Sales.create_sale/3` use. Sale lines store their own `discount` and a promotion snapshot; `line_total` is net. `create_sale/3` moves its totals into the transaction (the promotions depend on the shift's store), keeping the credit customer's lock as the transaction's first read.

**Tech Stack:** Phoenix 1.8 / LiveView 1.2, Ecto + MyXQL, ExUnit with `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-10-31-promo-produk-design.md`

## Global Constraints

- No new dependencies. LiveViews call contexts only.
- Money is `Decimal`; percent discounts are floored to whole rupiah. Dates via `LocalTime.today(store)`.
- `promotions` carries `organization_id` (Repo guard); targets/stores are checked to belong to the organization.
- Consignment products never get a promotion.
- One promotion per line: largest discount; tie → smallest promotion `id`.
- Credit sales: the customer `FOR UPDATE` stays the first read of the sale transaction (see `Customers.lock_for_credit/2` doc) — pinned by `customers_test.exs` "the customer is locked before anything else is read".
- UI copy in Indonesian; code/comments/commits in English, `type(promo): subject` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests share the dev DB: unique names, never assert empty tables. Tests that create promotions must scope them to their own store/products (promotions are per organization, each test has its own org).

## Review Focus

1. A promotion ending yesterday (store-local) or starting tomorrow must not apply; the boundary days themselves must. Test in Task 2.
2. A rupiah discount larger than the price (e.g. Rp 5.000 off a Rp 3.000 item) must cap at the line, never a negative line. Test in Task 2.
3. A screen showing a promo that has since been deactivated must not sell at the promo price — the server recomputes. Test in Task 3.
4. A cashier's manual discount over the limit is refused even when the screen check is bypassed; an admin's isn't. Test in Task 3.
5. Old sales (before this feature) keep identical report figures (discount 0, line_total unchanged). Test in Task 3 (report on a sale without promotions).

---

### Task 1: Promotions — schema, migration, admin CRUD, cashier discount limit

**Files:**
- Create: `priv/repo/migrations/20261031120000_create_promotions.exs`, `lib/zahlungs/promotions.ex`, `lib/zahlungs/promotions/promotion.ex`, `lib/zahlungs/promotions/promotion_target.ex`, `lib/zahlungs/promotions/promotion_store.ex`, `test/support/fixtures/promotions_fixtures.ex`, `test/zahlungs/promotions_test.exs`
- Modify: `lib/zahlungs/organizations/organization.ex` (field), `lib/zahlungs/sales/sale_item.ex` (fields + cast)

**Interfaces:**
- Produces:
  - Migration: `promotions` (`organization_id` FK not null, `name` 80, `kind` string 10, `value` decimal(12,2), `starts_on`/`ends_on` date, `all_stores` bool default true, `active` bool default true, timestamps; index `[:organization_id, :ends_on]`); `promotion_targets` (`promotion_id` delete_all, `product_id` nullable FK delete_all, `category_id` nullable FK delete_all; index promotion_id); `promotion_stores` (`promotion_id` delete_all, `store_id` delete_all; unique `[:promotion_id, :store_id]`); `sale_items` add `discount` decimal(12,2) not null default 0, `promotion_id` FK nilify, `promotion_name` string 80; `organizations` add `max_cashier_discount_percent` decimal(5,2) nullable.
  - `Promotion` schema: fields above, `has_many :targets`, `has_many :stores` (`PromotionStore`), virtual `product_ids`, `category_ids`, `store_ids` (lists). `Promotion.changeset/2`: required name/kind/value/starts_on/ends_on; kind in `~w(percent amount)`; value > 0 and ≤ 100 when percent; `ends_on ≥ starts_on` (error on `:ends_on`); at least one of product_ids/category_ids (error on `:product_ids`, "pilih minimal satu produk atau kategori"); when `all_stores` false, store_ids non-empty (error on `:store_ids`); `put_organization/1`.
  - `Promotions.list_promotions(today_by_store \\ nil)` → `[%{promotion, status}]` newest `starts_on` first, status `:running | :scheduled | :ended | :inactive` by `LocalTime.today(nil)`.
  - `Promotions.get_promotion!(id)` (preloads targets, stores; fills virtual id lists).
  - `Promotions.create_promotion(user, attrs)`, `update_promotion(user, promotion, attrs)`, `set_active(user, promotion, bool)`: admin only else `{:error, :unauthorized}`; ids in attrs filtered to the organization (products/categories/stores fetched through the guarded Repo; an id not found → changeset error on that field); targets/stores replaced in the same transaction.
  - `Promotions.change_promotion(promotion, attrs \\ %{})`.
  - `Promotions.cashier_discount_limit(organization_id) :: Decimal | nil`; `Promotions.set_cashier_discount_limit(user, value) :: {:ok, Organization} | {:error, :unauthorized | Ecto.Changeset}` (blank → nil; 0–100).
  - `SaleItem`: `discount` (default 0), `belongs_to :promotion`, `promotion_name`; changeset casts them.
  - `PromotionsFixtures.promotion_fixture(attrs \\ %{})` (inserts through the changeset with `product_ids` required by caller or a fresh product; defaults: name unique, `kind: "percent"`, `value: "10"`, `starts_on/ends_on` today ± 1 day in the default store's local date).

- [ ] **Step 1: Write failing tests** in `test/zahlungs/promotions_test.exs` (`describe "promotions"`): admin creates a percent promo with a product and a category → targets saved; cashier → `:unauthorized`; percent 101 → error on `:value`; `ends_on` before `starts_on` → error; no targets → error on `:product_ids`; `all_stores: false` without stores → error on `:store_ids`; another organization's product id → error, nothing saved; update replaces targets; `list_promotions` status for running / scheduled / ended / inactive; cashier discount limit: admin sets `"10"`, cashier → `:unauthorized`, `""` → nil, `"101"` → changeset error.
- [ ] **Step 2: Run** `mix test test/zahlungs/promotions_test.exs` — Expected: FAIL (module undefined).
- [ ] **Step 3: Implement** the above.
- [ ] **Step 4: Run** `mix test test/zahlungs/promotions_test.exs test/zahlungs/sales_test.exs` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(promo): promotions on products and categories, managed by the admin`.

### Task 2: The promotion engine

**Files:**
- Modify: `lib/zahlungs/promotions.ex`
- Test: `test/zahlungs/promotions_test.exs`

**Interfaces:**
- Consumes: Task 1 schemas.
- Produces:
  - `Promotions.active_for(store :: Store | nil, date :: Date) :: [Promotion]` (targets preloaded): `active`, `starts_on ≤ date ≤ ends_on`, and `all_stores` or the store in `promotion_stores`. A nil store gets only `all_stores` promotions.
  - `Promotions.apply(lines, promotions) :: lines` — pure. Each line is a map with `product: %{id, category_id, consignment}`, `quantity`, `unit_price`; returned lines gain `discount :: Decimal`, `promotion_id`, `promotion_name` (0 / nil / nil when none).
  - `Promotions.discount_for(promotion, unit_price, quantity) :: Decimal` — percent: `floor(unit_price × quantity × value / 100)` to the rupiah; amount: `value × quantity`; both capped at `unit_price × quantity`.

- [ ] **Step 1: Write failing tests** (`describe "engine"`): 10% of 12.350 × 1 → 1.235; 10% of 12.355 × 1 → 1.235 (floored); Rp 2.000 × 3 → 6.000; Rp 5.000 off a 3.000 line → 3.000; product promo 5% vs category promo Rp 1.000 on a 10.000 item → category wins (1.000 > 500); equal discounts → smaller id; consignment product → 0 and nil; no promotions → 0; `active_for`: starts today / ends today included (dates from `LocalTime.today(store)`), ended yesterday and starting tomorrow excluded, inactive excluded, `all_stores: false` with another store excluded, another organization's promotion not returned.
- [ ] **Step 2: Run** `mix test test/zahlungs/promotions_test.exs` — Expected: FAIL (undefined functions).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(promo): pick each line's best promotion`.

### Task 3: Sales apply promotions; cashier discount limit; reports

**Files:**
- Modify: `lib/zahlungs/sales.ex` (`create_sale`, `compute_totals`, `do_create_sale`, `insert_items_and_decrement_stock`, `sales_report`), `lib/zahlungs/customers.ex` (split `lock_for_credit`), `lib/zahlungs/promotions.ex` (`report/3`)
- Test: `test/zahlungs/promotions_test.exs` (`describe "sales"`), existing `sales_test.exs`, `customers_test.exs`

**Interfaces:**
- Consumes: Task 2 `active_for/2`, `apply/2`; Task 1 `cashier_discount_limit/1`.
- Produces:
  - `create_sale/3` transaction order: `:customer` (credit only: `Customers.lock_credit_customer(customer_id) :: {:ok, Customer} | {:error, :not_found | :customer_inactive}` — the first read) → `:shift` → `:store` → `:due_date` → `:items` (promotions applied with `active_for(store, LocalTime.today(store))`) → `:totals` (subtotal = Σ net line_total; existing discount/tax/payment rules; then `:discount_over_limit` when `user.role != "admin"` and limit set and discount > subtotal × limit / 100) → `:credit_limit` (credit only: `Customers.check_credit_limit(customer, debt) :: :ok | {:error, :over_credit_limit}`, balance read after the lock) → `:sale` → items/stock. Errors keep their current atoms (`:invalid_discount`, `:insufficient_payment`, `:down_payment_too_high`, …). `Customers.lock_for_credit/2` stays as `lock_credit_customer` + `check_credit_limit` for callers/tests.
  - Saved `sale_items`: `discount`, `promotion_id`, `promotion_name`, `line_total` net.
  - `Sales.sales_report/3` gains `promo_discount` (Σ `sale_items.discount` of completed sales in range).
  - `Promotions.report(scope, from, to) :: [%{promotion_id, name, items: integer, discount: Decimal, revenue: Decimal}]` grouped by `promotion_id, promotion_name` from completed sales in range, store filter like `Sales.sales_report/3`, largest discount first.

- [ ] **Step 1: Write failing tests** (`describe "sales"`): a 10% promo on a 10.000 product, sell 2 → item `discount` 2.000, `line_total` 18.000, `promotion_name` set, sale `subtotal` 18.000, `total` 18.000; deactivating the promo before checkout → no discount (server recomputes); a promo of another store (`all_stores: false`) → no discount; consignment product → no discount; cashier with limit 10%: discount 1.800 on subtotal 18.000 ok, 1.801 → `{:error, :discount_over_limit}` and stock unchanged; admin on shift with the same limit → ok; credit sale with promo: customer balance = total after promo; `sales_report.promo_discount` = 2.000 and `gross_sales` net; `Promotions.report` one row with discount 2.000 and revenue 18.000; a sale without promotions keeps `discount` 0 and `line_total = unit_price × qty`.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement.** Keep `build_items/1` outside the transaction (products only); everything depending on the store moves into the `Multi`.
- [ ] **Step 4: Run** `mix test test/zahlungs` — Expected: PASS (including "the customer is locked before anything else is read").
- [ ] **Step 5: Commit** `feat(promo): sales apply promotions per line, and the cashier discount limit`.

### Task 4: Admin promotions page and report UI

**Files:**
- Create: `lib/zahlungs_web/live/promotion_live/index.ex`, `test/zahlungs_web/live/promotion_live_test.exs`
- Modify: `lib/zahlungs_web/router.ex` (admin `live_session`: `/admin/promotions` `:index`, `/admin/promotions/new` `:new`, `/admin/promotions/:id/edit` `:edit`), `lib/zahlungs_web/components/layouts.ex` (admin link "Promo"), `lib/zahlungs_web/live/report_live/index.ex`

**Interfaces:**
- Consumes: Task 1 CRUD + limit; Task 3 `sales_report.promo_discount`, `Promotions.report/3`.
- Produces: inline form in the index (no live component, like `CustomerLive.Index`), events `"save"` (`%{"promotion" => params}` with `product_ids[]`, `category_ids[]`, `store_ids[]`), `"product_search"` (`q`) / `"add_product"` / `"remove_product"` (`id`) for picking products, `"toggle_active"` (`id`), `"save_limit"` (`%{"limit" => v}`); status badges Berjalan / Terjadwal / Selesai / Nonaktif. Sales report: card "Potongan promo" and table "Per promo".

- [ ] **Step 1: Write failing tests**: cashier `get "/admin/promotions"` → redirect "/"; admin 200 with "Promo"; LiveDriver: `:new` → add a product → save → promotion listed; `"toggle_active"` flips; `"save_limit"` stores 10; sales report html shows "Potongan promo" and the promotion's name after a promoted sale.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix test test/zahlungs_web` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(promo): the admin's promotions page and the promotion report`.

### Task 5: Cashier screen, receipts, docs

**Files:**
- Modify: `lib/zahlungs_web/live/cashier_live.ex`, `lib/zahlungs_web/components/core_components.ex` (`sale_receipt`), `lib/zahlungs_web/controllers/receipt_html/show.html.heex`, `CLAUDE.md`, `docs/IA.md`
- Test: `test/zahlungs_web/live/cashier_live_test.exs`, `test/zahlungs_web/controllers/receipt_controller_test.exs`

**Interfaces:**
- Consumes: `Promotions.active_for/2`, `apply/2`, `cashier_discount_limit/1`.
- Produces: cart items gain `category_id`, `consignment`, and after `apply/2`: `discount`, `promotion_name`, `line_total`; assign `promotions` (loaded in `assign_shift/2` for the shift's store and today, `[]` without a shift), `promo_saving` (Σ discount), `discount_limit`; `cart_subtotal` = Σ net lines; manual discount over limit for a non-admin → `amount_error` "Diskon maksimal N% dari subtotal." (N formatted without trailing zeros); `error_message(:discount_over_limit)` = same text. Cart row: struck normal price + "Nama promo" + "−Rp X". Summary row "Hemat promo" when > 0. Receipts: per promoted item a line "Promo: nama −Rp X"; "Hemat promo" total when > 0. Held carts: unchanged (prices and promotions are re-read on resume).

- [ ] **Step 1: Write failing tests**: with a 10% promo on a 10.000 product, `add` → cart line discount 1.000, `html` has "Hemat promo" and the promo name, `total` 9.000; checkout → `last_sale` item discount 1.000; cashier with limit 10% typing discount 901 on subtotal 9.000 → `can_checkout` false and message; printed receipt of a promoted sale contains the promo name.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix test` — Expected: PASS; `mix credo` — no issues.
- [ ] **Step 5: Docs** — `CLAUDE.md`: `promotions.ex` bullet (engine, one per line, consignment excluded, recomputed in the sale transaction, limit on cashier discounts), tables list; invariant "Sale items carry their promotion discount; `line_total` is net". `docs/IA.md`: `/admin/promotions`, cashier promo display, report card.
- [ ] **Step 6: Commit** `feat(promo): the cashier shows and applies promotions`.
