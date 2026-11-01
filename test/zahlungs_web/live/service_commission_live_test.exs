defmodule ZahlungsWeb.ServiceCommissionLiveTest do
  @moduledoc """
  The admin page for the cashier commission percent per service category:
  access via `get/2`, the form by driving the LiveView's callbacks.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Services
  alias ZahlungsWeb.ServiceCommissionLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  test "is for admins only", %{conn: conn} do
    assert conn
           |> log_in_user(user_fixture())
           |> get("/admin/services/commission")
           |> redirected_to() ==
             "/"

    assert build_conn()
           |> log_in_user(admin_fixture())
           |> get("/admin/services/commission")
           |> html_response(200) =~ "Komisi kasir"
  end

  test "asks a percent for every category" do
    rendered = ServiceCommissionLive |> mount_live(admin_fixture()) |> html()

    for {category, label} <- Services.categories() do
      assert rendered =~ ~s(name="rates[#{category}]")
      assert rendered =~ label
    end

    assert rendered =~ "Perubahan berlaku untuk transaksi berikutnya"
  end

  test "saves the percents" do
    socket =
      ServiceCommissionLive
      |> mount_live(admin_fixture())
      |> event("save", %{"rates" => %{"pulsa" => "10", "tagihan" => "12.5"}})

    assert flash(socket, :info) == "Persen komisi disimpan."
    assert Decimal.equal?(Services.commission_percent("pulsa"), 10)
    assert Decimal.equal?(Services.commission_percent("tagihan"), "12.5")
  end

  test "shows what is wrong and saves nothing" do
    socket =
      ServiceCommissionLive
      |> mount_live(admin_fixture())
      |> event("save", %{"rates" => %{"pulsa" => "101", "tagihan" => "5"}})

    rendered = html(socket)
    assert rendered =~ "harus antara 0 dan 100"
    assert rendered =~ ~s(value="101")
    assert Decimal.equal?(Services.commission_percent("tagihan"), 0)
  end

  test "the service products page links to it" do
    rendered = ZahlungsWeb.ServiceProductLive.Index |> mount_live(admin_fixture()) |> html()
    assert rendered =~ ~s(href="/admin/services/commission")
  end
end
