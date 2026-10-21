defmodule Zahlungs.ServicesReviewTest do
  @moduledoc """
  What the provider's answers carry besides the outcome (the actual cost and
  the raw answer), and answers that contradict a final status: they are held
  for an admin (`Services.resolve_review/3`), never applied by themselves.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.{Services, Shifts}
  alias Zahlungs.Services.Transaction

  defp d(value), do: Decimal.new(value)
  defp fresh(tx), do: Repo.get!(Transaction, tx.id)

  setup do
    account = api_account_fixture()
    assign_account(default_store(), account)
    cashier = user_fixture()
    shift = shift_fixture(cashier, "50000")
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    pulsa = service_product_fixture(%{provider_code: "TSEL10"})

    # Digit 9: the fake leaves it pending, so each test settles it itself.
    {:ok, tx} =
      Services.record(cashier, pulsa.id, %{
        "customer_ref" => "081234567899",
        "amount_paid" => "12000"
      })

    %{account: account, cashier: cashier, shift: shift, admin: admin, pulsa: pulsa, tx: tx}
  end

  defp success(extra \\ %{}),
    do: Map.merge(%{status: :success, token_sn: "SN1", provider_ref: "R1"}, extra)

  describe "the provider's answer" do
    test "brings the actual cost and the raw answer", ctx do
      assert {:ok, %Transaction{}} =
               Services.apply_result(
                 ctx.tx.id,
                 success(%{actual_cost: d("10100"), payload: ~s({"status":1})})
               )

      tx = fresh(ctx.tx)
      assert Decimal.equal?(tx.cost, d("10100"))
      assert Decimal.equal?(tx.quoted_cost, d("10150"))
      assert tx.provider_payload == ~s({"status":1})
      assert Decimal.equal?(Services.deposit_used(ctx.account), d("10100"))
    end

    test "an actual cost above the product's cost marks the product", ctx do
      Services.apply_result(ctx.tx.id, success(%{actual_cost: d("10500")}))
      assert Decimal.equal?(Services.get_product!(ctx.pulsa.id).provider_price, d("10500"))
    end

    test "a cost at or under the product's leaves it", ctx do
      Services.apply_result(ctx.tx.id, success(%{actual_cost: d("10150")}))
      assert is_nil(Services.get_product!(ctx.pulsa.id).provider_price)
    end

    test "a long raw answer is cut to 4000 characters", ctx do
      Services.apply_result(ctx.tx.id, success(%{payload: String.duplicate("x", 5000)}))
      assert String.length(fresh(ctx.tx).provider_payload) == 4000
    end

    test "a refund while processing is a failure", ctx do
      Services.apply_result(ctx.tx.id, %{status: :refunded, message: "Refund transaksi"})
      assert %{status: "failed", review_reason: nil} = fresh(ctx.tx)
    end
  end

  describe "answers that agree with the final status" do
    test "a second success is ignored, not reviewed", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, success())

      assert Services.apply_result(ctx.tx.id, success(%{token_sn: "SN2"})) ==
               {:ok, :already_final}

      assert %{token_sn: "SN1", review_reason: nil} = fresh(ctx.tx)
    end

    test "pending after a final status is ignored", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, success())
      assert Services.apply_result(ctx.tx.id, %{status: :pending}) == {:ok, :already_final}
      assert is_nil(fresh(ctx.tx).review_reason)
    end

    test "a second failure is ignored", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, %{status: :failed, message: "Nomor salah"})

      assert Services.apply_result(ctx.tx.id, %{status: :failed, message: "lagi"}) ==
               {:ok, :already_final}

      assert is_nil(fresh(ctx.tx).review_reason)
    end
  end

  describe "answers that contradict the final status" do
    test "a refund after success is held for review", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, success())
      Services.subscribe(ctx.tx.store_id)

      assert {:ok, %Transaction{}} =
               Services.apply_result(ctx.tx.id, %{status: :refunded, message: "Refund transaksi"})

      tx = fresh(ctx.tx)
      assert tx.status == "success"
      assert tx.review_reason =~ "refund"
      assert tx.review_reason =~ "Refund transaksi"
      assert [%{id: id}] = Services.list_in_review(ctx.account)
      assert id == tx.id
      assert_receive {:service_changed, ^id}
    end

    test "a success after failure is held for review", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, %{status: :failed, message: "Nomor salah"})
      {:ok, %Transaction{}} = Services.apply_result(ctx.tx.id, success())

      tx = fresh(ctx.tx)
      assert tx.status == "failed"
      assert tx.review_reason =~ "berhasil setelah"
    end
  end

  describe "resolve_review/3" do
    setup ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, success())

      {:ok, _} =
        Services.apply_result(ctx.tx.id, %{status: :refunded, message: "Refund transaksi"})

      :ok
    end

    test "is for admins", ctx do
      assert Services.resolve_review(fresh(ctx.tx), ctx.cashier, :keep) == {:error, :forbidden}
    end

    test "keep: stays successful, the flag goes", ctx do
      assert {:ok, tx} = Services.resolve_review(fresh(ctx.tx), ctx.admin, :keep)
      assert {tx.status, tx.review_reason, tx.reviewed_by_id} == {"success", nil, ctx.admin.id}
      assert tx.reviewed_at
      assert Services.list_in_review(ctx.account) == []

      assert Services.resolve_review(fresh(ctx.tx), ctx.admin, :keep) ==
               {:error, :not_in_review}
    end

    test "refund: fails it, the money waits to go back, the drawer stays even", ctx do
      assert money?(Shifts.expected_cash(ctx.shift), "62000")

      assert {:ok, tx} = Services.resolve_review(fresh(ctx.tx), ctx.admin, :refund)
      assert tx.status == "failed"
      assert tx.failure_reason =~ "refund"
      assert tx.id in Enum.map(Services.list_refunds_due(store_scope()), & &1.id)
      assert Decimal.equal?(Services.deposit_used(ctx.account), d("0"))

      # Still in the drawer until the refund is confirmed (Fase 1 rule).
      assert money?(Shifts.expected_cash(ctx.shift), "62000")

      {:ok, closed} = Shifts.close_shift(ctx.shift, "62000")
      next_shift = shift_fixture(ctx.cashier, "0")
      assert {:ok, _} = Services.confirm_refund(fresh(ctx.tx), ctx.cashier)

      assert [%{category: "refund"}] = Shifts.list_cash_movements(next_shift)
      assert money?(Shifts.expected_cash(closed), "62000")
    end

    test "refund is only for a success in review", ctx do
      {:ok, _} = Services.resolve_review(fresh(ctx.tx), ctx.admin, :keep)

      assert Services.resolve_review(fresh(ctx.tx), ctx.admin, :refund) ==
               {:error, :not_in_review}
    end
  end

  defp money?(value, expected), do: Decimal.equal?(value, d(expected))
end
