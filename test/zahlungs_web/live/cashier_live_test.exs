defmodule ZahlungsWeb.CashierLiveTest do
  @moduledoc """
  Cashier page tests: access and initial render via `get/2`, and the sale /
  shift flows by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Catalog, Sales, Shifts}
  alias ZahlungsWeb.CashierLive

  describe "/cashier" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/cashier")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "prompts to open a shift when the cashier has none", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/cashier")
      response = html_response(conn, 200)
      assert response =~ "Cashier"
      assert response =~ "Open shift"
      refute response =~ ">Cart<"
    end

    test "shows the cart once a shift is open", %{conn: conn} do
      user = user_fixture()
      {:ok, _shift} = Zahlungs.Shifts.open_shift(scope(user), 100_000)

      conn = conn |> log_in_user(user) |> get("/cashier")
      response = html_response(conn, 200)
      assert response =~ "Cart"
      assert response =~ "Close shift"
    end
  end

  describe "opening a shift" do
    test "opens the shift from the thousands-formatted opening cash" do
      user = user_fixture()

      socket =
        CashierLive |> mount_live(user) |> event("open_shift", %{"opening_cash" => "100.000"})

      assert flash(socket, :info) == "Shift opened."
      assert Decimal.equal?(socket.assigns.shift.opening_cash, Decimal.new("100000"))
      assert Shifts.current_shift(user).id == socket.assigns.shift.id
      assert html(socket) =~ "Close shift"
    end

    test "picks up a shift that was already opened elsewhere" do
      user = user_fixture()
      socket = mount_live(CashierLive, user)
      shift = shift_fixture(user)

      socket = event(socket, "open_shift", %{"opening_cash" => "0"})

      assert flash(socket, :error) =~ "already have an open shift"
      assert socket.assigns.shift.id == shift.id
    end
  end

  describe "building the cart" do
    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 3)
      %{user: user, product: product, socket: mount_live(CashierLive, user)}
    end

    test "scanning a SKU adds the product and beeps; scanning again raises the quantity",
         %{socket: socket, product: product} do
      socket = event(socket, "scan", %{"q" => " #{product.sku} "})

      assert [%{product_id: id, quantity: 1}] = socket.assigns.cart
      assert id == product.id
      assert pushed_events(socket) == [{"beep", %{type: "ok"}}]
      assert socket.assigns.search == ""

      socket = event(socket, "scan", %{"q" => product.sku})

      assert [%{quantity: 2}] = socket.assigns.cart
      assert Decimal.equal?(socket.assigns.subtotal, Decimal.new("2000"))
      assert html(socket) =~ product.name
    end

    test "scanning an unknown code changes nothing and beeps an error", %{socket: socket} do
      socket =
        event(socket, "scan", %{"q" => "NO-SUCH-CODE-#{System.unique_integer([:positive])}"})

      assert socket.assigns.cart == []
      assert flash(socket, :error) =~ "No product found"
      assert pushed_events(socket) == [{"beep", %{type: "error"}}]
    end

    test "scanning an out-of-stock product is refused", %{socket: socket} do
      empty = product_fixture(stock: 0)
      socket = event(socket, "scan", %{"q" => empty.sku})

      assert socket.assigns.cart == []
      assert flash(socket, :error) == "Product is out of stock."
    end

    test "search lists matching products and add puts one in the cart",
         %{socket: socket, product: product} do
      socket = event(socket, "search", %{"q" => product.name})
      assert Enum.map(socket.assigns.results, & &1.id) == [product.id]

      # JS.push sends the id as an integer, a form would send a string.
      socket =
        socket |> event("add", %{"id" => product.id}) |> event("add", %{"id" => "#{product.id}"})

      assert [%{quantity: 2}] = socket.assigns.cart

      # A blank search goes back to the product tiles, not to an empty list.
      blank = event(socket, "search", %{"q" => "  "})
      assert blank.assigns.search == "  "
      assert blank.assigns.results != []
    end

    test "quantity is capped at the stock on hand, and decreasing below 1 removes the line",
         %{socket: socket, product: product} do
      id = product.id
      socket = event(socket, "scan", %{"q" => product.sku})

      socket = Enum.reduce(1..5, socket, fn _, socket -> event(socket, "inc", %{"id" => id}) end)
      assert [%{quantity: 3}] = socket.assigns.cart

      socket = socket |> event("dec", %{"id" => id}) |> event("dec", %{"id" => id})
      assert [%{quantity: 1}] = socket.assigns.cart

      assert event(socket, "dec", %{"id" => id}).assigns.cart == []
      assert event(socket, "remove", %{"id" => id}).assigns.cart == []
    end
  end

  describe "product tiles" do
    setup do
      user = user_on_shift_fixture()
      category = category_fixture()
      label = "Tile #{System.unique_integer([:positive])}"

      in_stock =
        product_fixture(name: "#{label} A", stock: 5, category_id: category.id)

      sold_out = product_fixture(name: "#{label} B", stock: 0, category_id: category.id)
      elsewhere = product_fixture(name: "#{label} C", stock: 5)

      %{
        user: user,
        category: category,
        label: label,
        in_stock: in_stock,
        sold_out: sold_out,
        elsewhere: elsewhere,
        socket: mount_live(CashierLive, user)
      }
    end

    test "are shown without searching: in-stock products only, at most 24", %{socket: socket} do
      assert socket.assigns.results != []
      assert length(socket.assigns.results) <= 24
      assert Enum.all?(socket.assigns.results, &(&1.stock > 0 and &1.active))
    end

    test "a category chip narrows the tiles, and clearing it widens them again", ctx do
      socket = event(ctx.socket, "set_category", %{"id" => ctx.category.id})

      assert Enum.map(socket.assigns.results, & &1.id) == [ctx.in_stock.id]
      assert html(socket) =~ ctx.in_stock.name
      refute html(socket) =~ ctx.sold_out.name

      socket = event(socket, "set_category", %{"id" => ""})
      assert socket.assigns.category_id == nil
    end

    test "search and category combine", ctx do
      socket = event(ctx.socket, "search", %{"q" => ctx.label})

      assert Enum.sort(Enum.map(socket.assigns.results, & &1.id)) ==
               Enum.sort([ctx.in_stock.id, ctx.elsewhere.id])

      socket = event(socket, "set_category", %{"id" => "#{ctx.category.id}"})
      assert Enum.map(socket.assigns.results, & &1.id) == [ctx.in_stock.id]
    end

    test "tapping a tile adds the product to the cart", ctx do
      socket =
        ctx.socket
        |> event("set_category", %{"id" => ctx.category.id})
        |> event("add", %{"id" => ctx.in_stock.id})

      assert [%{product_id: id, quantity: 1}] = socket.assigns.cart
      assert id == ctx.in_stock.id
    end

    test "a product sold out by this sale leaves the tiles", ctx do
      last_one = product_fixture(name: "#{ctx.label} Last", price: Decimal.new("1000"), stock: 1)

      socket =
        ctx.socket
        |> event("search", %{"q" => last_one.name})
        |> event("add", %{"id" => last_one.id})
        |> event("set_amount_paid", %{"value" => "1000"})
        |> event("checkout")
        |> event("new_sale")
        |> event("search", %{"q" => last_one.name})

      assert socket.assigns.results == []
    end

    test "the cart panel can be opened and closed (portrait)", %{socket: socket} do
      refute socket.assigns.cart_open

      socket = event(socket, "toggle_cart")
      assert socket.assigns.cart_open

      refute event(socket, "toggle_cart").assigns.cart_open
    end
  end

  describe "quick cash" do
    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      socket =
        CashierLive
        |> mount_live(user)
        |> event("scan", %{"q" => product.sku})
        |> event("scan", %{"q" => product.sku})

      %{socket: socket}
    end

    test "exact amount fills in the total and enables checkout", %{socket: socket} do
      socket = event(socket, "quick_cash", %{"amount" => "exact"})

      assert socket.assigns.amount_paid == "2000"
      assert socket.assigns.can_checkout
      assert Decimal.equal?(socket.assigns.change_due, Decimal.new("0"))
      assert pushed_events(socket) == [{"set_amount_paid_input", %{value: "2000"}}]
    end

    test "a denomination sets the amount paid and shows the change", %{socket: socket} do
      socket = event(socket, "quick_cash", %{"amount" => 50_000})

      assert socket.assigns.amount_paid == "50000"
      assert Decimal.equal?(socket.assigns.change_due, Decimal.new("48000"))
      assert socket.assigns.can_checkout
    end

    test "exact amount rounds a fractional total up to whole rupiah", %{socket: socket} do
      socket =
        socket
        |> event("payment", %{"discount" => "0.5", "tax" => ""})
        |> event("quick_cash", %{"amount" => "exact"})

      assert socket.assigns.amount_paid == "2000"
      assert socket.assigns.can_checkout
    end

    test "offers exact cash and only denominations that cover the total", %{socket: socket} do
      rendered = html(socket)

      assert rendered =~ "Uang pas"
      assert rendered =~ "5.000"
      assert rendered =~ "100.000"
      refute rendered =~ ~s(data-quick-cash="1000")
    end
  end

  describe "payment" do
    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      socket =
        CashierLive
        |> mount_live(user)
        |> event("scan", %{"q" => product.sku})
        |> event("scan", %{"q" => product.sku})

      %{user: user, product: product, socket: socket}
    end

    test "checkout is disabled until the cash covers the total", %{socket: socket} do
      refute socket.assigns.can_checkout

      socket = event(socket, "set_amount_paid", %{"value" => "1999"})
      refute socket.assigns.can_checkout

      socket = event(socket, "set_amount_paid", %{"value" => "5000"})
      assert socket.assigns.can_checkout
      assert Decimal.equal?(socket.assigns.change_due, Decimal.new("3000"))
    end

    test "discount and tax feed the total", %{socket: socket} do
      socket = event(socket, "payment", %{"discount" => "500", "tax" => "200"})

      assert Decimal.equal?(socket.assigns.total, Decimal.new("1700"))
      assert is_nil(socket.assigns.amount_error)
    end

    test "a negative or oversized discount, or a negative tax, blocks checkout with a reason",
         %{socket: socket} do
      socket = event(socket, "set_amount_paid", %{"value" => "100000"})

      for {params, message} <- [
            {%{"discount" => "-500", "tax" => ""}, "Diskon tidak boleh negatif."},
            {%{"discount" => "2001", "tax" => ""}, "Diskon tidak boleh melebihi subtotal."},
            {%{"discount" => "", "tax" => "-1"}, "Pajak tidak boleh negatif."}
          ] do
        socket = event(socket, "payment", params)

        refute socket.assigns.can_checkout
        assert socket.assigns.amount_error == message
        assert html(socket) =~ message
      end
    end

    test "the server refuses an invalid discount even if the client sends checkout anyway",
         %{socket: socket, product: product} do
      socket =
        socket
        |> event("set_amount_paid", %{"value" => "100000"})
        |> event("payment", %{"discount" => "-500", "tax" => ""})
        |> event("checkout")

      assert flash(socket, :error) == "Diskon harus antara 0 dan subtotal."
      assert is_nil(socket.assigns.last_sale)
      assert stock_of(product) == 10
    end
  end

  describe "checkout" do
    setup do
      user = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      socket =
        CashierLive
        |> mount_live(user)
        |> event("scan", %{"q" => product.sku})
        |> event("scan", %{"q" => product.sku})
        |> event("payment", %{"discount" => "500", "tax" => ""})
        |> event("set_amount_paid", %{"value" => "2000"})

      %{user: user, product: product, socket: socket}
    end

    test "records the sale on the open shift, decrements stock and shows the receipt",
         %{socket: socket, user: user, product: product} do
      socket = event(socket, "checkout")

      sale = socket.assigns.last_sale
      assert flash(socket, :info) == "Sale #{sale.code} completed."
      assert pushed_events(socket) == [{"reset_amount_paid", %{}}]

      assert sale.user_id == user.id
      assert sale.shift_id == Shifts.current_shift(user).id
      assert Decimal.equal?(sale.total, Decimal.new("1500"))
      assert Decimal.equal?(sale.change_due, Decimal.new("500"))
      assert [%{quantity: 2}] = sale.items
      assert stock_of(product) == 8

      # The cart is cleared for the next customer, the receipt stays up.
      assert socket.assigns.cart == []
      assert socket.assigns.discount == ""
      assert html(socket) =~ sale.code

      socket = event(socket, "new_sale")
      assert is_nil(socket.assigns.last_sale)
    end

    test "is refused when the cash no longer covers the total", %{
      socket: socket,
      product: product
    } do
      socket = socket |> event("set_amount_paid", %{"value" => "1000"}) |> event("checkout")

      assert flash(socket, :error) == "Amount paid is less than the total."
      assert [_] = socket.assigns.cart
      assert stock_of(product) == 10
    end

    test "is refused when the stock ran out after the item was added",
         %{socket: socket, product: product} do
      {:ok, _} = Catalog.update_product(store_scope(), product, %{stock: 1})

      socket = event(socket, "checkout")

      assert flash(socket, :error) == "Insufficient stock for #{product.name}."
      assert is_nil(socket.assigns.last_sale)
      assert stock_of(product) == 1
    end

    test "is refused when the shift was closed from another tab, and the screen catches up",
         %{socket: socket, user: user, product: product} do
      {:ok, _} = Shifts.close_shift(socket.assigns.shift, "0")

      socket = event(socket, "checkout")

      assert flash(socket, :error) == "Shift belum dibuka atau sudah ditutup."
      assert is_nil(socket.assigns.shift)
      assert html(socket) =~ "Open shift"

      assert Sales.list_sales(store_scope(), limit: 1000) |> Enum.filter(&(&1.user_id == user.id)) ==
               []

      assert stock_of(product) == 10
    end
  end

  describe "cash movements and closing the shift" do
    setup do
      user = user_fixture()
      shift = shift_fixture(user, "100000")
      %{user: user, shift: shift, socket: mount_live(CashierLive, user)}
    end

    test "records a cash movement and lists it", %{socket: socket, shift: shift} do
      socket =
        socket
        |> event("toggle_movement")
        |> event("save_movement", %{
          "category" => "expense",
          "amount" => "5.000",
          "note" => "beli plastik",
          "supplier_id" => ""
        })

      assert flash(socket, :info) == "Gerakan kas dicatat."
      refute socket.assigns.movement_open
      assert [%{category: "expense", direction: "out"} = movement] = socket.assigns.movements
      assert Decimal.equal?(movement.amount, Decimal.new("5000"))
      assert Decimal.equal?(Shifts.expected_cash(shift), Decimal.new("95000"))
    end

    test "a consignment payment without a supplier is rejected", %{socket: socket} do
      socket =
        event(socket, "save_movement", %{
          "category" => "consignment_payment",
          "amount" => "1000",
          "note" => "",
          "supplier_id" => ""
        })

      assert flash(socket, :error) =~ "Gagal mencatat"
      assert socket.assigns.movements == []
    end

    test "closing shows the reconciliation and reports the variance",
         %{socket: socket, user: user, shift: shift} do
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, _} =
        Sales.create_sale(user, [%{product_id: product.id, quantity: 2}], %{amount_paid: "2000"})

      socket = event(socket, "toggle_close")
      assert Decimal.equal?(socket.assigns.summary.expected_cash, Decimal.new("102000"))
      assert html(socket) =~ "Expected cash"

      socket = event(socket, "close_shift", %{"counted_cash" => "101500", "note" => "kurang 500"})

      assert flash(socket, :info) =~ "Shift closed. Variance:"
      assert is_nil(socket.assigns.shift)
      assert is_nil(Shifts.current_shift(user))

      closed = Shifts.get_shift!(store_scope(), shift.id)
      assert closed.status == "closed"
      assert Decimal.equal?(closed.variance, Decimal.new("-500"))
      assert html(socket) =~ "Open shift"
    end

    test "closing a shift that was already closed elsewhere refreshes the screen",
         %{socket: socket, shift: shift} do
      {:ok, _} = Shifts.close_shift(shift, "100000")

      socket = event(socket, "close_shift", %{"counted_cash" => "1", "note" => ""})

      assert flash(socket, :error) == "Shift ini sudah ditutup."
      assert is_nil(socket.assigns.shift)

      assert Decimal.equal?(
               Shifts.get_shift!(store_scope(), shift.id).counted_cash,
               Decimal.new("100000")
             )
    end
  end

  describe "services when closing the shift" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      user = user_on_shift_fixture()
      %{user: user, socket: mount_live(CashierLive, user)}
    end

    test "the summary shows the service cash", %{socket: socket, user: user} do
      tx = service_fixture(user, service_product_fixture())
      {:ok, _} = Zahlungs.Services.mark_success(tx, user, nil)

      rendered = socket |> event("toggle_close") |> html()

      assert rendered =~ ~r{Layanan tunai</dt>\s*<dd>Rp 12\.000,00}
    end

    test "closing waits for services still processing", %{socket: socket, user: user} do
      service_fixture(user, service_product_fixture())

      socket =
        socket
        |> event("toggle_close")
        |> event("close_shift", %{"counted_cash" => "12000", "note" => ""})

      assert flash(socket, :error) == "Selesaikan dulu 1 layanan yang masih diproses."
      assert html(socket) =~ ~s(href="/services")
      assert Shifts.current_shift(user)
    end
  end
end
