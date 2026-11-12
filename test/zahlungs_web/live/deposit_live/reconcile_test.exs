defmodule ZahlungsWeb.DepositLive.ReconcileTest do
  @moduledoc """
  The reconciliation page of a deposit account: access via `get/2`, the rest
  by driving the LiveView's callbacks. SBI is `Sbi.StubClient`; every value is
  made up.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.{AccountsFixtures, ServicesFixtures, ShiftsFixtures, StoresFixtures}
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{LocalTime, Repo}
  alias Zahlungs.Services.Provider.Sbi.StubClient
  alias Zahlungs.Services.Transaction
  alias ZahlungsWeb.DepositLive

  setup do
    default_org()

    account =
      deposit_account_fixture(%{
        mode: "api",
        provider: "sbi",
        credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => "pw"}
      })

    store = assign_account(default_store(), account)
    cashier = user_on_shift_fixture()
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

    %{
      account: account,
      store: store,
      cashier: cashier,
      admin: admin,
      product: service_product_fixture(),
      shift: Zahlungs.Shifts.current_shift(cashier)
    }
  end

  defp yesterday, do: Date.add(LocalTime.today(), -1)

  # An api service of the account made yesterday at 10.00 (default zone).
  defp service!(ctx, attrs) do
    n = System.unique_integer([:positive])
    {from, _to} = LocalTime.day_range(yesterday(), yesterday())
    at = NaiveDateTime.add(from, 10 * 3600)

    Repo.insert!(
      struct(
        %Transaction{
          code: "LYT-#{n}",
          category: "pulsa",
          product_name: ctx.product.name,
          customer_ref: "089900001111",
          price: Decimal.new(12_000),
          cost: Decimal.new(5150),
          amount_paid: Decimal.new(12_000),
          status: "processing",
          channel: "api",
          ref_id: "Z#{n}",
          sent_at: at,
          inserted_at: at,
          updated_at: at,
          store_id: ctx.store.id,
          shift_id: ctx.shift.id,
          user_id: ctx.cashier.id,
          service_product_id: ctx.product.id,
          deposit_account_id: ctx.account.id
        },
        attrs
      )
    )
  end

  defp sbi_row(ref, status) do
    %{
      "ref_1" => ref,
      "status" => status,
      "total_payment" => "5150",
      "msg" => "TRX T5.089900001111 SUKSES, HRG:5150 SN:1 REFID:#{ref}."
    }
  end

  defp page(rows),
    do: {:ok, 200, %{"data" => %{"data" => rows, "meta" => %{"last_page" => 1}}}}

  defp open(ctx, account \\ nil),
    do:
      mount_live(DepositLive.Reconcile, ctx.admin,
        params: %{"id" => "#{(account || ctx.account).id}"}
      )

  defp reconcile(socket, date \\ nil),
    do: event(socket, "reconcile", %{"date" => date || Date.to_iso8601(yesterday())})

  defp history_requests,
    do: for({"history", _, _} = request <- StubClient.requests(), do: request)

  describe "access" do
    test "is for admins only", ctx do
      path = "/admin/deposits/#{ctx.account.id}/reconcile"

      assert build_conn() |> get(path) |> redirected_to() == "/users/log_in"
      assert build_conn() |> log_in_user(ctx.cashier) |> get(path) |> redirected_to() == "/"

      assert build_conn() |> log_in_user(ctx.admin) |> get(path) |> html_response(200) =~
               "Rekonsiliasi"
    end
  end

  describe "the link on the deposit account's page" do
    test "is there for an api account only", ctx do
      show = fn account ->
        DepositLive.Index
        |> mount_live(ctx.admin, action: :show, params: %{"id" => "#{account.id}"})
        |> html()
      end

      assert show.(ctx.account) =~ "Rekonsiliasi per tanggal"
      assert show.(ctx.account) =~ "/admin/deposits/#{ctx.account.id}/reconcile"
      refute show.(deposit_account_fixture()) =~ "Rekonsiliasi per tanggal"
    end
  end

  describe "the page" do
    test "opening the page doesn't ask SBI", ctx do
      html = ctx |> open() |> html()

      assert html =~ ctx.account.name
      assert html =~ "Cocokkan"
      refute html =~ "Lihat yang cocok"
      assert StubClient.requests() == []
    end

    test "reconciling shows the summary and the rows that don't match first", ctx do
      follow = service!(ctx, status: "processing")
      matched = service!(ctx, status: "success")
      StubClient.expect("history", page([sbi_row(follow.ref_id, 1), sbi_row(matched.ref_id, 1)]))

      socket = ctx |> open() |> reconcile()
      html = html(socket)

      assert html =~ follow.code
      assert html =~ "Ikuti SBI"
      assert html =~ "Lihat yang cocok (1)"
      refute html =~ matched.code

      html = socket |> event("toggle_matched") |> html()
      assert html =~ matched.code
      assert html =~ "Sembunyikan yang cocok"
    end

    test "an empty day", ctx do
      StubClient.expect("history", page([]))

      assert ctx |> open() |> reconcile() |> html() =~ "Tidak ada transaksi pada tanggal ini."
    end

    test "SBI not answering shows a message and no rows", ctx do
      service!(ctx, status: "processing")
      StubClient.expect("history", {:error, :timeout})

      html = ctx |> open() |> reconcile() |> html()
      assert html =~ "Riwayat SBI belum bisa diambil, coba lagi."
      refute html =~ "Lihat yang cocok"
    end

    test "a manual account", ctx do
      html = ctx |> open(deposit_account_fixture()) |> reconcile() |> html()

      assert html =~ "Rekonsiliasi hanya untuk akun api SBI."
      assert StubClient.requests() == []
    end

    test "a date that isn't one or hasn't come", ctx do
      tomorrow = Date.to_iso8601(Date.add(LocalTime.today(), 1))

      for date <- [tomorrow, "abc"] do
        assert ctx |> open() |> reconcile(date) |> html() =~
                 "Tanggal tidak valid atau belum terjadi."
      end

      assert StubClient.requests() == []
    end
  end

  describe "the buttons" do
    defp followed(ctx, index) do
      service = service!(ctx, status: "processing")
      StubClient.expect("history", page([sbi_row(service.ref_id, 1)]))
      StubClient.expect("status", {:ok, 200, %{"data" => sbi_row(service.ref_id, 1)}})

      socket = ctx |> open() |> reconcile()
      assert html(socket) =~ "Ikuti SBI"
      socket = event(socket, "recheck", %{"index" => index})

      assert flash(socket, :info) == "Sudah cocok dengan SBI."
      assert html(socket) =~ "Lihat yang cocok (1)"
      refute html(socket) =~ ">Ikuti SBI<"
      assert length(history_requests()) == 1
    end

    test("a button updates its row only (index as a number)", ctx, do: followed(ctx, 0))
    test("a button updates its row only (index as text)", ctx, do: followed(ctx, "0"))

    test "an index that isn't a row changes nothing", ctx do
      service = service!(ctx, status: "processing")
      StubClient.expect("history", page([sbi_row(service.ref_id, 1)]))
      socket = ctx |> open() |> reconcile()

      for index <- ["abc", 99, -1] do
        assert socket |> event("recheck", %{"index" => index}) |> html() == html(socket)
      end

      assert for({"status", _, _} <- StubClient.requests(), do: :status) == []
    end
  end

  describe "correcting from the report" do
    defp conflict(ctx, attrs \\ []) do
      service = service!(ctx, Keyword.merge([status: "success"], attrs))
      StubClient.expect("history", page([sbi_row(service.ref_id, 11)]))
      {service, ctx |> open() |> reconcile()}
    end

    test "a conflict corrected to match SBI", ctx do
      {service, socket} = conflict(ctx)
      assert html(socket) =~ "Koreksi status"

      socket =
        socket
        |> event("review_correction", %{"index" => 0})
        |> event("confirm_correction", %{"reason" => "Gagal di SBI", "token_sn" => ""})

      assert flash(socket, :info) ==
               "Status dikoreksi menjadi Gagal. Uang menunggu dikembalikan kasir."

      assert html(socket) =~ "Lihat yang cocok (1)"
      assert Repo.reload!(service).status == "failed"
      assert [{"history", _, _}] = StubClient.requests()
    end

    test "index as text", ctx do
      {_service, socket} = conflict(ctx)
      assert event(socket, "review_correction", %{"index" => "0"}).assigns.correcting
    end

    test "no button for a row in review", ctx do
      {_service, socket} = conflict(ctx, review_reason: "Uji")
      refute html(socket) =~ "Koreksi status"
    end

    test "an index that isn't a row", ctx do
      {_service, socket} = conflict(ctx)

      for index <- ["abc", 99] do
        refute event(socket, "review_correction", %{"index" => index}).assigns.correcting
      end
    end
  end
end
