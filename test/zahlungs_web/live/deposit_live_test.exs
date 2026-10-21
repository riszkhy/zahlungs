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

  describe "an api account" do
    test "the form asks for the provider's credentials and never shows them back" do
      admin = admin_fixture()
      name = "API #{System.unique_integer([:positive])}"

      socket =
        DepositLive.Index
        |> mount_live(admin, action: :new)
        |> event("validate_account", %{
          "account" => %{"name" => name, "mode" => "api", "provider" => "fake"}
        })

      assert html(socket) =~ "Secret callback"

      socket =
        event(socket, "save_account", %{
          "account" => %{
            "name" => name,
            "mode" => "api",
            "provider" => "fake",
            "credentials" => %{"secret" => "sangat-rahasia-123"}
          }
        })

      assert flash(socket, :info) =~ "disimpan"
      account = Enum.find(Deposits.list_accounts(), &(&1.name == name))
      assert Deposits.api?(account)

      rendered =
        DepositLive.Index
        |> mount_live(admin, action: :edit, params: %{"id" => "#{account.id}"})
        |> html()

      refute rendered =~ "sangat-rahasia-123"
      assert rendered =~ "tersimpan"
      assert rendered =~ "/api/ppob/callback/#{account.callback_token}"
    end

    test "the connection is tested and the provider's balance fills the reconciling" do
      admin = admin_fixture()
      account = api_account_fixture()

      {:ok, _} =
        Deposits.record_topup(admin, account, %{"amount" => "900000", "source" => "outside"})

      socket = admin |> show(account) |> event("test_connection", %{})
      assert flash(socket, :info) == "Koneksi ke penyedia berhasil."

      socket = event(socket, "fetch_balance", %{})
      rendered = html(socket)
      assert rendered =~ ~s(value="1000000")
      assert rendered =~ "Selisih Rp 100.000,00"
    end

    test "a manual account offers neither" do
      admin = admin_fixture()
      rendered = admin |> show(deposit_account_fixture()) |> html()

      refute rendered =~ "Tes koneksi"
      refute rendered =~ "Ambil saldo dari penyedia"
    end
  end

  describe "an SBI account" do
    test "asks for SBI's credentials and shows the callback URL without a token" do
      admin = admin_fixture()
      name = "SBI #{System.unique_integer([:positive])}"
      attrs = %{"name" => name, "mode" => "api", "provider" => "sbi"}

      socket =
        DepositLive.Index
        |> mount_live(admin, action: :new)
        |> event("validate_account", %{"account" => attrs})

      rendered = html(socket)
      assert rendered =~ "Member ID"
      assert rendered =~ "PIN"
      assert rendered =~ "Password"

      credentials = %{"member_id" => "MM77", "pin" => "4321", "password" => "kata-sandi-sbi"}
      event(socket, "save_account", %{"account" => Map.put(attrs, "credentials", credentials)})
      account = Enum.find(Deposits.list_accounts(), &(&1.name == name))

      rendered =
        DepositLive.Index
        |> mount_live(admin, action: :edit, params: %{"id" => "#{account.id}"})
        |> html()

      refute rendered =~ "kata-sandi-sbi"
      refute rendered =~ "4321"
      assert rendered =~ "/api/ppob/callback<"
      refute rendered =~ account.callback_token
    end
  end

  describe "services in review" do
    setup do
      admin = admin_fixture()
      account = api_account_fixture()
      Zahlungs.StoresFixtures.default_store() |> assign_account(account)
      cashier = Zahlungs.ShiftsFixtures.user_on_shift_fixture()
      pulsa = service_product_fixture(%{provider_code: "TSEL10"})

      {:ok, tx} =
        Zahlungs.Services.record(cashier, pulsa.id, %{
          "customer_ref" => "081234567899",
          "amount_paid" => "12000"
        })

      {:ok, _} =
        Zahlungs.Services.apply_result(tx.id, %{
          status: :success,
          token_sn: "SN",
          provider_ref: "R"
        })

      {:ok, _} =
        Zahlungs.Services.apply_result(tx.id, %{status: :refunded, message: "Refund transaksi"})

      %{admin: admin, account: account, tx: tx}
    end

    defp status_of(tx), do: Zahlungs.Repo.get!(Zahlungs.Services.Transaction, tx.id)

    test "are listed on the account with what the provider said", %{
      admin: admin,
      account: account
    } do
      rendered = admin |> show(account) |> html()
      assert rendered =~ "Perlu ditinjau"
      assert rendered =~ "Refund transaksi"
      assert rendered =~ "Batalkan dan kembalikan uang"
      assert rendered =~ "Tetap berhasil"
    end

    test "refund fails the service", %{admin: admin, account: account, tx: tx} do
      socket =
        admin
        |> show(account)
        |> event("resolve_review", %{"transaction_id" => tx.id, "decision" => "refund"})

      assert flash(socket, :info) == "Transaksi dibatalkan dan masuk Perlu dikembalikan."
      assert status_of(tx).status == "failed"
      refute html(socket) =~ "Batalkan dan kembalikan uang"
    end

    test "keep leaves it successful", %{admin: admin, account: account, tx: tx} do
      socket =
        admin
        |> show(account)
        |> event("resolve_review", %{"transaction_id" => "#{tx.id}", "decision" => "keep"})

      assert flash(socket, :info) == "Transaksi tetap berhasil."
      assert %{status: "success", review_reason: nil} = status_of(tx)
    end

    test "another account's service is not found", %{admin: admin, tx: tx} do
      other = api_account_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        admin
        |> show(other)
        |> event("resolve_review", %{"transaction_id" => tx.id, "decision" => "keep"})
      end
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

    test "a top-up typed with a decimal comma keeps its size", %{admin: admin, account: account} do
      admin
      |> show(account)
      |> event("topup", %{
        "topup" => %{"amount" => "250.000,00", "source" => "outside", "note" => ""}
      })

      assert Decimal.equal?(Deposits.estimated_balance(account), Decimal.new("250000"))
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
