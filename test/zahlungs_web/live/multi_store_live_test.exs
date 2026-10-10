defmodule ZahlungsWeb.MultiStoreLiveTest do
  @moduledoc """
  The existing screens with two stores: each shows its own store's data, and
  nothing of the other's is reachable.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Accounts, Catalog, Sales, Shifts}
  alias ZahlungsWeb.{CashierLive, CatalogLive, ReportLive, SalesLive, ShiftLive, UserLive}

  # Store A (the default) and store B, a product stocked in both, a cashier on
  # shift in each with one sale, and an admin whose own store is A.
  setup do
    store_a = default_store()

    store_b =
      store_fixture(name: "Cabang B", code: "CBB", address: "Jl. Kenanga 5", phone: "0812-000")

    product = product_fixture(price: Decimal.new("1000"), stock: 10)

    {:ok, _} =
      Catalog.update_product(
        store_scope(store_b),
        Catalog.get_product!(store_scope(store_b), product.id),
        %{stock: 4}
      )

    cashier_a = user_on_shift_fixture()
    cashier_b = user_fixture(store_id: store_b.id)
    shift_b = shift_fixture(cashier_b)
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")

    cart = [%{product_id: product.id, quantity: 1}]
    {:ok, sale_a} = Sales.create_sale(cashier_a, cart, %{amount_paid: "1000"})
    {:ok, sale_b} = Sales.create_sale(cashier_b, cart, %{amount_paid: "1000"})

    %{
      store_a: store_a,
      store_b: store_b,
      product: product,
      cashier_a: cashier_a,
      cashier_b: cashier_b,
      shift_b: shift_b,
      admin: admin,
      sale_a: sale_a,
      sale_b: sale_b
    }
  end

  describe "receipt" do
    test "is headed by the store that made the sale", %{conn: conn} = ctx do
      response =
        conn
        |> log_in_user(ctx.cashier_b)
        |> get("/sales/#{ctx.sale_b.id}/receipt")
        |> html_response(200)

      assert response =~ "<h1>Cabang B</h1>"
      assert response =~ "Jl. Kenanga 5"
      assert response =~ "0812-000"
      assert response =~ ctx.sale_b.code
    end

    test "of another store is not found", %{conn: conn} = ctx do
      assert_error_sent 404, fn ->
        conn |> log_in_user(ctx.cashier_b) |> get("/sales/#{ctx.sale_a.id}/receipt")
      end
    end
  end

  describe "sales history" do
    test "lists only the cashier's store and names it in the detail", ctx do
      socket =
        mount_live(SalesLive.Index, ctx.cashier_b,
          action: :show,
          params: %{"id" => "#{ctx.sale_b.id}"}
        )

      assert Enum.map(socket.assigns.sales, & &1.id) == [ctx.sale_b.id]
      assert html(socket) =~ "Cabang B"
    end

    test "another store's sale cannot be opened or voided", ctx do
      assert_raise Ecto.NoResultsError, fn ->
        mount_live(SalesLive.Index, ctx.cashier_b,
          action: :show,
          params: %{"id" => "#{ctx.sale_a.id}"}
        )
      end

      assert_raise Ecto.NoResultsError, fn ->
        SalesLive.Index
        |> mount_live(ctx.cashier_b)
        |> event("prompt_void", %{"id" => ctx.sale_a.id})
      end

      assert Sales.get_sale!(store_scope(ctx.store_a), ctx.sale_a.id).status == "completed"
    end

    test "an admin over all stores sees which store each sale belongs to", ctx do
      socket = mount_live(SalesLive.Index, ctx.admin, store: "all")
      ids = Enum.map(socket.assigns.sales, & &1.id)

      assert ctx.sale_a.id in ids and ctx.sale_b.id in ids
      assert html(socket) =~ "Cabang B"
    end
  end

  describe "shift history" do
    test "another store's shift cannot be opened", ctx do
      assert_raise Ecto.NoResultsError, fn ->
        mount_live(ShiftLive.Index, ctx.cashier_a,
          action: :show,
          params: %{"id" => "#{ctx.shift_b.id}"}
        )
      end
    end

    test "an admin picks the store whose shifts to see", ctx do
      socket = mount_live(ShiftLive.Index, ctx.admin, store: ctx.store_b.id)

      assert Enum.map(socket.assigns.shifts, & &1.id) == [ctx.shift_b.id]
    end
  end

  describe "sales report" do
    test "breaks the figures down per store when looking at all stores", ctx do
      socket = mount_live(ReportLive.Index, ctx.admin, store: "all")

      names = Enum.map(socket.assigns.by_store, & &1.store)
      assert ctx.store_a.name in names and "Cabang B" in names
      assert html(socket) =~ "Sales by store"
    end

    test "has no per-store breakdown for a single store", ctx do
      socket = mount_live(ReportLive.Index, ctx.admin, store: ctx.store_b.id)

      assert socket.assigns.by_store == []
      assert socket.assigns.report.transactions == 1
      refute html(socket) =~ "Sales by store"
    end
  end

  describe "cashier" do
    test "an admin looking at all stores is asked to pick one before opening a shift", ctx do
      socket =
        CashierLive
        |> mount_live(ctx.admin, store: "all")
        |> event("open_shift", %{"opening_cash" => "0"})

      assert flash(socket, :error) =~ "Pilih satu toko"
      assert Shifts.current_shift(ctx.admin) == nil
      assert html(socket) =~ "Pilih satu toko"
    end

    test "sells from the store of the open shift, even after the admin switches store", ctx do
      {:ok, _} = Shifts.open_shift(Zahlungs.Scope.for_user(ctx.admin, ctx.store_b.id), "0")

      # The navbar now says store A, but the open drawer is in B.
      socket = mount_live(CashierLive, ctx.admin, store: ctx.store_a.id)

      assert socket.assigns.sale_scope.store.id == ctx.store_b.id
      assert html(socket) =~ "Cabang B"

      socket = event(socket, "scan", %{"q" => ctx.product.sku})
      # Store B has 3 left (4 minus the sale in setup), store A has 9.
      assert [%{stock: 3}] = socket.assigns.cart
    end

    test "keeps selling from the open shift's store when the admin looks at all stores", ctx do
      {:ok, _} = Shifts.open_shift(Zahlungs.Scope.for_user(ctx.admin, ctx.store_b.id), "0")

      socket =
        CashierLive
        |> mount_live(ctx.admin, store: "all")
        |> event("scan", %{"q" => ctx.product.sku})

      # Not the 12 units summed over both stores: only store B's 3 can be sold here.
      assert socket.assigns.sale_scope.store.id == ctx.store_b.id
      assert [%{stock: 3}] = socket.assigns.cart
    end

    test "the search shows the stock of the cashier's own store", ctx do
      socket =
        CashierLive |> mount_live(ctx.cashier_b) |> event("search", %{"q" => ctx.product.sku})

      assert [%{stock: 3}] = socket.assigns.results
    end
  end

  describe "catalog" do
    test "shows each store its own stock", ctx do
      in_b =
        CatalogLive
        |> mount_live(ctx.cashier_b)
        |> event("filter", %{"search" => ctx.product.sku})

      in_a =
        CatalogLive
        |> mount_live(ctx.cashier_a)
        |> event("filter", %{"search" => ctx.product.sku})

      assert [%{stock: 3}] = in_b.assigns.products
      assert [%{stock: 9}] = in_a.assigns.products
    end
  end

  describe "home" do
    test "renders for an admin over all stores", %{conn: conn} = ctx do
      conn = conn |> log_in_user(ctx.admin) |> post("/stores/select", %{"store_id" => "all"})

      assert conn |> get("/home") |> html_response(200) =~ "Semua toko"
    end
  end

  describe "user management" do
    test "lists each user's store", ctx do
      socket = mount_live(UserLive.Index, ctx.admin)

      assert %{store: %{name: "Cabang B"}} =
               Enum.find(socket.assigns.users, &(&1.id == ctx.cashier_b.id))

      assert html(socket) =~ ~s(id="user-store-#{ctx.cashier_b.id}")
    end

    test "moves a cashier to another store", ctx do
      socket =
        UserLive.Index
        |> mount_live(ctx.admin)
        |> event("set_store", %{
          "user_id" => "#{ctx.cashier_a.id}",
          "store_id" => "#{ctx.store_b.id}"
        })

      assert flash(socket, :info) =~ "dipindahkan"
      assert Accounts.get_user!(ctx.cashier_a.id).store_id == ctx.store_b.id
    end

    test "a cashier cannot be left without a store", ctx do
      socket =
        UserLive.Index
        |> mount_live(ctx.admin)
        |> event("set_store", %{"user_id" => ctx.cashier_a.id, "store_id" => ""})

      assert flash(socket, :error) =~ "kasir harus punya toko"
      assert Accounts.get_user!(ctx.cashier_a.id).store_id == ctx.store_a.id
    end
  end
end
