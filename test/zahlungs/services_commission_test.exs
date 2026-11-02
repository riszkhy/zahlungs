defmodule Zahlungs.ServicesCommissionTest do
  @moduledoc """
  Cashier commission on service transactions: the percent per category (the
  admin's), copied onto a service when a cashier records it, and the amount
  worked out from the final status, price and cost.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.Transaction

  defp admin do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp percent(category), do: Services.commission_percent(category)

  describe "rates" do
    setup do
      %{admin: admin()}
    end

    test "a category without a rate is 0%" do
      rates = Services.commission_rates()

      assert Enum.map(rates, & &1.category) == Enum.map(Services.categories(), &elem(&1, 0))
      assert Enum.all?(rates, &Decimal.equal?(&1.percent, 0))
      assert Decimal.equal?(percent("pulsa"), 0)
    end

    test "an admin saves every category at once; blank is 0", %{admin: admin} do
      assert {:ok, _} =
               Services.save_commission_rates(admin, %{
                 "pulsa" => "10",
                 "tagihan" => "12.5",
                 "token_pln" => ""
               })

      assert Decimal.equal?(percent("pulsa"), "10")
      assert Decimal.equal?(percent("tagihan"), "12.5")
      assert Decimal.equal?(percent("token_pln"), 0)

      # Saved again: updated, not duplicated.
      assert {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "20"})
      assert Decimal.equal?(percent("pulsa"), "20")
      assert length(Services.commission_rates()) == length(Services.categories())
    end

    test "one wrong value saves nothing", %{admin: admin} do
      for bad <- ["-1", "101", "abc", "1.234", "12,5"] do
        assert {:error, %{"paket_data" => message}} =
                 Services.save_commission_rates(admin, %{"pulsa" => "10", "paket_data" => bad})

        assert is_binary(message)
        assert Decimal.equal?(percent("pulsa"), 0)
      end
    end

    test "a cashier can't save" do
      assert Services.save_commission_rates(user_fixture(), %{"pulsa" => "10"}) ==
               {:error, :unauthorized}

      assert Decimal.equal?(percent("pulsa"), 0)
    end

    test "another organization's rates are not ours" do
      in_org(organization_fixture(), fn ->
        {:ok, _} = Services.save_commission_rates(admin(), %{"pulsa" => "50"})
        assert Decimal.equal?(percent("pulsa"), "50")
      end)

      assert Decimal.equal?(percent("pulsa"), 0)
    end
  end

  describe "recording" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      admin = admin()
      {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10", "tagihan" => "12.5"})

      %{admin: admin, cashier: user_on_shift_fixture(), pulsa: service_product_fixture()}
    end

    test "a cashier's service carries the category's percent", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      assert Decimal.equal?(tx.commission_percent, "10")

      token = service_product_fixture(%{category: "token_pln"})
      assert Decimal.equal?(service_fixture(ctx.cashier, token).commission_percent, 0)
    end

    test "an admin's service carries none" do
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")
      tx = service_fixture(admin, service_product_fixture())
      assert Decimal.equal?(tx.commission_percent, 0)
    end

    test "the role is read from the database, not the struct", ctx do
      {:ok, _} = Zahlungs.Accounts.set_user_role(ctx.cashier, "admin")

      # ctx.cashier still says "cashier".
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      assert Decimal.equal?(tx.commission_percent, 0)
    end

    test "an admin made cashier mid-shift earns on what is recorded after" do
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")
      pulsa = service_product_fixture()
      before = service_fixture(admin, pulsa)

      {:ok, _} = Zahlungs.Accounts.set_user_role(admin, "cashier")

      # `admin` still says "admin".
      later = service_fixture(admin, pulsa)
      assert Decimal.equal?(before.commission_percent, 0)
      assert Decimal.equal?(later.commission_percent, "10")
    end

    test "the percent can't come from the caller", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa, %{"commission_percent" => "99"})
      assert Decimal.equal?(tx.commission_percent, "10")
    end

    test "a later change of percent leaves recorded services alone", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      {:ok, _} = Services.save_commission_rates(ctx.admin, %{"pulsa" => "50"})

      assert Decimal.equal?(Repo.get!(Transaction, tx.id).commission_percent, "10")
    end
  end

  describe "report" do
    # Pulsa at 10%: each success is 185 on a margin of 1.850.
    setup do
      assign_account(default_store(), deposit_account_fixture())
      admin = admin()
      {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10"})
      pulsa = service_product_fixture()

      a = user_on_shift_fixture()
      b = user_on_shift_fixture()
      {:ok, serving_admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")

      for user <- [a, a, b, serving_admin] do
        {:ok, _} = Services.mark_success(service_fixture(user, pulsa), user, nil)
      end

      {:ok, _} = Services.mark_failed(service_fixture(a, pulsa), a, "gagal")
      service_fixture(a, pulsa)

      %{admin: admin, a: a, b: b, pulsa: pulsa, today: Zahlungs.LocalTime.today()}
    end

    defp row(report, user), do: Enum.find(report.rows, &(&1.user_id == user.id))

    test "per cashier: successful services only; admins earn none", ctx do
      report = Services.commission_report(store_scope(), ctx.today, ctx.today)

      assert report.rows |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([ctx.a.id, ctx.b.id])

      assert row(report, ctx.a).count == 2
      assert Decimal.equal?(row(report, ctx.a).margin, 3700)
      assert Decimal.equal?(row(report, ctx.a).commission, 370)
      assert Decimal.equal?(row(report, ctx.b).commission, 185)
      assert {report.count, Decimal.to_integer(report.commission)} == {3, 555}
      assert Decimal.equal?(report.margin, 5550)
    end

    test "the total is the sum of the details", ctx do
      details = Services.commission_details(store_scope(), ctx.a.id, ctx.today, ctx.today)

      assert length(details) == 2
      assert Enum.all?(details, &(&1.product_name == ctx.pulsa.name))
      total = Enum.reduce(details, Decimal.new(0), &Decimal.add(&1.commission, &2))
      assert Decimal.equal?(total, 370)
    end

    test "a cashier sees only themself", ctx do
      scope = scope(ctx.a)

      assert [%{user_id: id}] = Services.commission_report(scope, ctx.today, ctx.today).rows
      assert id == ctx.a.id
      assert length(Services.commission_details(scope, ctx.b.id, ctx.today, ctx.today)) == 2
    end

    test "only the chosen days count" do
      report = Services.commission_report(store_scope(), ~D[2001-01-01], ~D[2001-01-31])
      assert report.rows == [] and Decimal.equal?(report.commission, 0)
    end

    test "all stores of the organization, never another organization", ctx do
      other_store = store_fixture()
      assign_account(other_store, deposit_account_fixture())
      elsewhere = user_on_shift_fixture(%{store_id: other_store.id})
      {:ok, _} = Services.mark_success(service_fixture(elsewhere, ctx.pulsa), elsewhere, nil)

      foreigner =
        in_org(organization_fixture(), fn ->
          foreign_store = store_fixture()
          assign_account(foreign_store, deposit_account_fixture())
          {:ok, _} = Services.save_commission_rates(admin(), %{"pulsa" => "10"})
          foreigner = user_on_shift_fixture(%{store_id: foreign_store.id})
          foreign = service_fixture(foreigner, service_product_fixture())
          {:ok, _} = Services.mark_success(foreign, foreigner, nil)
          foreigner
        end)

      ids = fn scope ->
        scope
        |> Services.commission_report(ctx.today, ctx.today)
        |> Map.fetch!(:rows)
        |> Enum.map(& &1.user_id)
      end

      refute elsewhere.id in ids.(store_scope())
      assert elsewhere.id in ids.(all_stores_scope(ctx.admin))
      refute foreigner.id in ids.(all_stores_scope(ctx.admin))
    end

    test "the days are the store's local days", ctx do
      tx = service_fixture(ctx.b, ctx.pulsa)
      {:ok, _} = Services.mark_success(tx, ctx.b, nil)
      {start, _finish} = Zahlungs.LocalTime.day_range(ctx.today, ctx.today, default_store())
      yesterday = Date.add(ctx.today, -1)

      count_of = fn day ->
        report = Services.commission_report(store_scope(), day, day)
        if row = row(report, ctx.b), do: row.count, else: 0
      end

      # The first second of the local day (the evening before, in UTC) is today.
      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [inserted_at: start])
      assert {count_of.(ctx.today), count_of.(yesterday)} == {2, 0}

      # One second earlier is yesterday.
      earlier = NaiveDateTime.add(start, -1)
      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [inserted_at: earlier])
      assert {count_of.(ctx.today), count_of.(yesterday)} == {1, 1}
    end

    test "shift_commission/1 adds up a shift's", ctx do
      shift = Zahlungs.Shifts.current_shift(ctx.a)
      assert Decimal.equal?(Services.shift_commission(shift), 370)
    end

    test "the service report shows the commission and the margin after it", ctx do
      report = Services.report(store_scope(), ctx.today, ctx.today)

      assert Decimal.equal?(report.commission, 555)
      assert Decimal.equal?(report.net_margin, Decimal.sub(report.margin, 555))
    end
  end

  describe "the final status and cost" do
    # An api account on the fake provider; number digit 9 stays pending, so
    # each test settles the service itself.
    setup do
      assign_account(default_store(), api_account_fixture())
      admin = admin()
      {:ok, _} = Services.save_commission_rates(admin, %{"pulsa" => "10"})
      cashier = user_fixture()
      shift_fixture(cashier, "50000")
      pulsa = service_product_fixture(%{provider_code: "TSEL10"})

      {:ok, tx} =
        Services.record(cashier, pulsa.id, %{
          "customer_ref" => "081234567899",
          "amount_paid" => "12000"
        })

      %{admin: admin, tx: tx}
    end

    defp fresh(tx), do: Repo.get!(Transaction, tx.id)
    defp success(extra \\ %{}), do: Map.merge(%{status: :success, token_sn: "SN1"}, extra)

    test "the vendor's actual cost is the cost", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, success(%{actual_cost: Decimal.new("10500")}))
      assert Decimal.equal?(Services.commission(fresh(ctx.tx)), 150)
    end

    test "a success refunded through a review loses it", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, success())
      assert Decimal.equal?(Services.commission(fresh(ctx.tx)), 185)

      {:ok, _} =
        Services.apply_result(ctx.tx.id, %{status: :refunded, message: "Refund transaksi"})

      {:ok, _} = Services.resolve_review(fresh(ctx.tx), ctx.admin, :refund)

      assert Decimal.equal?(Services.commission(fresh(ctx.tx)), 0)
      today = Zahlungs.LocalTime.today()
      assert Services.commission_report(store_scope(), today, today).rows == []
    end

    test "a failure made a success through a review earns it", ctx do
      {:ok, _} = Services.apply_result(ctx.tx.id, %{status: :failed, message: "Nomor salah"})
      {:ok, _} = Services.apply_result(ctx.tx.id, success())
      assert Decimal.equal?(Services.commission(fresh(ctx.tx)), 0)

      {:ok, _} = Services.resolve_review(fresh(ctx.tx), ctx.admin, :success)
      assert Decimal.equal?(Services.commission(fresh(ctx.tx)), 185)
    end

    test "a bill of 3 months earns on the 3 months' margin", ctx do
      {:ok, _} = Services.save_commission_rates(ctx.admin, %{"tagihan" => "12.5"})
      cashier = ctx.tx.user_id |> Zahlungs.Accounts.get_user!()
      bill = api_product_fixture()

      # The fake bills 3 months when the second-to-last digit is 3, and pays.
      {:ok, inquiry} = Services.inquire(cashier, bill.id, "530011223331")

      {:ok, tx} =
        Services.record(cashier, bill.id, %{"inquiry_id" => inquiry.id, "amount_paid" => "750000"})

      tx = fresh(tx)
      assert {tx.status, tx.sheets} == {"success", 3}
      # 3.000 the shop adds per month.
      assert Decimal.equal?(Decimal.sub(tx.price, tx.cost), 9000)
      assert Decimal.equal?(Services.commission(tx), 1125)
    end
  end

  describe "in rupiah" do
    # Pulsa earns Rp 500 a service, token PLN 10% of the margin.
    setup do
      assign_account(default_store(), deposit_account_fixture())
      admin = admin()

      {:ok, _} =
        Services.save_commission_rates(admin, %{
          "pulsa" => %{"kind" => "amount", "value" => "500"},
          "token_pln" => %{"kind" => "percent", "value" => "10"}
        })

      %{admin: admin, cashier: user_on_shift_fixture(), pulsa: service_product_fixture()}
    end

    defp rate(category), do: Enum.find(Services.commission_rates(), &(&1.category == category))

    test "each category is a percent or an amount, never both", ctx do
      assert %{kind: "amount"} = rate("pulsa")
      assert Decimal.equal?(rate("pulsa").amount, 500)
      assert Decimal.equal?(rate("pulsa").percent, 0)

      assert %{kind: "percent"} = rate("token_pln")
      assert Decimal.equal?(rate("token_pln").percent, 10)
      assert Decimal.equal?(rate("token_pln").amount, 0)

      assert %{kind: "percent"} = rate("tagihan")

      {:ok, _} =
        Services.save_commission_rates(ctx.admin, %{
          "pulsa" => %{"kind" => "percent", "value" => "20"}
        })

      assert %{kind: "percent"} = rate("pulsa")
      assert Decimal.equal?(rate("pulsa").percent, 20)
      assert Decimal.equal?(rate("pulsa").amount, 0)
    end

    test "an amount is whole rupiah up to a million; a wrong one saves nothing", ctx do
      for bad <- ["-1", "500.50", "1.000", "abc", "1000001"] do
        assert {:error, %{"paket_data" => message}} =
                 Services.save_commission_rates(ctx.admin, %{
                   "pulsa" => %{"kind" => "amount", "value" => "900"},
                   "paket_data" => %{"kind" => "amount", "value" => bad}
                 })

        assert is_binary(message)
        assert Decimal.equal?(rate("pulsa").amount, 500)
      end

      assert {:ok, _} =
               Services.save_commission_rates(ctx.admin, %{
                 "pulsa" => %{"kind" => "amount", "value" => "1000000"},
                 "paket_data" => %{"kind" => "amount", "value" => ""}
               })

      assert Decimal.equal?(rate("pulsa").amount, 1_000_000)
      assert Decimal.equal?(rate("paket_data").amount, 0)
    end

    test "a kind that isn't one is refused", ctx do
      assert {:error, %{"pulsa" => _}} =
               Services.save_commission_rates(ctx.admin, %{
                 "pulsa" => %{"kind" => "gratis", "value" => "5"}
               })

      assert %{kind: "amount"} = rate("pulsa")
    end

    test "a cashier's service carries the amount; an admin's none", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)
      assert Decimal.equal?(tx.commission_amount, 500)
      assert Decimal.equal?(tx.commission_percent, 0)

      {:ok, serving_admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")
      assert Decimal.equal?(service_fixture(serving_admin, ctx.pulsa).commission_amount, 0)
    end

    test "the amount can't come from the caller", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa, %{"commission_amount" => "99999"})
      assert Decimal.equal?(tx.commission_amount, 500)
    end

    test "a later change leaves recorded services alone", ctx do
      tx = service_fixture(ctx.cashier, ctx.pulsa)

      {:ok, _} =
        Services.save_commission_rates(ctx.admin, %{
          "pulsa" => %{"kind" => "amount", "value" => "900"}
        })

      assert Decimal.equal?(Repo.get!(Transaction, tx.id).commission_amount, 500)
    end

    test "paid in full on success, whatever the margin; nothing otherwise" do
      with_amount = &%{tx(&1, &2, &3, "0") | commission_amount: Decimal.new(500)}

      assert Decimal.equal?(Services.commission(with_amount.("success", "12000", "10150")), 500)
      # A margin smaller than the commission, and a sale at a loss.
      assert Decimal.equal?(Services.commission(with_amount.("success", "12000", "11900")), 500)
      assert Decimal.equal?(Services.commission(with_amount.("success", "12000", "12500")), 500)

      assert Decimal.equal?(Services.commission(with_amount.("processing", "12000", "10150")), 0)
      assert Decimal.equal?(Services.commission(with_amount.("failed", "12000", "10150")), 0)
    end

    test "the report mixes both, its total the sum of its details", ctx do
      token = service_product_fixture(%{category: "token_pln"})

      for product <- [ctx.pulsa, ctx.pulsa, token] do
        {:ok, _} = Services.mark_success(service_fixture(ctx.cashier, product), ctx.cashier, nil)
      end

      today = Zahlungs.LocalTime.today()
      report = Services.commission_report(store_scope(), today, today)

      # 500 + 500 + 10% of 1.850.
      assert [%{count: 3} = row] = report.rows
      assert row.user_id == ctx.cashier.id
      assert Decimal.equal?(row.commission, 1185)
      assert Decimal.equal?(report.commission, 1185)

      details = Services.commission_details(store_scope(), ctx.cashier.id, today, today)

      assert Enum.reduce(details, Decimal.new(0), &Decimal.add(&1.commission, &2))
             |> Decimal.equal?(1185)

      assert Enum.count(details, &Decimal.equal?(&1.amount, 500)) == 2
      assert Enum.count(details, &Decimal.equal?(&1.percent, 10)) == 1

      shift = Zahlungs.Shifts.current_shift(ctx.cashier)
      assert Decimal.equal?(Services.shift_commission(shift), 1185)
    end

    test "a service at a loss still counts, and the service report's margin goes down", ctx do
      {:ok, tx} = Services.mark_success(service_fixture(ctx.cashier, ctx.pulsa), ctx.cashier, nil)

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [cost: Decimal.new(12_100)]
      )

      today = Zahlungs.LocalTime.today()

      assert [%{commission: commission}] =
               Services.commission_report(store_scope(), today, today).rows

      assert Decimal.equal?(commission, 500)

      report = Services.report(store_scope(), today, today)
      assert Decimal.equal?(report.margin, -100)
      assert Decimal.equal?(report.commission, 500)
      assert Decimal.equal?(report.net_margin, -600)
    end

    test "a bill of 3 months is one commission", _ctx do
      assign_account(default_store(), api_account_fixture())
      admin = admin()

      {:ok, _} =
        Services.save_commission_rates(admin, %{
          "tagihan" => %{"kind" => "amount", "value" => "2000"}
        })

      cashier = user_on_shift_fixture()
      bill = api_product_fixture()

      # The fake bills 3 months when the second-to-last digit is 3, and pays.
      {:ok, inquiry} = Services.inquire(cashier, bill.id, "530011223331")

      {:ok, tx} =
        Services.record(cashier, bill.id, %{"inquiry_id" => inquiry.id, "amount_paid" => "750000"})

      tx = Repo.get!(Transaction, tx.id)
      assert {tx.status, tx.sheets} == {"success", 3}
      assert Decimal.equal?(Services.commission(tx), 2000)
    end
  end

  describe "commission/1" do
    defp tx(status, price, cost, percent) do
      %Transaction{
        status: status,
        price: Decimal.new(price),
        cost: Decimal.new(cost),
        commission_percent: Decimal.new(percent)
      }
    end

    test "a percent of a successful service's margin, rounded down to the rupiah" do
      assert Decimal.equal?(Services.commission(tx("success", "12000", "10150", "10")), 185)
      assert Decimal.equal?(Services.commission(tx("success", "12000", "10001", "12.5")), 249)
    end

    test "nothing for a service that isn't successful, or sold at a loss" do
      assert Decimal.equal?(Services.commission(tx("processing", "12000", "10150", "10")), 0)
      assert Decimal.equal?(Services.commission(tx("failed", "12000", "10150", "10")), 0)
      assert Decimal.equal?(Services.commission(tx("success", "12000", "12500", "10")), 0)
    end
  end
end
