defmodule ZahlungsWeb.ReportCommissionsLiveTest do
  @moduledoc """
  The admin's cashier commission report: access via `get/2`, the filter and
  the per-cashier details by driving the LiveView's callbacks.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Services
  alias ZahlungsWeb.ReportLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  # Pulsa at 10%: one success by the cashier, 185 on a margin of 1.850.
  setup do
    assign_account(default_store(), deposit_account_fixture())
    admin = admin_fixture()
    {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10"})
    cashier = user_on_shift_fixture(%{name: "Kasir Komisi"})
    tx = service_fixture(cashier, service_product_fixture())
    {:ok, tx} = Services.mark_success(tx, cashier, nil)

    %{admin: admin, cashier: cashier, tx: tx}
  end

  test "is for admins only", %{conn: conn, admin: admin} do
    assert conn |> log_in_user(user_fixture()) |> get("/reports/commissions") |> redirected_to() ==
             "/"

    response =
      build_conn() |> log_in_user(admin) |> get("/reports/commissions") |> html_response(200)

    assert response =~ "Komisi kasir"
  end

  test "this month's commission per cashier", %{admin: admin} do
    rendered = ReportLive.Commissions |> mount_live(admin) |> html()

    assert rendered =~ "Kasir Komisi"
    assert rendered =~ "Rp 185,00"
    assert rendered =~ "Rp 1.850,00"
  end

  test "another period, or one that isn't a date", %{admin: admin} do
    socket = mount_live(ReportLive.Commissions, admin)

    rendered =
      socket |> event("filter", %{"from" => "2001-01-01", "to" => "2001-01-31"}) |> html()

    refute rendered =~ "Kasir Komisi"
    assert rendered =~ "Belum ada komisi"

    assert socket |> event("filter", %{"from" => "x", "to" => ""}) |> html() =~
             "Pilih rentang tanggal yang valid."
  end

  test "a cashier's services, by number or by text", %{admin: admin, cashier: cashier, tx: tx} do
    socket = mount_live(ReportLive.Commissions, admin)
    refute html(socket) =~ tx.code

    assert socket |> event("select_cashier", %{"id" => cashier.id}) |> html() =~ tx.code
    assert socket |> event("select_cashier", %{"id" => "#{cashier.id}"}) |> html() =~ tx.code
  end

  test "the details say each service's rule", %{admin: admin, cashier: cashier, tx: tx} do
    {:ok, _} =
      Services.save_commission_rates(admin, %{
        "pulsa" => %{"kind" => "amount", "value" => "500"}
      })

    {:ok, by_amount} =
      Services.mark_success(service_fixture(cashier, service_product_fixture()), cashier, nil)

    rendered =
      ReportLive.Commissions
      |> mount_live(admin)
      |> event("select_cashier", %{"id" => cashier.id})
      |> html()

    assert rendered =~ "Aturan"
    assert rendered =~ tx.code
    assert rendered =~ "10%"
    assert rendered =~ by_amount.code
    assert rendered =~ "Rp 500"
    # 185 + 500
    assert rendered =~ "Rp 685,00"
  end

  test "is in the admin menu", %{conn: conn, admin: admin} do
    response = conn |> log_in_user(admin) |> get("/reports/services") |> html_response(200)

    assert response =~ ~s(href="/reports/commissions")
    assert response =~ "Komisi kasir"
    assert response =~ "Margin bersih"
    # Margin 1.850, commission 185.
    assert response =~ "Rp 1.665,00"
  end
end
