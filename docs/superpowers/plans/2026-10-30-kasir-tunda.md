# Tunda keranjang di Kasir — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The cashier can hold a cart, serve the next customer, and resume the held cart later from any tablet of the same store.

**Architecture:** A new per-store pair of tables (`held_carts`, `held_cart_items`) behind a new context `Zahlungs.HeldCarts`, which always takes the store from the cashier's open shift (like `Sales.create_sale/3`). Resume locks, reads and deletes in one transaction and returns current products with their stock, so prices and stock are never stored. `CashierLive` gets a Tunda form, a "Ditunda (N)" list, swap-on-resume and a warning in the close-shift dialog.

**Tech Stack:** Elixir, Phoenix 1.8 / LiveView 1.2, Ecto + MySQL (myxql), ExUnit with `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-10-30-kasir-tunda-design.md`

## Global Constraints

- Branch `feat/kasir-tunda`; commit subjects `type(kasir-tunda): subject`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit only when the user asks (the plan's commit steps wait for that).
- No new dependencies.
- The store is **never** taken from params: every `HeldCarts` function finds the user's open shift (`Shifts.current_shift/1` / `lock_current_shift/1`) and uses its `store_id`; no shift → `{:error, :no_open_shift}` (`count/1` → 0, `list/1` → `[]`).
- `held_carts` / `held_cart_items` have no `organization_id` (per store, like `sales`). Call `Repo.put_org_id(user.organization_id)` first, as `Sales.create_sale/3` does, and load products through `Catalog` with `Scope.for_store(store)`.
- Held carts never touch `product_stocks`, `cashier_shifts`, `cash_movements` or `sales`.
- Copy (Indonesian): "Tunda", "Keranjang ditunda.", "Ditunda (N)", "Lanjutkan", "Hapus", "Sudah dilanjutkan atau dihapus di kasir lain.", "N barang disesuaikan dengan stok.", "Ada N keranjang tertunda di toko ini. Keranjang tetap tersimpan.", auto label "3 item · Rp 45.000 · 14:05".
- `note` max 60 characters; `quantity` > 0; discount/tax stored as typed (blank → 0).
- Gates before finishing: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, full `mix test`.

## Review Focus

- A held cart resumed after the discount no longer fits (items dropped, subtotal smaller): Complete Sale stays disabled with the existing inline amount error, never a crash — test in Task 3.
- Resuming while the screen's cart is empty must not create an empty held cart — test in Task 3.
- A held cart whose every product is gone resumes as an empty cart with "N barang disesuaikan", not an error — test in Task 2.
- Another store's held cart id sent by hand (resume/delete) is `:not_found` and leaves the row — test in Task 2.
- Concurrency: SQL sandbox tests share one connection, so "two tablets at once" is pinned by the row lock + delete in one transaction and tested as "the second resume of the same id is `:not_found`" (Task 2). Ruling: the spec's concurrent test becomes this sequential one.

---

### Task 1: Tables, schemas, `hold/3`, `list/1`, `count/1`

**Files:**
- Create: `priv/repo/migrations/20261030090000_create_held_carts.exs`
- Create: `lib/zahlungs/held_carts/held_cart.ex`, `lib/zahlungs/held_carts/held_cart_item.ex`
- Create: `lib/zahlungs/held_carts.ex`
- Test: `test/zahlungs/held_carts_test.exs`

**Interfaces:**
- Produces:
  - `HeldCarts.hold(user, items, attrs) :: {:ok, %HeldCart{items: [%HeldCartItem{}]}} | {:error, :no_open_shift | :empty_cart | Ecto.Changeset.t()}` — `items`: `[%{product_id: id, quantity: pos_integer}]`; `attrs`: map with `"note"`/`:note`, `"discount"`, `"tax"` (strings or decimals).
  - `HeldCarts.list(user) :: [%{id: integer, note: String.t() | nil, inserted_at: NaiveDateTime.t(), units: integer, total: Decimal.t()}]`, newest first; `total` = Σ current price × qty (products not deleted) − discount + tax.
  - `HeldCarts.count(user) :: non_neg_integer`.

- [ ] **Step 1: Write the failing tests** in `test/zahlungs/held_carts_test.exs` (`use Zahlungs.DataCase, async: true`; fixtures `user_on_shift_fixture/0`, `user_fixture/0`, `product_fixture/1`, `store_fixture/0`, `stock_of/1`, `Shifts.expected_cash/1`):
  - `"hold/3 needs an open shift"` — `HeldCarts.hold(user_fixture(), [%{product_id: p.id, quantity: 1}], %{}) == {:error, :no_open_shift}`.
  - `"hold/3 refuses an empty cart"` — `{:error, :empty_cart}` for `[]`.
  - `"hold/3 keeps the items, the names and the shift's store"` — held cart `store_id == shift.store_id`, `user_id`, `shift_id`, items `[{p.id, 2, p.name}]`, `discount` = `Decimal.new("500")` from `"500"`, `tax` 0 from `""`.
  - `"a note is at most 60 characters"` — 61 chars → `{:error, %Ecto.Changeset{}}` with `errors_on(cs)[:note]`.
  - `"holding touches neither stock nor the drawer"` — `stock_of(p)` and `Shifts.expected_cash(shift)` unchanged after hold.
  - `"list/1 shows the store's held carts, newest first, priced now"` — two holds (first `note: "Bu Ani"`); then change the product price via `Catalog.update_product/3` to 2000; `[newest, older] = HeldCarts.list(user)`; `older.note == "Bu Ani"`, `older.units == 2`, `older.total == 2 × 2000 − discount + tax`.
  - `"list/1 and count/1 see only the shift's store"` — a cashier on shift in `store_fixture()` (another store) holds one; the first cashier's `count/1` doesn't count it and `list/1` doesn't contain it; `count(user_fixture()) == 0`.

- [ ] **Step 2: Run** `mix test test/zahlungs/held_carts_test.exs` — Expected: FAIL (module `Zahlungs.HeldCarts` undefined).

- [ ] **Step 3: Migration** `create_held_carts`: `held_carts` (`store_id` FK stores, not null; `user_id` FK users, not null; `shift_id` FK cashier_shifts, nilify on delete; `note` string 60; `discount`, `tax` decimal(12,2) not null default 0; timestamps), index `[:store_id, :inserted_at]`; `held_cart_items` (`held_cart_id` FK `on_delete: :delete_all`, not null; `product_id` FK products, not null; `quantity` integer not null; `name` string not null; timestamps), index `[:held_cart_id]`.

- [ ] **Step 4: Schemas.** `HeldCart` (`belongs_to :store, :user, :shift` (`Zahlungs.Shifts.Shift`), `has_many :items`, fields `note`, `discount`, `tax`; changeset casts `note discount tax`, `validate_length(:note, max: 60)`, `validate_number(:discount/:tax, greater_than_or_equal_to: 0)`, blank discount/tax → 0). `HeldCartItem` (`belongs_to :held_cart`, `:product`; `quantity`, `name`; `validate_number(:quantity, greater_than: 0)`).

- [ ] **Step 5: Implement `hold/3`, `list/1`, `count/1`** in `lib/zahlungs/held_carts.ex` per the Interfaces block; names come from `Catalog.get_product!(Scope.for_store(store), id)`; insert cart + items in one `Repo.transaction`.

- [ ] **Step 6: Run** the test file — Expected: all pass.

- [ ] **Step 7: Commit** (when asked): `feat(kasir-tunda): a cart can be held in the shift's store`.

### Task 2: `resume/2` and `delete/2`

**Files:**
- Modify: `lib/zahlungs/held_carts.ex`
- Test: `test/zahlungs/held_carts_test.exs`

**Interfaces:**
- Consumes: Task 1's `hold/3`.
- Produces:
  - `HeldCarts.resume(user, id) :: {:ok, %{items: [%{product: %Catalog.Product{}, quantity: pos_integer}], discount: Decimal.t(), tax: Decimal.t(), adjusted: non_neg_integer}} | {:error, :no_open_shift | :not_found}` — the product carries `stock` of the shift's store; `id` may be an integer or a string.
  - `HeldCarts.delete(user, id) :: :ok | {:error, :no_open_shift | :not_found}`.

- [ ] **Step 1: Write the failing tests:**
  - `"resume/2 gives the items back with today's prices and removes the cart"` — hold 2 × p (discount "500"); raise price; `{:ok, %{items: [%{product: prod, quantity: 2}], discount: d, adjusted: 0}}` with `prod.price` new price, `prod.stock == stock_of(p)`, `d == Decimal.new("500")`; `HeldCarts.count(user) == 0`.
  - `"a cart is resumed once"` — second `resume(user, id)` → `{:error, :not_found}`; also with `to_string(id)`.
  - `"products gone or short are adjusted"` — cart with a (qty 2), b (qty 5, stock 3), c (deleted via `Catalog.delete_product/1`), d (inactive via `Catalog.set_product_active(d, false)`), e (stock 0 — sold out after the hold): result items `[{a, 2}, {b, 3}]`, `adjusted == 4`.
  - `"a cart whose products are all gone resumes empty"` — only c deleted → `{:ok, %{items: [], adjusted: 1}}`.
  - `"another store's cart can be neither resumed nor deleted"` — held by a cashier of `store_fixture()`; first cashier's `resume`/`delete` → `{:error, :not_found}`; the owner still `count == 1`.
  - `"delete/2 removes the cart and its items"` — `:ok`, then `count == 0` and second delete `:not_found`.

- [ ] **Step 2: Run** the test file — Expected: the new tests FAIL (`resume/2` undefined).

- [ ] **Step 3: Implement.** `resume/2`: in `Repo.transaction`, `from(h in HeldCart, where: h.id == ^id and h.store_id == ^store_id, lock: "FOR UPDATE", preload: :items)`; nil → rollback `:not_found`; delete it; then load each product with `Catalog.list_products(scope, ...)` or `get_product!` (rescue none → dropped); drop deleted/inactive/stock 0, cap quantity at stock; `adjusted` counts dropped + capped items. Cast `id` with `Integer.parse` for strings (bad id → `:not_found`). `delete/2`: same lookup without returning items.

- [ ] **Step 4: Run** the test file — Expected: all pass.

- [ ] **Step 5: Commit** (when asked): `feat(kasir-tunda): a held cart is resumed once, fitted to today's stock`.

### Task 3: Cashier screen, close-shift warning, docs

**Files:**
- Modify: `lib/zahlungs_web/live/cashier_live.ex`
- Modify: `CLAUDE.md` (Architecture list: `held_carts.ex`; Database tables list), `docs/IA.md` (Kasir section)
- Test: `test/zahlungs_web/live/cashier_live_test.exs`

**Interfaces:**
- Consumes: `HeldCarts.hold/3`, `list/1`, `count/1`, `resume/2`, `delete/2`.
- Produces (events, all params strings or JSON numbers): `"hold"` `%{"note" => note}`; `"toggle_held"`; `"resume_held"` `%{"id" => id}`; `"delete_held"` `%{"id" => id}`. Assigns: `held_count`, `held_open`, `held` (the list). Public helper `CashierLive.held_age(inserted_at :: NaiveDateTime.t(), now :: NaiveDateTime.t()) :: String.t()` — "baru saja" (< 1 min), "N menit lalu", "N jam lalu", "N hari lalu".

- [ ] **Step 1: Write the failing tests** (new `describe "holding a cart"`; socket = `mount_live(CashierLive, user_on_shift_fixture())` with a product added via `event("add", %{"id" => p.id})`):
  - `"Tunda empties the cart and counts it"` — `event("hold", %{"note" => "Bu Ani"})` → `cart == []`, `flash(:info) == "Keranjang ditunda."`, `held_count == 1`, `html =~ "Ditunda (1)"`.
  - `"Tunda needs a cart"` — on an empty cart `"hold"` changes nothing (`held_count == 0`).
  - `"the list shows the note or the automatic label"` — hold with note "Bu Ani" and one without; `event("toggle_held")`; html has "Bu Ani" and `~r/1 item · Rp 1\.000/`.
  - `"Lanjutkan fills the cart at today's price"` — hold; raise price to 1500 via `Catalog.update_product/3`; `event("resume_held", %{"id" => id})` → cart `[%{product_id: p.id, quantity: 1, unit_price: 1500}]`, `held_count == 0`.
  - `"Lanjutkan with a full cart holds the screen's cart first"` — hold cart A (p); add q; resume A → cart has p only; `held_count == 1` and the held one has q.
  - `"Lanjutkan with an empty cart holds nothing"` — `held_count` goes 1 → 0.
  - `"a cart resumed twice says it is gone"` — resume with a stale id (deleted via `HeldCarts.delete/2`) → `flash(:error) == "Sudah dilanjutkan atau dihapus di kasir lain."`.
  - `"adjusted items are told"` — hold 5 × p with stock 10, set stock to 3 (`Catalog.update_product/3` with `stock: 3` in the store scope), resume → `flash(:info) =~ "1 barang disesuaikan dengan stok."`, quantity 3.
  - `"a discount that no longer fits keeps Complete Sale disabled"` — hold 2 × p with discount "1500", delete nothing but set stock 1 → resume → `can_checkout == false` and `amount_error` set; no crash.
  - `"Hapus removes a held cart"` — `"delete_held"` → `held_count == 0`.
  - `"the close-shift dialog warns about held carts"` — hold; `event("toggle_close")`; html =~ "Ada 1 keranjang tertunda di toko ini. Keranjang tetap tersimpan."
  - `"held_age/2 says how long ago"` — 30 s → "baru saja", 5 min → "5 menit lalu", 3 h → "3 jam lalu", 2 days → "2 hari lalu".

- [ ] **Step 2: Run** `mix test test/zahlungs_web/live/cashier_live_test.exs` — Expected: the new tests FAIL.

- [ ] **Step 3: Implement in `CashierLive`.**
  - mount / after each change: `held_count: HeldCarts.count(user)`, `held_open: false`, `held: []`.
  - `"hold"`: cart empty → no-op; else `HeldCarts.hold(user, cart items, %{note, discount, tax})` → `reset_cart/1`, `push_event("reset_amount_paid", %{})`, flash "Keranjang ditunda.", refresh count; errors via existing `error_message/1` (add `:empty_cart` if missing).
  - `"toggle_held"`: flip `held_open`, load `held: HeldCarts.list(user)` when opening.
  - `"resume_held"`: if cart not empty, hold it first (no note); then `resume/2` → build cart items with the same map `add_to_cart/2` builds (extract `cart_item(product, quantity)`), set `discount`/`tax` (`""` when zero, else `Decimal.to_string/1`), `assign_totals/1`, close the list, flash "N barang disesuaikan dengan stok." when `adjusted > 0`; `:not_found` → flash error "Sudah dilanjutkan atau dihapus di kasir lain." and reload the list.
  - `"delete_held"`: `delete/2`, reload list and count.
  - Markup: in the cart panel under the totals, a small form `phx-submit="hold"` with `note` input (`maxlength="60"`, placeholder "Catatan (opsional)") and a "Tunda" button, shown when `@cart != []`. Above the product search, a `chip` button "Ditunda ({@held_count})" when `@held_count > 0`, toggling a list: label (`note` or "#{units} item · #{format_money(total)} · #{HH:MM local}" via `LocalTime.to_local(inserted_at, store)`), `held_age/2`, "Lanjutkan" and "Hapus" (`data-confirm="Hapus keranjang tertunda ini?"`). In `close-shift-modal`, an amber notice when `@held_count > 0`.
  - Phone: both live inside the existing panel/tile column, so the cashier bar pattern needs no change.

- [ ] **Step 4: Docs.** `CLAUDE.md`: add `held_carts.ex` to the context list ("held carts: hold/list/resume/delete in the open shift's store; resume locks and deletes, prices and stock are read again") and `held_carts`, `held_cart_items` to the tables list. `docs/IA.md`: under Kasir, one bullet describing Tunda / Ditunda / Lanjutkan / Hapus and the close-shift warning.

- [ ] **Step 5: Run** the cashier test file, then the gates: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, `mix test` — Expected: all green.

- [ ] **Step 6: Commit** (when asked): `feat(kasir-tunda): the cashier holds and resumes carts`.
