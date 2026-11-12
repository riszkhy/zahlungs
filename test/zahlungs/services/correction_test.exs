defmodule Zahlungs.Services.CorrectionTest do
  @moduledoc """
  An admin's correction of a service's final status, and the one rule for
  money waiting to go back to the customer. Every value here is made up.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.{AccountsFixtures, ServicesFixtures, ShiftsFixtures, StoresFixtures}
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Services, Shifts}
  alias Zahlungs.Services.Transaction

  setup do
    account = deposit_account_fixture()
    store = assign_account(default_store(), account)
    cashier = user_on_shift_fixture()
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

    %{
      account: account,
      store: store,
      cashier: cashier,
      admin: admin,
      product: service_product_fixture(),
      shift: Shifts.current_shift(cashier)
    }
  end

  # A service written directly: 12.000 in cash on the cashier's shift.
  defp service!(ctx, attrs) do
    n = System.unique_integer([:positive])
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    Repo.insert!(
      struct(
        %Transaction{
          code: "KRK-#{n}",
          category: "pulsa",
          product_name: ctx.product.name,
          customer_ref: "089900002222",
          price: Decimal.new(12_000),
          cost: Decimal.new(10_150),
          amount_paid: Decimal.new(12_000),
          payment_method: "cash",
          status: "success",
          channel: "api",
          ref_id: "Z#{n}",
          sent_at: now,
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

  defp drawer(ctx), do: Shifts.expected_cash(Shifts.get_shift!(scope(ctx.cashier), ctx.shift.id))

  defp due_ids(ctx), do: Enum.map(Services.list_refunds_due(scope(ctx.cashier)), & &1.id)

  describe "awaiting refund" do
    test "the rule", ctx do
      corrected = ~N[2026-11-12 03:00:00]

      assert Transaction.awaiting_refund?(service!(ctx, status: "failed"))

      assert Transaction.awaiting_refund?(
               service!(ctx, status: "failed", channel: "manual", corrected_at: corrected)
             )

      refute Transaction.awaiting_refund?(service!(ctx, status: "failed", channel: "manual"))
      refute Transaction.awaiting_refund?(service!(ctx, status: "failed", refunded_at: corrected))
      refute Transaction.awaiting_refund?(service!(ctx, status: "success"))
    end

    test "a manual service failed by a correction counts in its drawer until refunded", ctx do
      before = drawer(ctx)

      tx =
        service!(ctx, status: "failed", channel: "manual", corrected_at: ~N[2026-11-12 03:00:00])

      assert Decimal.equal?(drawer(ctx), Decimal.add(before, 12_000))
      assert tx.id in due_ids(ctx)

      assert {:ok, %{refunded_at: %NaiveDateTime{}}} = Services.confirm_refund(tx, ctx.cashier)
      assert Decimal.equal?(drawer(ctx), before)
    end

    test "a manual service marked failed was handed back already", ctx do
      before = drawer(ctx)
      tx = service!(ctx, status: "failed", channel: "manual")

      assert Decimal.equal?(drawer(ctx), before)
      refute tx.id in due_ids(ctx)
      assert Services.confirm_refund(tx, ctx.cashier) == {:error, :not_refundable}
    end

    test "the refunds-due card on the Layanan screen shows it", ctx do
      tx =
        service!(ctx, status: "failed", channel: "manual", corrected_at: ~N[2026-11-12 03:00:00])

      html = ZahlungsWeb.ServiceLive.Index |> mount_live(ctx.cashier) |> html()

      assert html =~ ~s(id="refund-#{tx.id}")
      assert html =~ "Uang sudah dikembalikan"
    end
  end

  describe "correct_status/5" do
    test "a success becomes a failure waiting for its money", ctx do
      tx = service!(ctx, status: "success", token_sn: "5555")
      before = drawer(ctx)

      assert {:ok, failed} =
               Services.correct_status(ctx.admin, tx, "failed", " Pulsa tidak masuk ")

      assert failed.status == "failed"
      assert failed.failure_reason == "Pulsa tidak masuk"
      assert failed.correction_reason == "Pulsa tidak masuk"
      assert failed.corrected_by_id == ctx.admin.id
      assert %NaiveDateTime{} = failed.corrected_at
      assert failed.token_sn == "5555"
      assert Decimal.equal?(drawer(ctx), before)

      assert {:ok, _} = Services.confirm_refund(failed, ctx.cashier)
      assert Decimal.equal?(drawer(ctx), Decimal.sub(before, 12_000))
    end

    test "on a closed shift the refund is booked where it is handed back", ctx do
      tx = service!(ctx, status: "success")
      {:ok, _closed} = Shifts.close_shift(ctx.shift, drawer(ctx))
      other = user_on_shift_fixture()

      assert {:ok, failed} = Services.correct_status(ctx.admin, tx, "failed", "Tidak masuk")
      assert failed.failed_after_shift_close

      assert {:ok, _} = Services.confirm_refund(failed, other)
      [movement] = Shifts.list_cash_movements(Shifts.current_shift(other))
      assert movement.category == "refund"
      assert Decimal.equal?(movement.amount, 12_000)
    end

    test "a manual success can be failed too", ctx do
      tx = service!(ctx, status: "success", channel: "manual", ref_id: nil)

      assert {:ok, failed} = Services.correct_status(ctx.admin, tx, "failed", "Tidak masuk")
      assert Transaction.awaiting_refund?(failed)
    end

    test "a failure waiting for its money becomes a success", ctx do
      tx =
        service!(ctx,
          status: "failed",
          failure_reason: "Gagal",
          failed_after_shift_close: true,
          commission_percent: Decimal.new(10)
        )

      used = Services.deposit_used(ctx.account)
      assert Decimal.equal?(Services.commission(tx), 0)

      assert {:ok, ok} =
               Services.correct_status(ctx.admin, tx, "success", "Terlayani",
                 token_sn: "1111-2222"
               )

      assert ok.status == "success"
      assert ok.failure_reason == nil
      refute ok.failed_after_shift_close
      assert ok.token_sn == "1111-2222"
      assert Decimal.equal?(Services.commission(ok), 185)
      assert Decimal.equal?(Services.deposit_used(ctx.account), Decimal.add(used, 10_150))
    end

    test "a blank SN keeps the old one", ctx do
      tx = service!(ctx, status: "failed", token_sn: "9999")

      assert {:ok, %{token_sn: "9999"}} =
               Services.correct_status(ctx.admin, tx, "success", "Terlayani", token_sn: "   ")
    end

    test "refused without changing the row", ctx do
      long = String.duplicate("a", 201)

      cases = [
        {ctx.cashier, service!(ctx, status: "success"), "failed", "Alasan", [], :not_admin},
        {ctx.admin, service!(ctx, status: "processing"), "failed", "Alasan", [], :not_final},
        {ctx.admin, service!(ctx, status: "success"), "success", "Alasan", [], :same_status},
        {ctx.admin, service!(ctx, status: "failed", refunded_at: ~N[2026-11-12 03:00:00]),
         "success", "Alasan", [], :refunded},
        {ctx.admin, service!(ctx, status: "failed", channel: "manual"), "success", "Alasan", [],
         :refunded},
        {ctx.admin, service!(ctx, status: "success", review_reason: "Uji"), "failed", "Alasan",
         [], :in_review},
        {ctx.admin, service!(ctx, status: "success"), "failed", "   ", [], :reason_required},
        {ctx.admin, service!(ctx, status: "success"), "failed", long, [], :reason_required},
        {ctx.admin, service!(ctx, status: "failed"), "success", "Alasan",
         [token_sn: String.duplicate("9", 65)], :invalid_token_sn}
      ]

      for {user, tx, to, reason, opts, error} <- cases do
        assert Services.correct_status(user, tx, to, reason, opts) == {:error, error}

        fields = [
          :status,
          :failure_reason,
          :token_sn,
          :refunded_at,
          :corrected_at,
          :correction_reason
        ]

        assert Map.take(Repo.reload!(tx), fields) == Map.take(tx, fields)
      end
    end

    test "a reason of 200 characters is fine", ctx do
      tx = service!(ctx, status: "success")
      reason = String.duplicate("a", 200)

      assert {:ok, %{correction_reason: ^reason}} =
               Services.correct_status(ctx.admin, tx, "failed", reason)
    end

    test "another organization's service", ctx do
      foreign =
        in_org(organization_fixture(), fn ->
          store = store_fixture()
          account = deposit_account_fixture()
          assign_account(store, account)
          cashier = user_on_shift_fixture(store_id: store.id)

          service!(
            %{
              ctx
              | store: store,
                account: account,
                cashier: cashier,
                product: service_product_fixture(),
                shift: Shifts.current_shift(cashier)
            },
            status: "success"
          )
        end)

      assert_raise Ecto.NoResultsError, fn ->
        Services.correct_status(ctx.admin, foreign, "failed", "Alasan")
      end
    end

    test "a stale struct", ctx do
      tx = service!(ctx, status: "success")

      assert {:ok, _} = Services.correct_status(ctx.admin, tx, "failed", "Tidak masuk")
      assert Services.correct_status(ctx.admin, tx, "failed", "Lagi") == {:error, :same_status}
      assert Services.correct_status(ctx.admin, tx, "failed", "Lagi") == {:error, :same_status}
    end

    test "a later contradicting answer goes to review", ctx do
      tx = service!(ctx, status: "success")
      {:ok, _} = Services.correct_status(ctx.admin, tx, "failed", "Tidak masuk")

      Services.apply_result(tx.id, %{status: :success, token_sn: "1", provider_ref: nil})

      reloaded = Repo.reload!(tx)
      assert reloaded.status == "failed"
      assert is_binary(reloaded.review_reason)
    end
  end

  describe "correctable?/1" do
    test "a success, or a failure waiting for its money, not in review", ctx do
      assert Services.correctable?(service!(ctx, status: "success"))
      assert Services.correctable?(service!(ctx, status: "failed"))
      refute Services.correctable?(service!(ctx, status: "failed", channel: "manual"))
      refute Services.correctable?(service!(ctx, status: "success", review_reason: "Uji"))
      refute Services.correctable?(service!(ctx, status: "processing"))
    end
  end
end
