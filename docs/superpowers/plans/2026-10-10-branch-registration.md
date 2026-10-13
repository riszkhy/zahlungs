# Registrasi Toko Cabang Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An admin registers a new branch in one two-step wizard (store data, then an optional first cashier) that saves both or neither.

**Architecture:** A new context function `Stores.register_branch/2` does the atomic save (`Ecto.Multi`: store, then optional cashier via `Accounts.create_user/1`). A new LiveView `StoreLive.Register` holds the two steps and their forms in its own assigns (no live component, so `ZahlungsWeb.LiveDriver` can drive it). The store form fields move into one function component shared with the existing edit modal. The old "Toko baru" modal path is removed.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView 1.2, Ecto + MyXQL, ExUnit.

**Spec:** `docs/superpowers/specs/2026-10-10-branch-registration-design.md`

## Global Constraints

- Work on branch `feat/daftar-cabang`, cut from `master`.
- No new dependencies. LiveView behaviour is tested through `ZahlungsWeb.LiveDriver` (`mount_live/3`, `event/3`, `html/1`, `flash/2`, `live_redirect/1`), access control through `get/2`; `Phoenix.LiveViewTest.live/2` is not available.
- Tests share a database with real rows: store codes must be unique and match `^[A-Z0-9]{2,8}$`. Generate them with `"W" <> Integer.to_string(System.unique_integer([:positive]), 36)`; never assert a table is empty.
- The cashier's `role` is always `"cashier"` and its `store_id` always the new store's; neither is ever read from form params.
- Nothing is written to the database before the final `save` / `skip`.
- UI copy (exact): page title `Daftar Cabang`; headings `Langkah 1 dari 2 — Data toko` and `Langkah 2 dari 2 — Kasir pertama (opsional)`; buttons `Lanjut`, `Kembali`, `Lewati`, `Daftarkan cabang`; navbar link `Daftar Cabang`; success flash `Cabang <name> terdaftar. Stoknya masih 0 — pilih cabang ini di menu atas, lalu isi stok lewat Products.`
- After success: `push_navigate` to `/admin/stores`. The admin's active store is not changed.
- Every task ends green on the whole suite (`mix test`), `mix format --check-formatted` and `mix compile --warnings-as-errors`. Line endings are LF.

## Review Focus

1. `save` or `skip` arriving while the wizard is still on step 1 (double submit, crafted event) — must not create a store from unvalidated or empty data. → Task 2.
2. "Daftarkan cabang" with the cashier fields left blank — must be an error on step 2, not a silent skip; the store must not be saved. → Tasks 1 and 2.
3. A store code that differs only by case or surrounding spaces from an existing one (`" tu "` vs `TU`) — must be rejected on step 1. → Task 1.
4. Editing an existing store without changing its code — the new uniqueness check must not reject the store's own code. → Task 1.
5. A latitude without a longitude on step 1 — must stay on step 1 with the field error, like the edit form. → Task 2.

---

### Task 1: Atomic branch registration in the Stores context

**Files:**
- Modify: `lib/zahlungs/stores/store.ex` (changeset)
- Modify: `lib/zahlungs/stores.ex` (new function)
- Test: `test/zahlungs/stores_test.exs` (new `describe` blocks)

**Interfaces:**
- Consumes: `Zahlungs.Accounts.create_user(attrs)` → `{:ok, %User{}} | {:error, %Ecto.Changeset{}}` (requires `store_id` for role `"cashier"`, sets `confirmed_at`).
- Produces:
  `Zahlungs.Stores.register_branch(store_attrs :: map, cashier_attrs :: map | nil \\ nil) :: {:ok, %{store: %Store{}, cashier: %User{} | nil}} | {:error, :store, %Ecto.Changeset{}} | {:error, :cashier, %Ecto.Changeset{}}`
  and a `Store.changeset/2` that reports a taken code as an error on `:code` without touching the database constraint.

- [ ] **Step 1: Write the failing tests** — append to `test/zahlungs/stores_test.exs`:

```elixir
  defp code, do: "W" <> Integer.to_string(System.unique_integer([:positive]), 36)

  describe "store code uniqueness" do
    test "a taken code is an error on the changeset, ignoring case and spaces" do
      existing = store_fixture()
      attrs = %{name: "Dup", code: " " <> String.downcase(existing.code) <> " "}

      changeset = Stores.change_store(%Zahlungs.Stores.Store{}, attrs)

      refute changeset.valid?
      assert %{code: ["has already been taken"]} = errors_on(changeset)
    end

    test "a store keeps its own code when edited" do
      store = store_fixture()

      assert Stores.change_store(store, %{name: "Renamed", code: store.code}).valid?
    end
  end

  describe "register_branch/2" do
    test "registers a store without a cashier" do
      code = code()

      assert {:ok, %{store: store, cashier: nil}} =
               Stores.register_branch(%{"name" => "Cabang A", "code" => code})

      assert Stores.get_active_store(store.id).code == code
    end

    test "registers the store and its first cashier together" do
      email = unique_user_email()

      assert {:ok, %{store: store, cashier: cashier}} =
               Stores.register_branch(
                 %{"name" => "Cabang B", "code" => code()},
                 %{"name" => "Kasir B", "email" => email, "password" => valid_user_password()}
               )

      assert {cashier.role, cashier.store_id} == {"cashier", store.id}
      assert cashier.confirmed_at
      assert Zahlungs.Accounts.get_user_by_email_and_password(email, valid_user_password())
      assert Scope.usable?(Scope.for_user(cashier))
    end

    test "accepts atom keys and ignores role and store_id from the caller" do
      other = store_fixture()

      assert {:ok, %{store: store, cashier: cashier}} =
               Stores.register_branch(
                 %{name: "Cabang C", code: code()},
                 %{
                   email: unique_user_email(),
                   password: valid_user_password(),
                   role: "admin",
                   store_id: other.id
                 }
               )

      assert {cashier.role, cashier.store_id} == {"cashier", store.id}
    end

    test "an invalid cashier saves nothing" do
      code = code()
      taken = user_fixture().email

      for cashier <- [
            %{"email" => unique_user_email(), "password" => "short"},
            %{"email" => taken, "password" => valid_user_password()},
            %{"name" => "", "email" => "", "password" => ""},
            %{}
          ] do
        assert {:error, :cashier, %Ecto.Changeset{}} =
                 Stores.register_branch(%{"name" => "Cabang D", "code" => code}, cashier)
      end

      refute Enum.any?(Stores.list_stores(), &(&1.code == code))
    end

    test "an invalid store saves nothing, cashier included" do
      existing = store_fixture()
      email = unique_user_email()

      assert {:error, :store, changeset} =
               Stores.register_branch(
                 %{"name" => "Cabang E", "code" => existing.code},
                 %{"email" => email, "password" => valid_user_password()}
               )

      assert %{code: [_ | _]} = errors_on(changeset)
      refute Zahlungs.Accounts.get_user_by_email(email)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/zahlungs/stores_test.exs`
Expected: FAIL — `register_branch/2` undefined for the five new tests, and "a taken code is an error on the changeset" fails on `refute changeset.valid?`. "a store keeps its own code when edited" passes already.

- [ ] **Step 3: Add `unsafe_validate_unique(:code, Zahlungs.Repo)` to `Store.changeset/2`** in `lib/zahlungs/stores/store.ex`, after `validate_format(:code, ...)` and before `unique_constraint(:code)` (so the code is already trimmed and upcased when checked).

- [ ] **Step 4: Implement `register_branch/2`** in `lib/zahlungs/stores.ex` with `Ecto.Multi`: insert the store; then, unless `cashier_attrs` is `nil`, call `Zahlungs.Accounts.create_user/1` with a string-keyed map built from the caller's `name`, `email`, `password` (read from either string or atom keys) plus `"role" => "cashier"` and `"store_id" => store.id`. Map `{:error, :store, changeset, _}` and `{:error, :cashier, changeset, _}` to the 3-tuples above. `nil` skips the cashier; any map — even an empty one — does not.

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/zahlungs/stores_test.exs && mix test`
Expected: PASS, whole suite 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/zahlungs/stores.ex lib/zahlungs/stores/store.ex test/zahlungs/stores_test.exs
git commit -m "feat(daftar-cabang): register a branch and its first cashier atomically"
```

---

### Task 2: The registration wizard

**Files:**
- Create: `lib/zahlungs_web/live/store_live/form_fields.ex`
- Create: `lib/zahlungs_web/live/store_live/register.ex`
- Modify: `lib/zahlungs_web/live/store_live/index.ex` (modal uses the shared fields)
- Modify: `lib/zahlungs_web/router.ex` (admin live session)
- Modify: `lib/zahlungs_web/components/layouts.ex` (navbar link)
- Test: `test/zahlungs_web/live/store_register_live_test.exs`

**Interfaces:**
- Consumes: `Stores.register_branch/2` (Task 1), `Stores.change_store/2`, `Accounts.change_user_registration(%User{}, attrs)`.
- Produces:
  - `ZahlungsWeb.StoreLive.FormFields.store_fields(assigns)` — function component, attr `form` (a `Phoenix.HTML.Form` named `store`), rendering the inputs `name`, `code`, `address`, `phone`, `utc_offset_hours` (select WIB 7 / WITA 8 / WIT 9), and the `#store-location` block (`phx-hook="StoreLocation"`, inputs `latitude` / `longitude`, the `data-use-my-location` button) exactly as the modal in `StoreLive.Index` renders them today.
  - Route `live "/admin/stores/register", StoreLive.Register, :new`.
  - `ZahlungsWeb.StoreLive.Register` with assigns `step` (`:store | :cashier`), `store_params`, `cashier_params`, `store_form` (form name `store`), `cashier_form` (form name `user`), and events:

| Event | Params | Effect |
| --- | --- | --- |
| `validate_store` | `%{"store" => map}` | re-validate `store_form` (action `:validate`), keep `step` |
| `next` | `%{"store" => map}` | valid → remember `store_params`, `step: :cashier`; invalid → stay, show errors |
| `back` | — | `step: :store`, forms rebuilt from remembered params |
| `validate_cashier` | `%{"user" => map}` | remember `cashier_params`, re-validate `cashier_form` |
| `save` | `%{"user" => map}` | `register_branch(store_params, map)` |
| `skip` | — | `register_branch(store_params, nil)` |

  `save` / `skip` while `step == :store` do nothing. Results: `{:ok, %{store: store}}` → success flash + `push_navigate(to: ~p"/admin/stores")`; `{:error, :store, cs}` → `step: :store` with `store_form` from `cs`; `{:error, :cashier, cs}` → stay on `:cashier` with `cashier_form` from `cs`.

- [ ] **Step 1: Write the failing tests** — create `test/zahlungs_web/live/store_register_live_test.exs`:

```elixir
defmodule ZahlungsWeb.StoreRegisterLiveTest do
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Accounts, Stores}
  alias ZahlungsWeb.StoreLive

  defp admin_fixture do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp code, do: "W" <> Integer.to_string(System.unique_integer([:positive]), 36)

  defp store_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Cabang Wizard",
        "code" => code(),
        "address" => "Jl. Anggrek 3",
        "phone" => "",
        "utc_offset_hours" => "8",
        "latitude" => "",
        "longitude" => ""
      },
      overrides
    )
  end

  defp cashier_params(overrides \\ %{}) do
    Map.merge(
      %{"name" => "Kasir Wizard", "email" => unique_user_email(), "password" => valid_user_password()},
      overrides
    )
  end

  defp store_with(code), do: Enum.find(Stores.list_stores(), &(&1.code == code))

  defp on_step_two(store \\ store_params()) do
    StoreLive.Register |> mount_live(admin_fixture(), action: :new) |> event("next", %{"store" => store})
  end

  describe "access" do
    test "guests go to log in, cashiers to /, admins see step 1", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/stores/register")) == "/users/log_in"

      assert conn |> log_in_user(user_fixture()) |> get("/admin/stores/register") |> redirected_to() ==
               "/"

      response =
        conn |> log_in_user(admin_fixture()) |> get("/admin/stores/register") |> html_response(200)

      assert response =~ "Langkah 1 dari 2 — Data toko"
      assert response =~ ~s(href="/admin/stores/register")
      assert response =~ "Daftar Cabang"
    end
  end

  describe "step 1" do
    test "valid store data moves to step 2 without saving anything" do
      params = store_params()
      socket = on_step_two(params)

      assert socket.assigns.step == :cashier
      assert html(socket) =~ "Langkah 2 dari 2 — Kasir pertama (opsional)"
      assert html(socket) =~ "Cabang Wizard"
      refute store_with(params["code"])
    end

    test "invalid store data stays on step 1 with the errors" do
      taken = store_fixture().code

      for {bad, field} <- [
            {%{"name" => ""}, :name},
            {%{"code" => String.downcase(taken)}, :code},
            {%{"latitude" => "-6.2"}, :longitude}
          ] do
        socket = on_step_two(store_params(bad))

        assert socket.assigns.step == :store
        assert socket.assigns.store_form.errors[field]
        assert html(socket) =~ "Langkah 1 dari 2 — Data toko"
      end
    end

    test "validate_store shows errors while typing" do
      socket =
        StoreLive.Register
        |> mount_live(admin_fixture(), action: :new)
        |> event("validate_store", %{"store" => store_params(%{"code" => "x y"})})

      assert socket.assigns.step == :store
      assert socket.assigns.store_form.errors[:code]
    end

    test "save and skip do nothing before step 2" do
      socket = mount_live(StoreLive.Register, admin_fixture(), action: :new)
      before = length(Stores.list_stores())

      assert event(socket, "skip").assigns.step == :store
      assert event(socket, "save", %{"user" => cashier_params()}).assigns.step == :store
      assert length(Stores.list_stores()) == before
    end
  end

  describe "step 2" do
    test "back returns to step 1 with the store and cashier data kept" do
      params = store_params()
      cashier = cashier_params()

      socket =
        params
        |> on_step_two()
        |> event("validate_cashier", %{"user" => cashier})
        |> event("back")

      assert socket.assigns.step == :store
      assert socket.assigns.store_form[:name].value == "Cabang Wizard"
      assert socket.assigns.store_form[:code].value == params["code"]

      socket = event(socket, "next", %{"store" => params})
      assert socket.assigns.cashier_form[:email].value == cashier["email"]
    end

    test "skip registers the store alone, ignoring what was typed for the cashier" do
      params = store_params()
      cashier = cashier_params()

      socket =
        params
        |> on_step_two()
        |> event("validate_cashier", %{"user" => cashier})
        |> event("skip")

      store = store_with(params["code"])
      assert {store.name, store.utc_offset_hours, store.address} == {"Cabang Wizard", 8, "Jl. Anggrek 3"}
      refute Accounts.get_user_by_email(cashier["email"])
      assert live_redirect(socket) == "/admin/stores"

      assert flash(socket, :info) ==
               "Cabang Cabang Wizard terdaftar. Stoknya masih 0 — pilih cabang ini di menu atas, lalu isi stok lewat Products."
    end

    test "save registers the store and a cashier who can log in there" do
      params = store_params()
      cashier = cashier_params()

      socket = params |> on_step_two() |> event("save", %{"user" => cashier})

      store = store_with(params["code"])
      user = Accounts.get_user_by_email_and_password(cashier["email"], cashier["password"])
      assert {user.role, user.store_id, user.name} == {"cashier", store.id, "Kasir Wizard"}
      assert live_redirect(socket) == "/admin/stores"
    end

    test "a cashier error keeps step 2 and saves no store" do
      params = store_params()
      taken = user_fixture().email

      for bad <- [%{"email" => taken}, %{"password" => "short"}, %{"email" => "", "password" => ""}] do
        socket = params |> on_step_two() |> event("save", %{"user" => cashier_params(bad)})

        assert socket.assigns.step == :cashier
        assert socket.assigns.cashier_form.errors != []
        assert live_redirect(socket) == nil
      end

      refute store_with(params["code"])
    end

    test "a code taken between step 1 and saving sends the admin back to step 1" do
      params = store_params()
      socket = on_step_two(params)
      store_fixture(code: params["code"])

      socket = event(socket, "skip")

      assert socket.assigns.step == :store
      assert socket.assigns.store_form.errors[:code]
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/zahlungs_web/live/store_register_live_test.exs`
Expected: FAIL — `ZahlungsWeb.StoreLive.Register` is not available / no route for `/admin/stores/register`.

- [ ] **Step 3: Extract `ZahlungsWeb.StoreLive.FormFields.store_fields/1`** (`use ZahlungsWeb, :html`) by moving the inputs out of the modal in `StoreLive.Index` unchanged, and render `<.store_fields form={@form} />` inside that modal's `<.form>`.

Run: `mix test test/zahlungs_web/live/store_live_test.exs`
Expected: PASS (the modal renders as before).

- [ ] **Step 4: Add the route** `live "/admin/stores/register", StoreLive.Register, :new` next to the other `/admin/stores` routes in the admin `live_session`, and the navbar link `Daftar Cabang` (admin only, `href={~p"/admin/stores/register"}`) right after the `Stores` link in `Layouts.user_menu/1`.

- [ ] **Step 5: Implement `ZahlungsWeb.StoreLive.Register`** per the Interfaces table. `mount/3` starts at `step: :store` with empty params. Build `store_form` with `to_form(Stores.change_store(%Store{}, params))` and `cashier_form` with `to_form(Accounts.change_user_registration(%User{}, params), as: :user)`; pass `action: :validate` whenever errors should show. `next` decides on `Ecto.Changeset.apply_action(changeset, :validate)`. Step 1 renders the heading, `<.store_fields form={@store_form} />` in a form with `phx-change="validate_store"` `phx-submit="next"` and the `Lanjut` button. Step 2 renders the heading, a summary of `store_params` (name, code, address), the cashier inputs `name`, `email`, `password` in a form with `phx-change="validate_cashier"` `phx-submit="save"` and the `Daftarkan cabang` button, plus `Kembali` (`phx-click="back"`) and `Lewati` (`phx-click="skip"`) as `type="button"`.

- [ ] **Step 6: Run to verify they pass**

Run: `mix test test/zahlungs_web/live/store_register_live_test.exs && mix test`
Expected: PASS, whole suite 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/zahlungs_web test/zahlungs_web/live/store_register_live_test.exs
git commit -m "feat(daftar-cabang): two-step branch registration wizard"
```

---

### Task 3: Retire the old "Toko baru" path

**Files:**
- Modify: `lib/zahlungs_web/router.ex` (remove one route)
- Modify: `lib/zahlungs_web/live/store_live/index.ex`
- Modify: `test/zahlungs_web/live/store_live_test.exs`
- Modify: `docs/IA.md`, `docs/superpowers/specs/2026-10-10-branch-registration-design.md` (status)

**Interfaces:**
- Consumes: the route `/admin/stores/register` (Task 2).
- Produces: `StoreLive.Index` with live actions `:index` and `:edit` only.

- [ ] **Step 1: Change the tests first** in `test/zahlungs_web/live/store_live_test.exs`: delete `"creates a store from the form"` and `"shows the errors and saves nothing when the form is invalid"` (their behaviour is covered by Task 2's wizard tests), and add:

```elixir
    test "stores are created through the registration wizard only", %{conn: conn} do
      conn = log_in_user(conn, admin_fixture())

      assert conn |> get("/admin/stores/new") |> response(404)

      response = conn |> get("/admin/stores") |> html_response(200)
      assert response =~ "Daftar cabang"
      refute response =~ "Toko baru"
    end

    test "an invalid edit keeps the modal open with the errors", %{admin: admin} do
      store = store_fixture()

      socket =
        StoreLive.Index
        |> mount_live(admin, action: :edit, params: %{"id" => "#{store.id}"})
        |> event("save", %{"store" => %{"name" => "", "code" => store.code}})

      assert socket.assigns.form.errors[:name]
      assert live_redirect(socket) == nil
      assert Stores.get_store!(store.id).name == store.name
    end
```

  Put the first in the `"/admin/stores access control"` describe and the second in `"managing stores"`.

- [ ] **Step 2: Run to verify the new test fails**

Run: `mix test test/zahlungs_web/live/store_live_test.exs`
Expected: FAIL on "stores are created through the registration wizard only" (`/admin/stores/new` still answers 200). The invalid-edit test passes already.

- [ ] **Step 3: Remove the old path.** Delete `live "/admin/stores/new", StoreLive.Index, :new` from the router. In `StoreLive.Index`: delete the `apply_action(socket, :new, _)` clause and the create branch of `save` (it only updates now), show the modal for `:edit` only, and replace the "Toko baru" button with `<.link navigate={~p"/admin/stores/register"}><.button>Daftar cabang</.button></.link>`.

- [ ] **Step 4: Run to verify**

Run: `mix test && mix compile --force --warnings-as-errors && mix format --check-formatted && mix credo`
Expected: 0 failures, no warnings, formatter and credo clean.

- [ ] **Step 5: Update the docs.** In `docs/IA.md`, replace the `/admin/stores` sitemap line with `/admin/stores  Manajemen toko/cabang (ubah, aktif/nonaktif)` and add below it `/admin/stores/register  Daftar cabang: wizard 2 langkah (data toko, kasir pertama opsional)`. In the spec, change `Status: menunggu tinjauan` to `Status: diimplementasikan`.

- [ ] **Step 6: Commit**

```bash
git add lib/zahlungs_web test/zahlungs_web/live/store_live_test.exs docs
git commit -m "refactor(daftar-cabang): create stores through the wizard only"
```
