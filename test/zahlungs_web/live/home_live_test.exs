defmodule ZahlungsWeb.HomeLiveTest do
  @moduledoc """
  Tests the home dashboard via the disconnected render (`get/2`), and the small
  pure helpers behind its greeting and shift card.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Ecto.Query, only: [from: 2]

  alias Zahlungs.Sales
  alias ZahlungsWeb.HomeLive

  defp admin_fixture(attrs \\ %{}) do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(attrs), "admin")
    admin
  end

  # The shift card's markup, so a figure is looked for in the card and not
  # anywhere on the page.
  defp shift_card(response) do
    case Regex.run(~r{<section id="shift-card".*?</section>}s, response) do
      [card] -> card
      nil -> nil
    end
  end

  # The opening tag of the summary card with this id: a link or a plain div.
  defp card_tag(response, id) do
    [tag] = Regex.run(~r{<(?:a|div)[^>]*id="#{id}"[^>]*>}, response)
    tag
  end

  defp sell(user, product, quantity) do
    {:ok, sale} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: quantity}], %{
        amount_paid: "100000"
      })

    sale
  end

  describe "/home" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/home")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "greets the user by name and shows the summary cards", %{conn: conn} do
      user = user_fixture(%{name: "Budi Santoso"})
      response = conn |> log_in_user(user) |> get("/home") |> html_response(200)

      assert response =~ "Budi Santoso"
      assert response =~ "Produk aktif"
      assert response =~ "Stok menipis"
      assert response =~ "Kategori"
      assert response =~ "Penjualan toko hari ini"

      # The screen is in Indonesian throughout.
      refute response =~ "Active Products"
      refute response =~ "Low Stock"
      refute response =~ "Quick actions"
      refute response =~ "transaction(s)"
    end

    test "falls back to the email when the user has no name", %{conn: conn} do
      user = user_fixture()
      response = conn |> log_in_user(user) |> get("/home") |> html_response(200)

      assert response =~ user.email
    end

    test "the summary cards lead to the screens behind them", %{conn: conn} do
      cashier = conn |> log_in_user(user_fixture()) |> get("/home") |> html_response(200)

      assert card_tag(cashier, "card-products") =~ ~s(href="/catalog")
      assert card_tag(cashier, "card-sales") =~ ~s(href="/sales")

      # Reports and category management are for admins: plain cards.
      for id <- ["card-low-stock", "card-categories"] do
        tag = card_tag(cashier, id)
        assert String.starts_with?(tag, "<div")
        refute tag =~ "href"
      end

      admin = build_conn() |> log_in_user(admin_fixture()) |> get("/home") |> html_response(200)

      assert card_tag(admin, "card-products") =~ ~s(href="/products")
      assert card_tag(admin, "card-low-stock") =~ ~s(href="/reports/stock")
      assert card_tag(admin, "card-categories") =~ ~s(href="/categories")
      assert card_tag(admin, "card-sales") =~ ~s(href="/sales")
    end

    test "shows admin shortcuts only for admins", %{conn: conn} do
      admin_resp = conn |> log_in_user(admin_fixture()) |> get("/home") |> html_response(200)
      assert admin_resp =~ "Kelola produk"
      assert admin_resp =~ "Kelola kategori"

      cashier_resp =
        build_conn() |> log_in_user(user_fixture()) |> get("/home") |> html_response(200)

      refute cashier_resp =~ "Kelola produk"
      refute cashier_resp =~ "Kelola kategori"
    end
  end

  describe "shift card" do
    test "without a shift it says so and sends the cashier to open one", %{conn: conn} do
      response = conn |> log_in_user(user_fixture()) |> get("/home") |> html_response(200)
      card = shift_card(response)

      assert card =~ "Belum ada shift"
      assert card =~ "Buka shift"
      assert card =~ ~s(href="/cashier")
      refute card =~ "Lanjut berjualan"
    end

    test "with an open shift it shows the cashier's own sales in that shift", %{conn: conn} do
      cashier = user_on_shift_fixture()
      colleague = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 50)

      sell(cashier, product, 3)
      sell(colleague, product, 5)

      response = conn |> log_in_user(cashier) |> get("/home") |> html_response(200)
      card = shift_card(response)

      assert card =~ "Shift terbuka"
      assert card =~ "Lanjut berjualan"
      assert card =~ ~s(href="/cashier")
      assert card =~ "Penjualan Anda"
      assert card =~ "Rp 3.000,00"
      assert card =~ "1 transaksi"
      refute card =~ "Belum ada shift"

      # The colleague's sale is in the store's total, not in "Penjualan Anda".
      refute card =~ "Rp 8.000,00"
      assert response =~ "Rp 8.000,00"
    end

    test "a shift left open for days says so, with the date it opened", %{conn: conn} do
      cashier = user_on_shift_fixture()
      shift = Zahlungs.Shifts.current_shift(cashier)
      three_days_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -3 * 86_400 - 3600)

      Zahlungs.Repo.update_all(
        from(s in Zahlungs.Shifts.Shift, where: s.id == ^shift.id),
        set: [opened_at: three_days_ago]
      )

      card = conn |> log_in_user(cashier) |> get("/home") |> html_response(200) |> shift_card()

      assert card =~ "3 hari 1 jam"
      assert card =~ ~r/sejak \d{1,2} [A-Z][a-z]{2} \d\d:\d\d/
    end

    test "links to the shift's own page", %{conn: conn} do
      cashier = user_on_shift_fixture()
      shift = Zahlungs.Shifts.current_shift(cashier)

      response = conn |> log_in_user(cashier) |> get("/home") |> html_response(200)

      assert shift_card(response) =~ ~s(href="/shifts/#{shift.id}")
    end

    test "an admin looking at all stores is asked to pick one", %{conn: conn} do
      conn =
        conn
        |> log_in_user(admin_fixture())
        |> Plug.Test.init_test_session(%{store_id: "all"})

      response = conn |> get("/home") |> html_response(200)
      card = shift_card(response)

      assert card =~ "Pilih toko"
      refute card =~ "Buka shift"
    end
  end

  describe "greeting/1" do
    test "follows the shop's clock" do
      assert HomeLive.greeting(5) == "Selamat pagi"
      assert HomeLive.greeting(10) == "Selamat pagi"
      assert HomeLive.greeting(11) == "Selamat siang"
      assert HomeLive.greeting(14) == "Selamat siang"
      assert HomeLive.greeting(15) == "Selamat sore"
      assert HomeLive.greeting(17) == "Selamat sore"
      assert HomeLive.greeting(18) == "Selamat malam"
      assert HomeLive.greeting(0) == "Selamat malam"
      assert HomeLive.greeting(4) == "Selamat malam"
    end
  end

  describe "duration_label/1" do
    test "says how long a shift has been open" do
      assert HomeLive.duration_label(0) == "baru saja"
      assert HomeLive.duration_label(59) == "baru saja"
      assert HomeLive.duration_label(60) == "1 mnt"
      assert HomeLive.duration_label(45 * 60) == "45 mnt"
      assert HomeLive.duration_label(60 * 60) == "1 jam"
      assert HomeLive.duration_label(3 * 3600 + 40 * 60) == "3 jam 40 mnt"
      assert HomeLive.duration_label(24 * 3600) == "1 hari"
      assert HomeLive.duration_label(26 * 3600 + 15 * 60) == "1 hari 2 jam"
      assert HomeLive.duration_label(105 * 86_400 + 3 * 3600) == "105 hari 3 jam"
      assert HomeLive.duration_label(-30) == "baru saja"
    end
  end
end
