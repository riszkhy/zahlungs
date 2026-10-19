defmodule Zahlungs.ServicesApiTest do
  @moduledoc """
  PPOB services through a provider API (Fase 1), on the fake provider: bill
  inquiry, recording, sending, the provider's answers, the status checker,
  and what they do to a shift's cash.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Inquiry

  defp d(value), do: Decimal.new(value)

  defp inquiries_of(store),
    do: Repo.aggregate(from(i in Inquiry, where: i.store_id == ^store.id), :count)

  describe "inquire/3" do
    setup do
      store = api_store_fixture()
      %{store: store, cashier: user_on_shift_fixture(), bill: api_product_fixture()}
    end

    test "stores what the provider says, for 15 minutes", ctx do
      assert {:ok, inquiry} = Services.inquire(ctx.cashier, ctx.bill.id, "5300-1122-3331")

      assert {inquiry.sheets, inquiry.customer_name, inquiry.period} ==
               {3, "PELANGGAN 3331", "AGU–OKT 2026"}

      assert inquiry.customer_ref == "530011223331"
      assert Decimal.equal?(inquiry.bill_amount, d("735000"))
      assert inquiry.store_id == ctx.store.id
      assert is_nil(inquiry.used_at)

      seconds = NaiveDateTime.diff(inquiry.expires_at, NaiveDateTime.utc_now())
      assert seconds in 890..900

      # 735.000 + 3 sheets × 3.000 admin
      assert Decimal.equal?(Services.inquiry_price(inquiry).price, d("744000"))
    end

    test "passes the provider's refusals on, recording nothing", ctx do
      before = inquiries_of(ctx.store)

      assert Services.inquire(ctx.cashier, ctx.bill.id, "530011223346") == {:error, :not_found}
      assert Services.inquire(ctx.cashier, ctx.bill.id, "530011223345") == {:error, :already_paid}
      assert Services.inquire(ctx.cashier, ctx.bill.id, "530011223347") == {:error, :unavailable}

      assert inquiries_of(ctx.store) == before
    end

    test "refuses a number that isn't one before asking the provider", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Services.inquire(ctx.cashier, ctx.bill.id, "12")

      assert errors_on(changeset)[:customer_ref]
    end

    test "needs an open shift, an api account and a bill product with a vendor code", ctx do
      assert Services.inquire(user_fixture(), ctx.bill.id, "530011223331") ==
               {:error, :no_open_shift}

      pulsa = service_product_fixture(%{provider_code: "TSEL10"})

      assert Services.inquire(ctx.cashier, pulsa.id, "081234567891") ==
               {:error, :product_unavailable}

      no_code = api_product_fixture(%{provider_code: nil})

      assert Services.inquire(ctx.cashier, no_code.id, "530011223331") ==
               {:error, :no_provider_code}

      assign_account(default_store(), deposit_account_fixture())
      assert Services.inquire(ctx.cashier, ctx.bill.id, "530011223331") == {:error, :not_api}

      bare = user_on_shift_fixture(%{store_id: store_fixture().id})
      assert Services.inquire(bare, ctx.bill.id, "530011223331") == {:error, :no_deposit_account}
    end
  end
end
