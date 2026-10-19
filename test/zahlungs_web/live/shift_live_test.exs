defmodule ZahlungsWeb.ShiftLiveTest do
  @moduledoc """
  Shift history tests: access and render via `get/2`, and who may see which
  shift by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Sales, Shifts}
  alias ZahlungsWeb.ShiftLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  describe "/shifts" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert redirected_to(get(conn, "/shifts")) == "/users/log_in"
    end

    test "lists the cashier's own shifts and shows their name", %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Zahlungs.Accounts.update_user_name(user, %{name: "Budi Kasir"})
      user = Zahlungs.Accounts.get_user!(user.id)
      {:ok, shift} = Shifts.open_shift(scope(user), 100_000)

      conn = conn |> log_in_user(user) |> get("/shifts")
      response = html_response(conn, 200)
      assert response =~ "Shifts"
      assert response =~ "Budi Kasir"
      assert response =~ Integer.to_string(shift.id)
    end
  end

  describe "shift list" do
    test "a cashier sees only their own shifts, an admin sees everyone's" do
      cashier = user_fixture()
      mine = shift_fixture(cashier)
      theirs = shift_fixture(user_fixture())

      as_cashier = mount_live(ShiftLive.Index, cashier)
      assert Enum.map(as_cashier.assigns.shifts, & &1.id) == [mine.id]

      # The admin list is capped at the 50 most recent, which these two are.
      as_admin = mount_live(ShiftLive.Index, admin_fixture())
      admin_ids = Enum.map(as_admin.assigns.shifts, & &1.id)
      assert mine.id in admin_ids
      assert theirs.id in admin_ids
    end
  end

  describe "narrow screens" do
    test "each shift is also a card that opens its detail" do
      cashier = user_fixture()
      shift = shift_fixture(cashier, "100000")

      rendered = ShiftLive.Index |> mount_live(cashier) |> html()

      [_, card] = Regex.run(~r{<a[^>]*id="shift-card-#{shift.id}"[^>]*>(.*?)</a>}s, rendered)

      assert rendered =~ ~s(href="/shifts/#{shift.id}")
      assert card =~ "open"
    end
  end

  describe "shift detail" do
    setup do
      cashier = user_fixture()
      shift = shift_fixture(cashier, "100000")
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      {:ok, sale} =
        Sales.create_sale(cashier, [%{product_id: product.id, quantity: 2}], %{
          amount_paid: "2000"
        })

      {:ok, _} = Shifts.add_cash_movement(shift, %{"category" => "expense", "amount" => "500"})

      %{cashier: cashier, shift: shift, sale: sale}
    end

    test "shows the owner the reconciliation, sales and cash movements",
         %{cashier: cashier, shift: shift, sale: sale} do
      socket =
        mount_live(ShiftLive.Index, cashier, action: :show, params: %{"id" => "#{shift.id}"})

      assert socket.assigns.shift.id == shift.id
      assert Enum.map(socket.assigns.sales, & &1.id) == [sale.id]
      assert [%{category: "expense"}] = socket.assigns.movements
      assert Decimal.equal?(socket.assigns.summary.expected_cash, Decimal.new("101500"))
      assert html(socket) =~ sale.code
    end

    test "an admin can open any cashier's shift", %{shift: shift} do
      socket =
        mount_live(ShiftLive.Index, admin_fixture(),
          action: :show,
          params: %{"id" => "#{shift.id}"}
        )

      assert socket.assigns.shift.id == shift.id
      assert is_nil(flash(socket, :error))
    end

    test "another cashier is sent back to the list without seeing it", %{shift: shift} do
      socket =
        mount_live(ShiftLive.Index, user_fixture(),
          action: :show,
          params: %{"id" => "#{shift.id}"}
        )

      assert flash(socket, :error) == "You can only view your own shifts."
      assert live_redirect(socket) == "/shifts"
      assert is_nil(socket.assigns[:summary])
    end
  end

  describe "services in the shift detail" do
    test "the summary lists service cash, so it adds up to the expected cash" do
      assign_account(default_store(), deposit_account_fixture())
      cashier = user_on_shift_fixture()
      shift = Shifts.current_shift(cashier)
      tx = service_fixture(cashier, service_product_fixture())
      {:ok, _} = Zahlungs.Services.mark_success(tx, cashier, nil)

      rendered =
        ShiftLive.Index
        |> mount_live(cashier, action: :show, params: %{"id" => "#{shift.id}"})
        |> html()

      assert rendered =~ ~r{Layanan tunai</dt>\s*<dd>Rp 12\.000,00}
    end
  end
end
