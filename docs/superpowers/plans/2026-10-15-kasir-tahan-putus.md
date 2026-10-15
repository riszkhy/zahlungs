# Kasir Tahan Putus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dropped connection, a reload or a restarted tablet no longer loses the cashier's cart, the cashier can see they are offline, and one cart can never become two sales.

**Architecture:** The server stays the source of truth. After every cart change `CashierLive` pushes a small copy (`cart_saved`) that a new JS hook keeps in `localStorage`; when the screen mounts or reconnects the hook sends it back (`restore_cart`) and the server rebuilds the cart from the database. Each cart carries a UUID that `Sales.create_sale/3` stores in the new `sales.client_ref` column and checks under the shift lock, so a resubmitted cart returns the sale already recorded instead of a second one. The offline banner is plain CSS on LiveView's `phx-client-error` / `phx-server-error` classes.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MyXQL, ExUnit, vanilla JS in `assets/js/app.js`.

**Spec:** `docs/superpowers/specs/2026-10-15-kasir-tahan-putus-design.md`

## Global Constraints

- Branch `feat/kasir-tahan-putus` (already created from `feat/saas-multi-owner`; the dev DB is multi-tenant).
- No new dependencies. LiveView behaviour is tested through `ZahlungsWeb.LiveDriver` (`mount_live/3`, `event/3`, `html/1`, `flash/2`, `pushed_events/1`); `Phoenix.LiveViewTest.live/2` is not available. There is no JS test tooling: hooks are checked in the browser.
- Tests share a database with real rows: never assert a table is empty; find rows by id, unique SKU or `client_ref`.
- The copy from the tablet is untrusted: only ids, quantities and the amount strings are read; prices charged always come from the database; every amount goes through `assign_totals/1` and `Sales.create_sale/3` as today.
- `create_sale/3` without `:client_ref` behaves exactly as today (all existing tests stay green unchanged, except where a task says otherwise).
- UI copy (exact):
  - restore ok: `Keranjang dipulihkan.` followed by the change notes, space-separated
  - restore with nothing left: `Keranjang tidak bisa dipulihkan.` (flash `:error`) followed by the change notes
  - change notes: `Harga <name> berubah.` · `<name> dihapus: stok habis.` · `<name> dihapus: tidak dijual lagi.` · `Barang yang sudah dihapus dari katalog dikeluarkan.` (once) · `Jumlah <name> dikurangi ke <n> (sisa stok).`
  - key already recorded, on restore: `Penjualan <code> sudah tercatat. Jangan terima pembayaran lagi.`
  - key already recorded, on checkout: `Penjualan <code> sudah tercatat sebelumnya. Jangan terima pembayaran lagi.`
  - global banner: `Koneksi terputus — menyambung ulang…`
  - cashier offline note: `Keranjang aman di tablet ini. Tunggu tersambung sebelum menerima pembayaran.`
- Every task ends green on `mix test`, `mix format --check-formatted`, `mix compile --warnings-as-errors` and `mix credo`. Line endings LF.

## Review Focus

1. **`CurrencyInput` pushing `set_amount_paid ""` on mount after a restore** — the restored "uang diterima" must survive a page reload. → Task 4 changes the hook; Task 4's browser check reloads with an amount entered.
2. **A copy that arrives before the handshake, or a second `restore_cart` (mounted + reconnected)** — the empty cart of a fresh process must not erase the stored copy, and a second restore must not overwrite a cart already rebuilt. → Task 2 test "nothing is pushed before restore_cart"; Task 3 test "ignored when the server cart is not empty".
3. **Malformed or crafted copies** (`items` not a list, negative or string quantities, a non-UUID key, an unknown `v`) — ignored, no crash, no sale. → Task 3 tests on `CartBackup.parse/1`.
4. **An admin whose navbar store differs from the open shift's store** — restore must price, stock-check and look up the key in the shift's store (`@sale_scope`). → Task 3 test "uses the shift's store".
5. **A key that belongs to a sale in another store** — not "already recorded" here; a new sale is created. → Task 1 test "keys are per store".

---

### Task 1: One cart, at most one sale (`sales.client_ref`)

**Files:**
- Create: `priv/repo/migrations/20261015090000_add_client_ref_to_sales.exs`
- Modify: `lib/zahlungs/sales/sale.ex` (field, cast, unique constraint)
- Modify: `lib/zahlungs/sales.ex` (`create_sale/3`, new `get_sale_by_client_ref/2`, docs)
- Modify: `CLAUDE.md` (Invariants section)
- Test: `test/zahlungs/sales_test.exs` (new `describe "client_ref"`)

**Interfaces:**
- Produces:
  - `Sales.create_sale(user, cart, payment)` — `payment` accepts `:client_ref` (UUID string or nil). New result `{:error, {:already_recorded, %Sale{}}}`; the sale is preloaded like a successful one (`[:user, :store, items: :product]`).
  - `Sales.get_sale_by_client_ref(scope :: %Scope{}, key :: String.t() | nil) :: %Sale{} | nil` — same preloads; `nil` when the scope has no store, the key is nil, or no sale in that store has it.

- [ ] **Step 1: Write the failing tests** — append to `test/zahlungs/sales_test.exs`:

```elixir
  describe "client_ref" do
    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)
      %{user: user, cart: [%{product_id: product.id, quantity: 2}], product: product}
    end

    test "the same key twice records one sale and takes the stock once", ctx do
      key = Ecto.UUID.generate()
      payment = %{amount_paid: "2000", client_ref: key}

      assert {:ok, sale} = Sales.create_sale(ctx.user, ctx.cart, payment)
      assert sale.client_ref == key

      assert {:error, {:already_recorded, again}} = Sales.create_sale(ctx.user, ctx.cart, payment)
      assert again.id == sale.id
      assert [%{quantity: 2}] = again.items
      assert stock_of(ctx.product) == 8
    end

    test "different keys, or no key, record separate sales", ctx do
      {:ok, a} = Sales.create_sale(ctx.user, ctx.cart, %{amount_paid: "2000", client_ref: Ecto.UUID.generate()})
      {:ok, b} = Sales.create_sale(ctx.user, ctx.cart, %{amount_paid: "2000", client_ref: Ecto.UUID.generate()})
      {:ok, c} = Sales.create_sale(ctx.user, ctx.cart, %{amount_paid: "2000"})

      assert length(Enum.uniq([a.id, b.id, c.id])) == 3
      assert is_nil(c.client_ref)
      assert stock_of(ctx.product) == 4
    end

    test "keys are per store", ctx do
      key = Ecto.UUID.generate()
      {:ok, here} = Sales.create_sale(ctx.user, ctx.cart, %{amount_paid: "2000", client_ref: key})

      # Products are shared; stock is per store.
      other = store_fixture()
      cashier = user_on_shift_fixture(store_id: other.id)
      {:ok, _} = Catalog.update_product(store_scope(other), ctx.product, %{stock: 5})

      assert {:ok, there} =
               Sales.create_sale(cashier, [%{product_id: ctx.product.id, quantity: 1}], %{
                 amount_paid: "1000",
                 client_ref: key
               })

      assert there.id != here.id
      assert Sales.get_sale_by_client_ref(store_scope(), key).id == here.id
      assert Sales.get_sale_by_client_ref(store_scope(other), key).id == there.id
    end

    test "get_sale_by_client_ref/2 finds nothing for an unknown or missing key" do
      assert Sales.get_sale_by_client_ref(store_scope(), Ecto.UUID.generate()) == nil
      assert Sales.get_sale_by_client_ref(store_scope(), nil) == nil
    end
  end
```

(Alias `Zahlungs.Catalog` in the test module if it isn't already.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/zahlungs/sales_test.exs`
Expected: the four new tests fail (`client_ref` unknown key / `get_sale_by_client_ref/2` undefined); the rest pass.

- [ ] **Step 3: Migration** — `alter table(:sales)`: `add :client_ref, :string, size: 36`; `create unique_index(:sales, [:store_id, :client_ref])` (default name `sales_store_id_client_ref_index`).

- [ ] **Step 4: Schema** — `Sale`: `field :client_ref, :string`; cast it in `changeset/2`; `unique_constraint(:client_ref, name: :sales_store_id_client_ref_index)`.

- [ ] **Step 5: `create_sale/3`** — read `payment[:client_ref] || payment["client_ref"]` and pass it into `do_create_sale`. In the `Multi`, add a step `:already_recorded` right after `:shift` (so it runs under the shift's row lock): when the key is non-nil and a sale with `(shift.store_id, key)` exists, return `{:error, {:already_recorded, preloaded_sale}}`; otherwise `{:ok, nil}`. Put `client_ref` into the inserted sale's attrs. If the insert still fails on the unique constraint (`client_ref` error in the changeset), look the sale up and return `{:error, {:already_recorded, sale}}` instead of the changeset. Add the new result to the `@doc`.

- [ ] **Step 6: `get_sale_by_client_ref/2`** — `nil` for a nil key or `Scope.store_id(scope) == nil`; otherwise `Repo.get_by(Sale, store_id: ..., client_ref: key)` preloaded like `create_sale/3`'s result.

- [ ] **Step 7: CLAUDE.md** — add to "Invariants worth knowing before changing sales or shifts":
  `- **One cart, at most one sale.** The cashier sends each cart's UUID as `client_ref`; `create_sale/3` checks it under the shift lock (unique per store) and returns `{:error, {:already_recorded, sale}}` for a cart already recorded.`
  Also add `sales.client_ref` nowhere else (the table list is unchanged).

- [ ] **Step 8: Run to verify they pass**

Run: `mix test test/zahlungs/sales_test.exs` → all pass. Then `mix test` → 0 failures.

- [ ] **Step 9: Commit**

```bash
git add priv/repo/migrations/20261015090000_add_client_ref_to_sales.exs lib/zahlungs/sales.ex lib/zahlungs/sales/sale.ex test/zahlungs/sales_test.exs CLAUDE.md
git commit -m "feat(kasir-tahan-putus): record a cart at most once"
```

---

### Task 2: Cart key and the cart copy (`cart_saved`)

**Files:**
- Create: `lib/zahlungs_web/live/cashier_live/cart_backup.ex` (`ZahlungsWeb.CashierLive.CartBackup`)
- Modify: `lib/zahlungs_web/live/cashier_live.ex`
- Test: `test/zahlungs_web/live/cashier_live_test.exs` (new `describe "cart copy"` and `describe "checkout of a cart already recorded"`)

**Interfaces:**
- Consumes: Task 1's `create_sale/3` `:client_ref` and `{:error, {:already_recorded, sale}}`.
- Produces:
  - `CartBackup.snapshot(assigns :: map) :: map` →
    `%{v: 1, user_id: integer, shift_id: integer | nil, key: String.t(), items: [[product_id, quantity, unit_price_string]], discount: String.t(), tax: String.t(), amount_paid: String.t(), payment_method: String.t()}` (reads `current_user`, `shift`, `cart_key`, `cart`, `discount`, `tax`, `amount_paid`, `payment_method`).
  - `CashierLive` assigns `cart_key` (UUID string, new on every `reset_cart/1`) and `cart_synced` (boolean, `false` at mount).
  - Push event `"cart_saved"` with `CartBackup.snapshot/1` — sent only while `cart_synced` is true, at the end of: successful `scan`, `add`, `inc`, `dec`, `remove`, `payment`, `set_amount_paid`, `set_payment_method`, `quick_cash`, `checkout` (success and already-recorded) and `new_sale`.
  - Event `"restore_cart"` with `%{"cart" => nil}` sets `cart_synced: true` and changes nothing else (the copy case is Task 3).

- [ ] **Step 1: Write the failing tests** — append to `cashier_live_test.exs`:

```elixir
  describe "cart copy" do
    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)
      %{user: user, product: product, socket: mount_live(CashierLive, user)}
    end

    defp saved(socket), do: for({"cart_saved", copy} <- pushed_events(socket), do: copy)

    test "nothing is pushed before the hook said hello", %{socket: socket, product: product} do
      assert saved(event(socket, "scan", %{"q" => product.sku})) == []
    end

    test "every change pushes ids, quantities and the prices seen", ctx do
      socket = event(ctx.socket, "restore_cart", %{"cart" => nil})
      assert socket.assigns.cart == []

      socket = event(socket, "scan", %{"q" => ctx.product.sku})

      assert [copy] = saved(socket)
      assert copy.v == 1
      assert copy.user_id == ctx.user.id
      assert copy.shift_id == socket.assigns.shift.id
      assert copy.key == socket.assigns.cart_key
      assert copy.items == [[ctx.product.id, 1, "1000"]]

      socket = event(socket, "set_amount_paid", %{"value" => "5000"})
      assert [%{amount_paid: "5000", items: [[_, 1, _]]}] = saved(socket)

      assert [%{items: []}] = saved(event(socket, "remove", %{"id" => ctx.product.id}))
    end

    test "a completed sale or a new sale empties the copy and changes the key", ctx do
      socket =
        ctx.socket
        |> event("restore_cart", %{"cart" => nil})
        |> event("scan", %{"q" => ctx.product.sku})
        |> event("set_amount_paid", %{"value" => "1000"})

      key = socket.assigns.cart_key
      socket = event(socket, "checkout")

      assert socket.assigns.last_sale.client_ref == key
      assert [%{items: [], key: new_key}] = saved(socket)
      assert new_key == socket.assigns.cart_key and new_key != key

      assert [%{items: []}] = saved(event(socket, "new_sale"))
    end
  end

  describe "checkout of a cart already recorded" do
    test "shows the recorded sale instead of making a second one" do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      socket =
        CashierLive
        |> mount_live(user)
        |> event("scan", %{"q" => product.sku})
        |> event("set_amount_paid", %{"value" => "1000"})

      # The first click reached the server, its reply never reached the tablet.
      {:ok, first} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{
          amount_paid: "1000",
          client_ref: socket.assigns.cart_key
        })

      socket = event(socket, "checkout")

      assert flash(socket, :info) ==
               "Penjualan #{first.code} sudah tercatat sebelumnya. Jangan terima pembayaran lagi."

      assert socket.assigns.last_sale.id == first.id
      assert socket.assigns.cart == []
      assert stock_of(product) == 9
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/zahlungs_web/live/cashier_live_test.exs`
Expected: the new tests fail (`restore_cart` has no clause / `cart_key` missing); existing ones pass.

- [ ] **Step 3: `CartBackup.snapshot/1`** in the new module (moduledoc: what the copy is for, that prices in it are never charged). `unit_price` is sent with `Decimal.to_string/1`.

- [ ] **Step 4: `CashierLive`** — `mount/3` assigns `cart_synced: false`; `reset_cart/1` assigns `cart_key: Ecto.UUID.generate()`; add `defp save_cart(socket)` (push `cart_saved` with the snapshot only when `cart_synced`) and call it at the end of the events listed under Interfaces; add `handle_event("restore_cart", %{"cart" => nil}, socket)`; `checkout` passes `client_ref: socket.assigns.cart_key` and handles `{:error, {:already_recorded, sale}}` like success (assign `last_sale`, `reset_cart`, push `reset_amount_paid`, `save_cart`) with the exact flash from Global Constraints.

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/zahlungs_web/live/cashier_live_test.exs` → all pass (the existing checkout test still sees only `reset_amount_paid`, since it never sends `restore_cart`). Then `mix test` → 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/zahlungs_web/live/cashier_live.ex lib/zahlungs_web/live/cashier_live/cart_backup.ex test/zahlungs_web/live/cashier_live_test.exs
git commit -m "feat(kasir-tahan-putus): keep a copy of the cart and send each cart once"
```

---

### Task 3: Restoring the cart (`restore_cart`)

**Files:**
- Modify: `lib/zahlungs/catalog.ex` (`list_products/2` option `:ids`)
- Modify: `lib/zahlungs_web/live/cashier_live/cart_backup.ex` (`parse/1`, `rebuild/2`)
- Modify: `lib/zahlungs_web/live/cashier_live.ex` (`restore_cart` with a copy)
- Test: `test/zahlungs/catalog_test.exs`, `test/zahlungs_web/live/cashier_live_test.exs` (new `describe "restoring the cart"`), new `test/zahlungs_web/live/cart_backup_test.exs`

**Interfaces:**
- Consumes: Task 1's `Sales.get_sale_by_client_ref/2`; Task 2's snapshot format, `cart_key`, `cart_synced`, `save_cart/1`.
- Produces:
  - `Catalog.list_products(scope, ids: [integer])` — only those ids (still excluding soft-deleted, still filling `stock`); combinable with the other options.
  - `CartBackup.parse(term) :: {:ok, %{user_id: integer, shift_id: integer, key: String.t(), items: [{integer, pos_integer, Decimal.t()}], discount: String.t(), tax: String.t(), amount_paid: String.t(), payment_method: String.t()}} | :error` — `:error` for anything that is not a map with `"v" => 1`, integer `user_id`/`shift_id`, a string `key`, and `items` a list of `[id, qty, price]` with positive integer id and qty and a price string `Decimal.parse/1` accepts fully. Amount fields that aren't strings become `""`; a `payment_method` outside `cash qris card transfer` becomes `"cash"`. The key is not validated here.
  - `CartBackup.rebuild(items, products_by_id :: %{integer => %Product{}}) :: {cart :: [cart_item], notes :: [String.t()]}` — pure. `cart_item` is the shape `add_to_cart/2` builds (`product_id, name, sku, unit_price, quantity, stock`), priced from the product. Notes in item order, exact copy from Global Constraints; the "dihapus dari katalog" note at most once, last.

- [ ] **Step 1: Write the failing tests**

`test/zahlungs_web/live/cart_backup_test.exs` (`use ExUnit.Case, async: true`):

```elixir
  @copy %{"v" => 1, "user_id" => 1, "shift_id" => 2, "key" => "k",
          "items" => [[10, 2, "1000"]], "discount" => "", "tax" => "",
          "amount_paid" => "5000", "payment_method" => "cash"}

  test "parse/1 reads a copy" do
    assert {:ok, %{items: [{10, 2, price}], amount_paid: "5000"}} = CartBackup.parse(@copy)
    assert Decimal.equal?(price, Decimal.new("1000"))
  end

  test "parse/1 rejects malformed copies" do
    for bad <- [nil, "x", %{}, %{@copy | "v" => 2}, %{@copy | "items" => "x"},
                %{@copy | "items" => [[10, -1, "1000"]]}, %{@copy | "items" => [["10", 1, "1000"]]},
                %{@copy | "items" => [[10, 1, "abc"]]}, %{@copy | "user_id" => "1"}] do
      assert CartBackup.parse(bad) == :error, inspect(bad)
    end
  end

  test "parse/1 falls back to cash and blank amounts" do
    assert {:ok, %{payment_method: "cash", tax: ""}} =
             CartBackup.parse(%{@copy | "payment_method" => "bitcoin", "tax" => 5})
  end
```

`test/zahlungs/catalog_test.exs`: `list_products(store_scope(), ids: [a.id])` returns only `a` with its `stock`; a soft-deleted id in `ids` is not returned.

`cashier_live_test.exs`:

```elixir
  describe "restoring the cart" do
    setup do
      user = user_on_shift_fixture()
      a = product_fixture(name: "Molto #{System.unique_integer([:positive])}", price: Decimal.new("1000"), stock: 10)
      b = product_fixture(name: "Rinso #{System.unique_integer([:positive])}", price: Decimal.new("2000"), stock: 10)
      socket = mount_live(CashierLive, user)
      copy = fn items, extra ->
        Map.merge(%{"v" => 1, "user_id" => user.id, "shift_id" => socket.assigns.shift.id,
          "key" => Ecto.UUID.generate(), "items" => items, "discount" => "", "tax" => "",
          "amount_paid" => "10000", "payment_method" => "cash"}, extra)
      end
      %{user: user, a: a, b: b, socket: socket, copy: copy}
    end

    defp restore(socket, copy), do: event(socket, "restore_cart", %{"cart" => copy})
```

Tests (names and assertions):
  - **"brings back items, amounts and the key"** — `restore(socket, copy.([[a.id, 2, "1000"]], %{}))` → `cart` has `a` × 2 at `1000`, `amount_paid == "10000"`, `cart_key == copy["key"]`, `flash(:info) == "Keranjang dipulihkan."`, `pushed_events` contains `{"set_amount_paid_input", %{value: "10000"}}` and a `cart_saved` whose `items == [[a.id, 2, "1000"]]`.
  - **"uses today's price, drops what can't be sold and caps quantities"** — before restoring: `a`'s price → `1500`; `b`'s stock → `1`; a third product `c` set inactive; a fourth `d` deleted. Copy `[[a,1,"1000"],[b,3,"2000"],[c,1,…],[d,1,…]]` → cart is `a` × 1 at `1500` and `b` × 1; flash is exactly `"Keranjang dipulihkan. Harga #{a.name} berubah. Jumlah #{b.name} dikurangi ke 1 (sisa stok). #{c.name} dihapus: tidak dijual lagi. Barang yang sudah dihapus dari katalog dikeluarkan."` (Add a product with stock 0 to a second copy and assert `"#{name} dihapus: stok habis."`.)
  - **"nothing left to restore"** — copy with only an inactive product → `cart == []`, `flash(:error)` starts with `"Keranjang tidak bisa dipulihkan."`.
  - **"a key already recorded shows that sale"** — record a sale with `client_ref: key` via `Sales.create_sale/3`, restore a copy with that key → `last_sale.id` is that sale, `cart == []`, flash `"Penjualan #{code} sudah tercatat. Jangan terima pembayaran lagi."`, a `cart_saved` with `items: []`, and the sales count for the user unchanged.
  - **"a copy from another shift is dropped"** — `shift_id` of a closed earlier shift → `cart == []`, a `cart_saved` with `items: []`, no flash.
  - **"ignored for another cashier, a malformed copy, or a cart already rebuilt"** — `user_id` of someone else → cart unchanged; `%{"v" => 9}` → cart unchanged; restore once, then restore a different copy → the first cart stays. None of these raise.
  - **"a key that isn't a UUID is replaced"** — `"key" => "not-a-uuid"` → items restored, `cart_key != "not-a-uuid"` and is a valid UUID (`Ecto.UUID.cast/1`).
  - **"uses the shift's store"** — `user_on_shift_fixture()` (shift in the default store), then `Accounts.set_user_role(user, "admin")` and `mount_live(CashierLive, admin, store: "all")`. Set `a`'s stock to 2 in the default store (`Catalog.update_product(store_scope(), a, %{stock: 2})`) and to 50 in a second store (`store_scope(store_fixture())`). Restoring `a` × 5 gives quantity 2 (the shift store's stock, not the sum over stores).

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/zahlungs_web/live/cart_backup_test.exs test/zahlungs/catalog_test.exs test/zahlungs_web/live/cashier_live_test.exs`
Expected: the new tests fail; existing ones pass.

- [ ] **Step 3: `Catalog.list_products/2` `:ids`** — one more filter in `base_query/2` (`where p.id in ^ids`, skipped for nil); document the option.

- [ ] **Step 4: `CartBackup.parse/1` and `rebuild/2`** — as specified under Interfaces. In `rebuild/2`: product missing → catalogue note; `active == false` → "tidak dijual lagi"; `stock <= 0` → "stok habis"; price differs from the copy's (`Decimal.equal?/2`) → "Harga … berubah."; `qty > stock` → cap and "Jumlah … dikurangi ke …".

- [ ] **Step 5: `handle_event("restore_cart", %{"cart" => copy}, socket)`** — always set `cart_synced: true`. Then, in order: ignore (no change, no push) when there is no shift, the server cart is not empty, `parse/1` is `:error`, or the copy's `user_id` isn't the current user; if `Sales.get_sale_by_client_ref(sale_scope, key)` finds a sale → recorded case; if `shift_id` isn't the open shift's → `reset_cart` + `save_cart`; otherwise load `Catalog.list_products(sale_scope, ids: ids)`, `rebuild/2`, assign the cart and amounts, keep the key if `Ecto.UUID.cast/1` accepts it (else a new one), `assign_totals`, push `set_amount_paid_input` when `amount_paid != ""`, `save_cart`, flash per Global Constraints.

- [ ] **Step 6: Run to verify they pass** — same command as Step 2, then `mix test` → 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/zahlungs/catalog.ex lib/zahlungs_web/live/cashier_live.ex lib/zahlungs_web/live/cashier_live/cart_backup.ex test/zahlungs/catalog_test.exs test/zahlungs_web/live/cart_backup_test.exs test/zahlungs_web/live/cashier_live_test.exs
git commit -m "feat(kasir-tahan-putus): restore the cart after a reconnect or reload"
```

---

### Task 4: The tablet side — `CartKeeper`, offline banner, docs

**Files:**
- Modify: `assets/js/app.js` (new `Hooks.CartKeeper`; `Hooks.CurrencyInput.mounted`)
- Modify: `assets/css/app.css` (`.offline-banner`, `.offline-only`, `.offline-lock`)
- Modify: `lib/zahlungs_web/components/layouts/app.html.heex` (banner)
- Modify: `lib/zahlungs_web/live/cashier_live.ex` (hook element, offline note, lock classes)
- Modify: `docs/DEPLOYMENT.md` (new `## 9. Koneksi internet di toko`)
- Test: `test/zahlungs_web/live/cashier_live_test.exs`

**Interfaces:**
- Consumes: Task 2/3 events `cart_saved` (payload = snapshot) and `restore_cart` (`%{cart: copy | null}`).
- Produces: `Hooks.CartKeeper` on `<div id="cart-keeper" phx-hook="CartKeeper" data-user-id={@current_user.id} class="hidden">`, storage slot `zahlungs:cart:<user_id>`.

- [ ] **Step 1: Write the failing test** — in `cashier_live_test.exs`:

```elixir
  describe "offline" do
    test "the cashier screen carries the cart keeper, the offline note and the locks" do
      user = user_on_shift_fixture()
      html = CashierLive |> mount_live(user) |> html()

      assert html =~ ~s(id="cart-keeper")
      assert html =~ ~s(phx-hook="CartKeeper")
      assert html =~ ~s(data-user-id="#{user.id}")
      assert html =~ "Keranjang aman di tablet ini. Tunggu tersambung sebelum menerima pembayaran."
      assert html =~ ~r/<button[^>]*offline-lock[^>]*>\s*Complete Sale/
    end
  end
```

And in a controller-rendered check (`get(conn, "/cashier")` for a logged-in cashier): the response contains `Koneksi terputus — menyambung ulang…`.

- [ ] **Step 2: Run to verify it fails** — `mix test test/zahlungs_web/live/cashier_live_test.exs` → the new tests fail.

- [ ] **Step 3: Markup** — app layout: `<div class="offline-banner" role="status">Koneksi terputus — menyambung ulang…</div>` at the top of `<main>`. Cashier: the `cart-keeper` element next to `cashier-beeper`; the offline note (`offline-only`, amber) above the cart; `offline-lock` on the Complete Sale button, the quick-cash group, the product tile grid and the cart's quantity/remove buttons.

- [ ] **Step 4: CSS** — `.offline-banner` and `.offline-only` hidden by default and shown under `.phx-client-error` / `.phx-server-error`; `.offline-lock` under those classes gets `pointer-events: none; opacity: .4`. (LiveView puts the classes on the `[data-phx-main]` element, which contains the app layout.)

- [ ] **Step 5: JS** — `Hooks.CartKeeper`: slot from `this.el.dataset.userId`; `mounted()` and `reconnected()` read the slot (`JSON.parse`, any failure → `null`) and `this.pushEvent("restore_cart", {cart})`; `handleEvent("cart_saved", copy => …)` stores `JSON.stringify(copy)`, or removes the slot when `copy.items.length === 0`. Every `localStorage` access in `try/catch`. `Hooks.CurrencyInput.mounted()`: format the field without `pushEvent` (keep pushing on `input`).

- [ ] **Step 6: DEPLOYMENT.md** — section 9: why a backup connection (4G modem or phone hotspot as WiFi fallback) is the cheapest protection; what the app does on its own when the connection drops (cart kept on the tablet, payment locked until reconnected, no double sale); that selling while offline is not supported yet.

- [ ] **Step 7: Run checks** — `mix test` (0 failures), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo`.

- [ ] **Step 8: Browser verification** (dev server, as a cashier on an open shift; reset any viewport emulation afterwards):
  1. Scan two products, type an amount paid. In the console: `liveSocket.disconnect()` → the banner and the cashier note show, Complete Sale / tiles / quick cash are dimmed and don't react. `liveSocket.connect()` → the cart, the amounts and the amount-paid field are back; flash `Keranjang dipulihkan.`
  2. With a cart and an amount paid, reload the page → same result (Review Focus 1).
  3. With a cart, disconnect; in another tab as admin change one product's price; reconnect → new price and `Harga … berubah.`
  4. `liveSocket.enableLatencySim(3000)`, click Complete Sale, then `liveSocket.disconnect()` before the receipt shows; `disableLatencySim()`, `connect()` → `… sudah tercatat. Jangan terima pembayaran lagi.` and `/sales` shows one sale for that cart.
  5. Complete a sale normally, reload → the cart stays empty (the slot was cleared).

- [ ] **Step 9: Commit**

```bash
git add assets/js/app.js assets/css/app.css lib/zahlungs_web/components/layouts/app.html.heex lib/zahlungs_web/live/cashier_live.ex test/zahlungs_web/live/cashier_live_test.exs docs/DEPLOYMENT.md docs/superpowers/specs/2026-10-15-kasir-tahan-putus-design.md docs/superpowers/plans/2026-10-15-kasir-tahan-putus.md
git commit -m "feat(kasir-tahan-putus): keep the cart on the tablet and show when offline"
```
