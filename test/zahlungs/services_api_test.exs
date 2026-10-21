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
      assert Decimal.equal?(tx.cost, d("735000"))
      assert Decimal.equal?(tx.change_due, d("6000"))
      assert tx.ref_id == inquiry.ref_id
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

    test "the bill is paid with the inquiry's ref", ctx do
      {:ok, inquiry} = Services.inquire(ctx.cashier, ctx.bill.id, "530011223341")
      assert inquiry.ref_id =~ ~r/^Q#{ctx.store.id}/
      assert inquiry.kind == "bill"
      ref_id = inquiry.ref_id

      assert {:ok, tx} = Services.record(ctx.cashier, ctx.bill.id, paying(inquiry))
      assert tx.ref_id == ref_id
      assert_received {:fake_provider, :pay, ^ref_id}
    end

    test "a bill costs the provider's total plus the shop's fee per sheet", ctx do
      bill = api_product_fixture(%{api_extra_fee: "2000"})
      {:ok, inquiry} = Services.inquire(ctx.cashier, bill.id, "530011223331")

      assert Decimal.equal?(inquiry.provider_total, d("735000"))
      assert Decimal.equal?(inquiry.provider_admin, d("0"))

      assert {:ok, tx} = Services.record(ctx.cashier, bill.id, paying(inquiry))
      assert Decimal.equal?(tx.price, d("741000"))
      assert Decimal.equal?(tx.cost, d("735000"))
      assert Decimal.equal?(tx.quoted_cost, d("735000"))
    end

    test "the vendor code is copied and used", ctx do
      pulsa = service_product_fixture(%{provider_code: "TSEL10"})

      {:ok, tx} =
        Services.record(ctx.cashier, pulsa.id, %{
          "customer_ref" => "081234567894",
          "amount_paid" => "12000"
        })

      {:ok, _} = Services.update_product(pulsa, %{provider_code: "TSEL20"})
      tx = Repo.get!(Services.Transaction, tx.id)

      assert tx.provider_code == "TSEL10"
      assert Decimal.equal?(tx.quoted_cost, tx.cost)
      assert Services.provider_request(tx).product_code == "TSEL10"
    end

    test "api refs are unique across organizations", ctx do
      pulsa = service_product_fixture(%{provider_code: "TSEL10"})

      {:ok, tx} =
        Services.record(ctx.cashier, pulsa.id, %{
          "customer_ref" => "081234567891",
          "amount_paid" => "12000"
        })

      assert tx.ref_id =~ ~r/^Z#{ctx.store.id}\d{12}[0-9A-F]{6}$/
      refute tx.ref_id == tx.code
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

  describe "the status checker" do
    setup do
      account = api_account_fixture()
      assign_account(default_store(), account)

      %{
        account: account,
        cashier: user_on_shift_fixture(),
        pulsa: service_product_fixture(%{provider_code: "TSEL10"})
      }
    end

    defp record_pulsa(ctx, number) do
      {:ok, tx} =
        Services.record(ctx.cashier, ctx.pulsa.id, %{
          "customer_ref" => number,
          "amount_paid" => "12000"
        })

      tx
    end

    defp later(seconds), do: NaiveDateTime.add(NaiveDateTime.utc_now(), seconds)
    defp status_of(tx), do: Repo.get!(Services.Transaction, tx.id).status

    defp flush_provider_calls do
      receive do
        {:fake_provider, _, _} -> flush_provider_calls()
      after
        0 -> :ok
      end
    end

    test "pending is settled by a later status check", ctx do
      done = record_pulsa(ctx, "081234567899")
      failed = record_pulsa(ctx, "081234567898")

      assert Services.check_pending(later(31)) >= 2

      assert status_of(done) == "success"
      assert status_of(failed) == "failed"
    end

    test "a service never sent is sent by the checker, once", ctx do
      tx = record_pulsa(ctx, "081234567899")
      ref_id = tx.ref_id
      Repo.update_all(from(t in Services.Transaction, where: t.id == ^tx.id), set: [sent_at: nil])
      flush_provider_calls()

      Services.check_pending(later(31))

      assert_received {:fake_provider, :pay, ^ref_id}
      refute_received {:fake_provider, :pay, ^ref_id}
      assert Repo.get!(Services.Transaction, tx.id).sent_at
    end

    test "a sent service is only asked about, never paid again", ctx do
      tx = record_pulsa(ctx, "081234567894")
      ref_id = tx.ref_id
      flush_provider_calls()

      Services.check_pending(later(31))
      Services.check_pending(later(62))

      refute_received {:fake_provider, :pay, ^ref_id}
      assert_received {:fake_provider, :status, ^ref_id}

      reloaded = Repo.get!(Services.Transaction, tx.id)
      assert reloaded.status == "processing"
      assert reloaded.provider_message =~ "tidak mengenal"
    end

    test "recently checked services wait their turn", ctx do
      tx = record_pulsa(ctx, "081234567899")
      ref_id = tx.ref_id
      flush_provider_calls()

      Services.check_pending(later(10))

      refute_received {:fake_provider, :status, ^ref_id}
      assert status_of(tx) == "processing"
    end

    test "the cashier's status check asks right away", ctx do
      tx = record_pulsa(ctx, "081234567899")

      assert {:ok, %Services.Transaction{status: "success"}} = Services.check_status(tx.id)
      assert Services.check_status(tx.id) == {:ok, :already_final}
    end

    test "a payment still on its way isn't asked about yet", ctx do
      tx = record_pulsa(ctx, "081234567899")
      ref_id = tx.ref_id
      sent_now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      Repo.update_all(from(t in Services.Transaction, where: t.id == ^tx.id),
        set: [sent_at: sent_now, last_checked_at: nil]
      )

      flush_provider_calls()

      Services.check_pending(later(10))
      refute_received {:fake_provider, :status, ^ref_id}

      Services.check_pending(later(31))
      assert_received {:fake_provider, :status, ^ref_id}
    end

    test "success clears an earlier warning", ctx do
      tx = record_pulsa(ctx, "081234567899")

      Repo.update_all(from(t in Services.Transaction, where: t.id == ^tx.id),
        set: [provider_message: "Penyedia tidak mengenal transaksi ini."]
      )

      Services.check_pending(later(31))

      assert %{status: "success", provider_message: nil} = Repo.get!(Services.Transaction, tx.id)
    end

    @tag :capture_log
    test "a service that breaks the check doesn't stop the others", ctx do
      broken_store = store_fixture()
      assign_account(broken_store, deposit_account_fixture(%{mode: "api", provider: "broken"}))
      elsewhere = user_on_shift_fixture(%{store_id: broken_store.id})

      {:ok, broken} =
        Services.record(elsewhere, ctx.pulsa.id, %{
          "customer_ref" => "081234567899",
          "amount_paid" => "12000"
        })

      done = record_pulsa(ctx, "081234567899")
      assert broken.id < done.id

      Services.check_pending(later(31))

      assert status_of(done) == "success"
      assert status_of(broken) == "processing"
    end

    test "an admin may settle a service the provider has left waiting", ctx do
      tx = record_pulsa(ctx, "081234567894")
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")

      refute Services.awaiting_too_long?(tx)
      assert Services.mark_failed(tx, admin, "Tidak ada") == {:error, :not_manual}

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -11 * 60)

      Repo.update_all(from(t in Services.Transaction, where: t.id == ^tx.id),
        set: [inserted_at: long_ago]
      )

      tx = Repo.get!(Services.Transaction, tx.id)
      assert Services.awaiting_too_long?(tx)
      assert Services.mark_failed(tx, ctx.cashier, "Tidak ada") == {:error, :not_manual}

      assert {:ok, failed} = Services.mark_failed(tx, admin, "Tidak ada di aplikasi penyedia")
      assert {failed.status, failed.resolved_by_id} == {"failed", admin.id}
      assert tx.id in Enum.map(Services.list_refunds_due(store_scope()), & &1.id)
    end

    test "switching the account to manual leaves pending api services to the provider", ctx do
      tx = record_pulsa(ctx, "081234567899")
      {:ok, _} = Zahlungs.Deposits.update_account(ctx.account, %{"mode" => "manual"})

      assert Services.mark_success(tx, ctx.cashier, nil) == {:error, :not_manual}

      Services.check_pending(later(31))
      assert status_of(tx) == "success"
    end
  end

  describe "shift cash and refunds" do
    alias Zahlungs.Shifts

    setup do
      account = api_account_fixture()
      store = assign_account(default_store(), account)
      cashier = user_fixture()

      %{
        account: account,
        store: store,
        cashier: cashier,
        shift: shift_fixture(cashier, "50000"),
        pulsa: service_product_fixture(%{provider_code: "TSEL10"})
      }
    end

    defp sell_pulsa(ctx, number, method \\ "cash") do
      {:ok, tx} =
        Services.record(ctx.cashier, ctx.pulsa.id, %{
          "customer_ref" => number,
          "payment_method" => method,
          "amount_paid" => "12000"
        })

      tx
    end

    defp in_a_minute, do: NaiveDateTime.add(NaiveDateTime.utc_now(), 61)
    defp fresh(tx), do: Repo.get!(Services.Transaction, tx.id)
    defp money_equal?(a, b), do: Decimal.equal?(a, Decimal.new(b))

    test "a shift closes over pending api services; manual ones still hold it", ctx do
      sell_pulsa(ctx, "081234567899")

      assert {:ok, closed} = Shifts.close_shift(ctx.shift, "62000")
      assert money_equal?(closed.expected_cash, "62000")

      manual_cashier = user_fixture()
      manual_shift = shift_fixture(manual_cashier, "0")
      {:ok, _} = Zahlungs.Deposits.update_account(ctx.account, %{"mode" => "manual"})

      {:ok, _} =
        Services.record(manual_cashier, ctx.pulsa.id, %{
          "customer_ref" => "081234567891",
          "amount_paid" => "12000"
        })

      assert Shifts.close_shift(manual_shift, "12000") == {:error, :services_processing}
    end

    test "a failure after close keeps the closed shift final", ctx do
      tx = sell_pulsa(ctx, "081234567898")
      {:ok, closed} = Shifts.close_shift(ctx.shift, "62000")

      Services.check_pending(in_a_minute())

      assert {fresh(tx).status, fresh(tx).failed_after_shift_close} == {"failed", true}
      assert money_equal?(Shifts.shift_summary(closed).expected_cash, "62000")
      assert money_equal?(Shifts.expected_cash(closed), "62000")
    end

    test "the refund comes out of the next shift's drawer", ctx do
      tx = sell_pulsa(ctx, "081234567898")
      {:ok, _} = Shifts.close_shift(ctx.shift, "62000")
      Services.check_pending(in_a_minute())

      next_shift = shift_fixture(ctx.cashier, "0")
      assert tx.id in Enum.map(Services.list_refunds_due(store_scope()), & &1.id)

      assert {:ok, refunded} = Services.confirm_refund(fresh(tx), ctx.cashier)
      assert refunded.refunded_at && refunded.refunded_by_id == ctx.cashier.id

      assert [movement] = Shifts.list_cash_movements(next_shift)
      assert {movement.category, movement.direction} == {"refund", "out"}
      assert money_equal?(movement.amount, "12000")
      assert money_equal?(Shifts.expected_cash(next_shift), "-12000")

      refute tx.id in Enum.map(Services.list_refunds_due(store_scope()), & &1.id)
      assert Services.confirm_refund(fresh(tx), ctx.cashier) == {:error, :not_refundable}
    end

    test "a failure counts in its shift until the money is handed back from that drawer", ctx do
      tx = sell_pulsa(ctx, "081234567890")

      assert fresh(tx).status == "failed"
      refute fresh(tx).failed_after_shift_close
      assert money_equal?(Shifts.expected_cash(ctx.shift), "62000")

      assert {:ok, _} = Services.confirm_refund(fresh(tx), ctx.cashier)
      assert Shifts.list_cash_movements(ctx.shift) == []
      assert money_equal?(Shifts.expected_cash(ctx.shift), "50000")
    end

    test "a failure the shift closed over is refunded from the next drawer", ctx do
      tx = sell_pulsa(ctx, "081234567898")
      Services.check_pending(in_a_minute())
      assert fresh(tx).status == "failed"

      assert {:ok, closed} = Shifts.close_shift(ctx.shift, "62000")
      assert money_equal?(closed.expected_cash, "62000")

      next_shift = shift_fixture(ctx.cashier, "0")
      assert {:ok, _} = Services.confirm_refund(fresh(tx), ctx.cashier)

      assert [%{category: "refund"}] = Shifts.list_cash_movements(next_shift)
      assert money_equal?(Shifts.expected_cash(closed), "62000")
    end

    test "another cashier's refund comes out of their own drawer", ctx do
      tx = sell_pulsa(ctx, "081234567890")
      colleague = user_fixture()
      their_shift = shift_fixture(colleague, "0")

      assert {:ok, _} = Services.confirm_refund(fresh(tx), colleague)

      assert [%{category: "refund"}] = Shifts.list_cash_movements(their_shift)
      assert money_equal?(Shifts.expected_cash(their_shift), "-12000")
      assert money_equal?(Shifts.expected_cash(ctx.shift), "62000")
    end

    test "a non-cash failure is never refunded from a drawer", ctx do
      tx = sell_pulsa(ctx, "081234567898", "qris")
      {:ok, _} = Shifts.close_shift(ctx.shift, "50000")
      Services.check_pending(in_a_minute())
      next_shift = shift_fixture(ctx.cashier, "0")

      assert {:ok, _} = Services.confirm_refund(fresh(tx), ctx.cashier)
      assert Shifts.list_cash_movements(next_shift) == []
    end

    test "refunds are confirmed in the service's own store, on an open shift", ctx do
      tx = sell_pulsa(ctx, "081234567890")

      elsewhere = user_on_shift_fixture(%{store_id: store_fixture().id})
      assert Services.confirm_refund(fresh(tx), elsewhere) == {:error, :other_store}
      assert Services.confirm_refund(fresh(tx), user_fixture()) == {:error, :no_open_shift}
      assert is_nil(fresh(tx).refunded_at)
    end
  end
end
