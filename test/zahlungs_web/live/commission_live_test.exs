defmodule ZahlungsWeb.CommissionLiveTest do
  @moduledoc """
  A cashier's own commission ("Komisi saya") and the shift's commission on
  the Layanan screen.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Services
  alias ZahlungsWeb.{CommissionLive, ServiceLive}

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp success(user, product) do
    {:ok, tx} = Services.mark_success(service_fixture(user, product), user, nil)
    tx
  end

  # Pulsa at 10%: each success is 185 on a margin of 1.850.
  setup do
    assign_account(default_store(), deposit_account_fixture())
    admin = admin_fixture()
    {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10"})

    %{admin: admin, pulsa: service_product_fixture()}
  end

  describe "/commissions" do
    test "is a cashier's; an admin goes to the report", %{conn: conn, admin: admin} do
      assert conn |> log_in_user(user_fixture()) |> get("/commissions") |> html_response(200) =~
               "Komisi saya"

      assert build_conn() |> log_in_user(admin) |> get("/commissions") |> redirected_to() ==
               "/reports/commissions"
    end

    test "shows only the cashier's own", %{pulsa: pulsa} do
      a = user_on_shift_fixture()
      b = user_on_shift_fixture()
      mine = success(a, pulsa)
      theirs = success(b, pulsa)

      rendered = CommissionLive |> mount_live(a) |> html()

      assert rendered =~ mine.code
      refute rendered =~ theirs.code
      assert rendered =~ "Rp 185,00"
    end

    test "another period, or one that isn't a date", %{pulsa: pulsa} do
      a = user_on_shift_fixture()
      mine = success(a, pulsa)
      socket = mount_live(CommissionLive, a)

      refute socket |> event("filter", %{"from" => "2001-01-01", "to" => "2001-01-31"}) |> html() =~
               mine.code

      assert socket |> event("filter", %{"from" => "", "to" => "x"}) |> html() =~
               "Pilih rentang tanggal yang valid."
    end

    test "is in a cashier's menu, not an admin's", %{conn: conn, admin: admin} do
      assert conn |> log_in_user(user_fixture()) |> get("/services") |> html_response(200) =~
               ~s(href="/commissions")

      refute build_conn() |> log_in_user(admin) |> get("/services") |> html_response(200) =~
               ~s(href="/commissions")
    end
  end

  describe "the Layanan screen" do
    test "shows a cashier the shift's commission, kept up to date", %{pulsa: pulsa} do
      cashier = user_on_shift_fixture()
      socket = mount_live(ServiceLive.Index, cashier)
      assert html(socket) =~ "Komisi shift ini"

      tx = success(cashier, pulsa)
      rendered = socket |> info({:service_changed, tx.id}) |> html()
      assert rendered =~ "Komisi shift ini"
      assert rendered =~ "Rp 185,00"
    end

    test "an admin earns none, so sees none" do
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")
      refute ServiceLive.Index |> mount_live(admin) |> html() =~ "Komisi shift ini"
    end
  end
end
