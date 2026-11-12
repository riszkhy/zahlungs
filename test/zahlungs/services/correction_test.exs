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
end
