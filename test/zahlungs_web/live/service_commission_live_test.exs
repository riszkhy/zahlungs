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

  defp percent(value), do: %{"kind" => "percent", "value" => value}
  defp rupiah(value), do: %{"kind" => "amount", "value" => value}

  defp rate(category), do: Enum.find(Services.commission_rates(), &(&1.category == category))

  test "asks a kind and a value for every category" do
    rendered = ServiceCommissionLive |> mount_live(admin_fixture()) |> html()

    for {category, label} <- Services.categories() do
      assert rendered =~ ~s(name="rates[#{category}][kind]")
      assert rendered =~ ~s(name="rates[#{category}][value]")
      assert rendered =~ label
    end

    assert rendered =~ "Persen"
    assert rendered =~ "Rupiah"
    assert rendered =~ "Perubahan berlaku untuk transaksi berikutnya"
    assert rendered =~ "tetap dibayar penuh"
  end

  test "saves percents and amounts, and shows them again" do
    socket =
      ServiceCommissionLive
      |> mount_live(admin_fixture())
      |> event("save", %{"rates" => %{"pulsa" => rupiah("500"), "tagihan" => percent("12.5")}})

    assert flash(socket, :info) == "Komisi disimpan."
    assert %{kind: "amount"} = rate("pulsa")
    assert Decimal.equal?(rate("pulsa").amount, 500)
    assert Decimal.equal?(rate("tagihan").percent, "12.5")

    reopened = ServiceCommissionLive |> mount_live(admin_fixture()) |> html()
    assert reopened =~ ~s(value="500")
    assert reopened =~ ~s(value="12.5")
    assert reopened =~ ~r/<option[^>]*value="amount"[^>]*selected/
  end

  test "shows what is wrong and saves nothing, keeping what was typed" do
    socket =
      ServiceCommissionLive
      |> mount_live(admin_fixture())
      |> event("save", %{"rates" => %{"pulsa" => percent("101"), "tagihan" => percent("5")}})

    rendered = html(socket)
    assert rendered =~ "harus antara 0 dan 100"
    assert rendered =~ ~s(value="101")
    assert Decimal.equal?(Services.commission_percent("tagihan"), 0)

    rendered =
      socket
      |> event("save", %{"rates" => %{"pulsa" => rupiah("1.000"), "tagihan" => percent("5")}})
      |> html()

    assert rendered =~ "tanpa titik"
    assert rendered =~ ~s(value="1.000")
    assert rendered =~ ~r/<option[^>]*value="amount"[^>]*selected/
    assert Decimal.equal?(Services.commission_percent("tagihan"), 0)
  end

  test "the service products page links to it" do
    rendered = ZahlungsWeb.ServiceProductLive.Index |> mount_live(admin_fixture()) |> html()
    assert rendered =~ ~s(href="/admin/services/commission")
  end
end
