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

  describe "record/3 on an api account" do
    setup do
      store = api_store_fixture()
      %{store: store, cashier: user_on_shift_fixture(), bill: api_product_fixture()}
    end

    defp paying(inquiry, extra \\ %{}) do
      Map.merge(
        %{"inquiry_id" => inquiry.id, "payment_method" => "cash", "amount_paid" => "750000"},
        extra
      )
    end

    test "a bill is recorded from its inquiry, once", ctx do
      {:ok, inquiry} = Services.inquire(ctx.cashier, ctx.bill.id, "530011223331")

      # A number or amount sent along is ignored: the inquiry decides.
      tampered = paying(inquiry, %{"customer_ref" => "081200000000", "bill_amount" => "1"})
      assert {:ok, tx} = Services.record(ctx.cashier, ctx.bill.id, tampered)

      assert tx.channel == "api"
      assert tx.customer_ref == "530011223331"
      assert {tx.sheets, tx.customer_name, tx.period} == {3, "PELANGGAN 3331", "AGU–OKT 2026"}
      assert Decimal.equal?(tx.bill_amount, d("735000"))
      assert Decimal.equal?(tx.price, d("744000"))
      assert Decimal.equal?(tx.cost, d("739500"))
      assert Decimal.equal?(tx.change_due, d("6000"))
      assert tx.ref_id == tx.code
      assert tx.service_inquiry_id == inquiry.id
      assert Repo.get!(Inquiry, inquiry.id).used_at

      assert Services.record(ctx.cashier, ctx.bill.id, paying(inquiry)) ==
               {:error, :inquiry_expired}
    end

    test "an expired inquiry, or one of another store or product, can't be paid", ctx do
      {:ok, old} = Services.inquire(ctx.cashier, ctx.bill.id, "530011223341")
      past = NaiveDateTime.add(NaiveDateTime.utc_now(), -60) |> NaiveDateTime.truncate(:second)
      Repo.update_all(from(i in Inquiry, where: i.id == ^old.id), set: [expires_at: past])
      assert Services.record(ctx.cashier, ctx.bill.id, paying(old)) == {:error, :inquiry_expired}

      {:ok, inquiry} = Services.inquire(ctx.cashier, ctx.bill.id, "530011223341")
      other_bill = api_product_fixture()

      assert Services.record(ctx.cashier, other_bill.id, paying(inquiry)) ==
               {:error, :inquiry_expired}

      other_store = store_fixture()
      assign_account(other_store, api_account_fixture())
      elsewhere = user_on_shift_fixture(%{store_id: other_store.id})

      assert Services.record(elsewhere, ctx.bill.id, paying(inquiry)) ==
               {:error, :inquiry_expired}

      assert Services.record(ctx.cashier, ctx.bill.id, Map.delete(paying(inquiry), "inquiry_id")) ==
               {:error, :inquiry_expired}
    end

    test "pulsa on an api account needs a vendor code", ctx do
      pulsa = service_product_fixture()

      assert Services.record(ctx.cashier, pulsa.id, %{
               "customer_ref" => "081234567891",
               "amount_paid" => "12000"
             }) == {:error, :no_provider_code}

      coded = service_product_fixture(%{provider_code: "TSEL10"})

      assert {:ok, tx} =
               Services.record(ctx.cashier, coded.id, %{
                 "customer_ref" => "081234567891",
                 "amount_paid" => "12000"
               })

      assert {tx.channel, tx.sheets} == {"api", 1}
    end

    test "a manual account still records the Fase 0 way", ctx do
      assign_account(default_store(), deposit_account_fixture())

      bill =
        service_product_fixture(%{category: "tagihan_pln", cost: "1500", margin_value: "3000"})

      assert {:ok, tx} =
               Services.record(ctx.cashier, bill.id, %{
                 "customer_ref" => "530011223344",
                 "bill_amount" => "245000",
                 "amount_paid" => "248000"
               })

      assert {tx.channel, tx.sheets, tx.service_inquiry_id} == {"manual", 1, nil}
      assert Decimal.equal?(tx.price, d("248000"))
    end
  end

  describe "sending and the provider's answers" do
    setup do
      store = api_store_fixture()

      %{
        store: store,
        cashier: user_on_shift_fixture(),
        pulsa: service_product_fixture(%{provider_code: "TSEL10"}),
        token:
          service_product_fixture(%{
            category: "token_pln",
            provider_code: "PLN20",
            cost: "50150",
            margin_value: "2350"
          })
      }
    end

    defp sell(cashier, product, number, extra \\ %{}) do
      {:ok, %{price: price}} = Services.price_for(product, nil)

      {:ok, tx} =
        Services.record(
          cashier,
          product.id,
          Map.merge(
            %{
              "customer_ref" => number,
              "payment_method" => "cash",
              "amount_paid" => Decimal.to_string(price)
            },
            extra
          )
        )

      tx
    end

    defp reload(tx), do: Repo.get!(Services.Transaction, tx.id)

    test "pays at once: success keeps the token, failure the message", ctx do
      done = ctx.cashier |> sell(ctx.pulsa, "081234567891") |> reload()

      assert {done.status, done.token_sn, done.provider_ref} ==
               {"success", "SN" <> done.ref_id, "FAKE-" <> done.ref_id}

      assert done.sent_at && done.resolved_at

      token = ctx.cashier |> sell(ctx.token, "12345678901") |> reload()
      assert token.status == "success"
      assert token.token_sn =~ ~r/^\d{20}$/

      failed = ctx.cashier |> sell(ctx.pulsa, "081234567890") |> reload()
      assert {failed.status, failed.provider_message} == {"failed", "Nomor tidak aktif"}
      refute failed.failed_after_shift_close
    end

    test "pending stays processing; a timeout too", ctx do
      pending = ctx.cashier |> sell(ctx.pulsa, "081234567899") |> reload()
      assert {pending.status, pending.provider_ref} == {"processing", "FAKE-" <> pending.ref_id}
      assert pending.sent_at

      timeout = ctx.cashier |> sell(ctx.pulsa, "081234567897") |> reload()

      assert {timeout.status, timeout.provider_message} ==
               {"processing", "Belum ada jawaban penyedia"}
    end

    test "a payment is sent once", ctx do
      tx = sell(ctx.cashier, ctx.pulsa, "081234567899")
      ref_id = tx.ref_id
      assert_received {:fake_provider, :pay, ^ref_id}

      assert Services.send_payment(tx.id) == :ok
      refute_received {:fake_provider, :pay, ^ref_id}
    end

    test "a late answer for a settled service is ignored", ctx do
      tx = sell(ctx.cashier, ctx.pulsa, "081234567899")

      assert {:ok, %Services.Transaction{status: "failed"}} =
               Services.apply_result(tx.id, %{status: :failed, message: "Gagal di penyedia"})

      assert Services.apply_result(tx.id, %{status: :success, token_sn: "X", provider_ref: "Y"}) ==
               {:ok, :already_final}

      assert reload(tx).status == "failed"
    end

    test "changes are broadcast to the store", ctx do
      :ok = Services.subscribe(ctx.store.id)
      tx = sell(ctx.cashier, ctx.pulsa, "081234567891")
      id = tx.id

      assert_receive {:service_changed, ^id}
    end

    test "api services can't be marked by hand", ctx do
      tx = sell(ctx.cashier, ctx.pulsa, "081234567899")

      assert Services.mark_success(tx, ctx.cashier, nil) == {:error, :not_manual}
      assert Services.mark_failed(tx, ctx.cashier, "salah") == {:error, :not_manual}
    end

    test "a bill goes out with its inquiry", ctx do
      bill = api_product_fixture()
      {:ok, inquiry} = Services.inquire(ctx.cashier, bill.id, "530011223341")

      {:ok, tx} =
        Services.record(ctx.cashier, bill.id, %{
          "inquiry_id" => inquiry.id,
          "amount_paid" => "251000"
        })

      assert reload(tx).status == "success"
    end
  end
end
