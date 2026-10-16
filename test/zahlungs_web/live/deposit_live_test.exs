defmodule ZahlungsWeb.DepositLiveTest do
  @moduledoc """
  The admin page for deposit accounts: access via `get/2`, and accounts,
  top-ups and reconciling by driving the LiveView's callbacks.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Deposits
  alias ZahlungsWeb.DepositLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp show(admin, account),
    do: mount_live(DepositLive.Index, admin, action: :show, params: %{"id" => "#{account.id}"})

  describe "/admin/deposits" do
    test "is for admins only", %{conn: conn} do
      assert conn |> log_in_user(user_fixture()) |> get("/admin/deposits") |> redirected_to() ==
               "/"

      assert build_conn()
             |> log_in_user(admin_fixture())
             |> get("/admin/deposits")
             |> html_response(200) =~ "Deposit"
    end
  end

  describe "accounts" do
    test "are listed with their estimated balance" do
      admin = admin_fixture()
      account = deposit_account_fixture()

      {:ok, _} =
        Deposits.record_topup(admin, account, %{"amount" => "500000", "source" => "outside"})

      rendered = DepositLive.Index |> mount_live(admin) |> html()

      assert rendered =~ account.name
      assert rendered =~ "Rp 500.000,00"
    end

    test "a new account is saved" do
      name = "Konter #{System.unique_integer([:positive])}"

      socket =
        DepositLive.Index
        |> mount_live(admin_fixture(), action: :new)
        |> event("save_account", %{"account" => %{"name" => name}})

      assert flash(socket, :info) =~ "disimpan"
      assert live_redirect(socket) == "/admin/deposits"
      assert Enum.any?(Deposits.list_accounts(), &(&1.name == name))
    end
  end

  describe "an account" do
    setup do
      %{admin: admin_fixture(), account: deposit_account_fixture()}
    end

    test "a top-up from outside the drawer raises the estimate", %{admin: admin, account: account} do
      socket =
        admin
        |> show(account)
        |> event("topup", %{
          "topup" => %{"amount" => "250.000", "source" => "outside", "note" => "transfer BCA"}
        })

      assert flash(socket, :info) =~ "Isi ulang dicatat"
      assert Decimal.equal?(Deposits.estimated_balance(account), Decimal.new("250000"))
      assert html(socket) =~ "transfer BCA"
    end

    test "the drawer is offered only to an admin with an open shift", %{
      admin: admin,
      account: account
    } do
      refute admin |> show(account) |> html() =~ "Kas laci shift saya"

      shift_fixture(admin, "300000")
      assert admin |> show(account) |> html() =~ "Kas laci shift saya"
    end

    test "reconciling previews the difference, then records it", %{admin: admin, account: account} do
      {:ok, _} =
        Deposits.record_topup(admin, account, %{"amount" => "500000", "source" => "outside"})

      socket =
        event(show(admin, account), "reconcile_preview", %{
          "actual_balance" => "430.000",
          "note" => ""
        })

      assert html(socket) =~ "-Rp 70.000,00"

      socket = event(socket, "reconcile", %{"actual_balance" => "430.000", "note" => "cek sore"})
      assert flash(socket, :info) =~ "koreksi"
      assert html(socket) =~ "Pencocokan: saldo aplikasi Rp 430.000"

      socket = event(socket, "reconcile_preview", %{"actual_balance" => "430.000", "note" => ""})
      assert html(socket) =~ "Cocok"

      socket = event(socket, "reconcile", %{"actual_balance" => "430.000", "note" => ""})
      assert flash(socket, :info) =~ "Cocok"
      assert length(Deposits.list_entries(account)) == 2
    end
  end
end
