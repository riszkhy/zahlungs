defmodule ZahlungsWeb.SalesLiveTest do
  @moduledoc """
  Sales history tests: access and render via `get/2`, and the void / return
  flows by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import ZahlungsWeb.LiveDriver
  import Ecto.Query, only: [from: 2]

  alias Zahlungs.{Sales, Shifts}
  alias ZahlungsWeb.SalesLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  # A cashier on an open shift with one completed sale of 3 units (stock 10 -> 7).
  defp sale_fixture(_context) do
    cashier = user_on_shift_fixture()
    product = product_fixture(price: Decimal.new("1000"), stock: 10)

    {:ok, sale} =
      Sales.create_sale(cashier, [%{product_id: product.id, quantity: 3}], %{amount_paid: "3000"})

    %{cashier: cashier, product: product, sale: sale}
  end

  describe "/sales" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/sales")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "lists sales for authenticated users", %{conn: conn} do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "1000"})

      conn = conn |> log_in_user(user) |> get("/sales")
      response = html_response(conn, 200)
      assert response =~ "Sales"
      assert response =~ sale.code
    end
  end

  describe "date filter" do
    setup :sale_fixture

    test "narrows the list to the chosen shop-local day", %{cashier: cashier, sale: sale} do
      socket = mount_live(SalesLive.Index, cashier)
      today = Date.to_iso8601(Zahlungs.LocalTime.today())

      on_day = event(socket, "filter", %{"date" => today})
      assert sale.id in Enum.map(on_day.assigns.sales, & &1.id)

      assert event(socket, "filter", %{"date" => "2000-01-01"}).assigns.sales == []

      # An unparsable date falls back to "no filter" instead of crashing.
      unfiltered = event(socket, "filter", %{"date" => "not-a-date"})
      assert sale.id in Enum.map(unfiltered.assigns.sales, & &1.id)
    end
  end

  describe "narrow screens" do
    setup :sale_fixture

    test "each sale is also a card that opens its detail", %{cashier: cashier, sale: sale} do
      rendered = SalesLive.Index |> mount_live(cashier) |> html()

      [_, card] = Regex.run(~r{<a[^>]*id="sale-card-#{sale.id}"[^>]*>(.*?)</a>}s, rendered)

      assert rendered =~ ~s(href="/sales/#{sale.id}")
      assert card =~ sale.code
      assert card =~ "completed"
    end
  end

  describe "paging" do
    test "shows 25 per page and clamps out-of-range pages" do
      cashier = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 100)
      day = ~D[2001-06-06]
      {start, _finish} = Zahlungs.LocalTime.day_range(day, day)

      for _ <- 1..26 do
        {:ok, _} =
          Sales.create_sale(cashier, [%{product_id: product.id, quantity: 1}], %{
            amount_paid: "1000"
          })
      end

      Zahlungs.Repo.update_all(
        from(s in Sales.Sale, where: s.user_id == ^cashier.id),
        set: [inserted_at: NaiveDateTime.add(start, 3600)]
      )

      socket =
        SalesLive.Index |> mount_live(cashier) |> event("filter", %{"date" => "2001-06-06"})

      assert socket.assigns.total == 26
      assert socket.assigns.total_pages == 2
      assert length(socket.assigns.sales) == 25
      assert html(socket) =~ "Menampilkan 1–25 dari 26 penjualan"

      # The page buttons push the page as a JSON number.
      last = event(socket, "page", %{"to" => 2})
      assert last.assigns.page == 2
      assert length(last.assigns.sales) == 1
      assert html(last) =~ "Menampilkan 26–26 dari 26 penjualan"

      assert event(last, "page", %{"to" => 99}).assigns.page == 2
      assert event(last, "page", %{"to" => "0"}).assigns.page == 1

      # Changing the filter goes back to the first page.
      assert event(last, "filter", %{"date" => ""}).assigns.page == 1
    end
  end

  describe "void" do
    setup :sale_fixture

    test "a cashier voids their own sale with a reason; stock comes back",
         %{cashier: cashier, product: product, sale: sale} do
      socket =
        SalesLive.Index
        |> mount_live(cashier, action: :show, params: %{"id" => "#{sale.id}"})
        |> event("prompt_void", %{"id" => sale.id})

      assert socket.assigns.voiding.id == sale.id

      socket = event(socket, "do_void", %{"reason" => "salah qty"})

      assert flash(socket, :info) =~ "dibatalkan"
      assert live_redirect(socket) == "/sales"
      assert is_nil(socket.assigns.voiding)

      voided = Sales.get_sale!(store_scope(), sale.id)
      assert voided.status == "void"
      assert voided.void_reason == "salah qty"
      assert voided.voided_by_id == cashier.id
      assert stock_of(product) == 10
    end

    test "a reason is required", %{cashier: cashier, product: product, sale: sale} do
      socket =
        SalesLive.Index
        |> mount_live(cashier)
        |> event("prompt_void", %{"id" => sale.id})
        |> event("do_void", %{"reason" => ""})

      assert flash(socket, :error) =~ "Gagal membatalkan"
      assert Sales.get_sale!(store_scope(), sale.id).status == "completed"
      assert stock_of(product) == 7
    end

    test "a cashier cannot void someone else's sale", %{product: product, sale: sale} do
      socket =
        SalesLive.Index
        |> mount_live(user_fixture())
        |> event("prompt_void", %{"id" => sale.id})
        |> event("do_void", %{"reason" => "iseng"})

      assert flash(socket, :error) =~ "penjualan sendiri"
      assert Sales.get_sale!(store_scope(), sale.id).status == "completed"
      assert stock_of(product) == 7
    end

    test "after the shift is closed only an admin can void",
         %{cashier: cashier, product: product, sale: sale} do
      {:ok, _} = Shifts.close_shift(Shifts.current_shift(cashier), "3000")

      as_cashier =
        SalesLive.Index
        |> mount_live(cashier)
        |> event("prompt_void", %{"id" => sale.id})
        |> event("do_void", %{"reason" => "telat"})

      assert flash(as_cashier, :error) =~ "Shift sudah ditutup"
      assert Sales.get_sale!(store_scope(), sale.id).status == "completed"

      as_admin =
        SalesLive.Index
        |> mount_live(admin_fixture())
        |> event("prompt_void", %{"id" => sale.id})
        |> event("do_void", %{"reason" => "koreksi admin"})

      assert flash(as_admin, :info) =~ "dibatalkan"
      assert Sales.get_sale!(store_scope(), sale.id).status == "void"
      assert stock_of(product) == 10
    end

    test "voiding twice from two open screens restores the stock only once",
         %{cashier: cashier, product: product, sale: sale} do
      prompt = fn ->
        SalesLive.Index |> mount_live(cashier) |> event("prompt_void", %{"id" => sale.id})
      end

      first = prompt.()
      second = prompt.()

      assert flash(event(first, "do_void", %{"reason" => "salah"}), :info) =~ "dibatalkan"
      assert flash(event(second, "do_void", %{"reason" => "salah"}), :error) =~ "tidak bisa"
      assert stock_of(product) == 10
    end

    test "cancelling the prompt leaves the sale alone", %{cashier: cashier, sale: sale} do
      socket =
        SalesLive.Index
        |> mount_live(cashier)
        |> event("prompt_void", %{"id" => sale.id})
        |> event("void_change", %{"reason" => "ragu"})
        |> event("cancel_void")

      assert is_nil(socket.assigns.voiding)
      assert socket.assigns.void_reason == ""
      assert Sales.get_sale!(store_scope(), sale.id).status == "completed"
    end
  end

  describe "return" do
    setup :sale_fixture

    test "is refused for cashiers", %{cashier: cashier, product: product, sale: sale} do
      socket = SalesLive.Index |> mount_live(cashier) |> event("return", %{"id" => sale.id})

      assert flash(socket, :error) =~ "permission"
      assert Sales.get_sale!(store_scope(), sale.id).status == "completed"
      assert stock_of(product) == 7
    end

    test "an admin returns the sale once; a second attempt is reported",
         %{product: product, sale: sale} do
      socket = mount_live(SalesLive.Index, admin_fixture())

      returned = event(socket, "return", %{"id" => sale.id})
      assert flash(returned, :info) =~ "returned; stock restored"
      assert live_redirect(returned) == "/sales"
      assert Sales.get_sale!(store_scope(), sale.id).status == "returned"

      again = event(socket, "return", %{"id" => sale.id})
      assert flash(again, :error) =~ "already been returned"
      assert stock_of(product) == 10
    end

    test "a return after the shift closed is refunded from the admin's own drawer",
         %{cashier: cashier, sale: sale} do
      {:ok, _} = Shifts.close_shift(Shifts.current_shift(cashier), "103000")
      admin = admin_fixture()
      admin_shift = shift_fixture(admin, "50000")

      SalesLive.Index |> mount_live(admin) |> event("return", %{"id" => sale.id})

      assert [%{category: "refund"}] = Shifts.list_cash_movements(admin_shift)
      assert Decimal.equal?(Shifts.expected_cash(admin_shift), Decimal.new("47000"))
    end
  end
end
