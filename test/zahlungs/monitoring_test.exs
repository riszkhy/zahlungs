defmodule Zahlungs.MonitoringTest do
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.Accounts.UserLogin
  alias Zahlungs.{Deposits, LocalTime, Monitoring, Sales}
  alias Zahlungs.Organizations.Organization
  alias Zahlungs.Sales.Sale
  alias Zahlungs.Services.Transaction

  @now ~N[2026-11-05 12:00:00]
  @today ~D[2026-11-05]

  defp ago(seconds), do: NaiveDateTime.add(@now, -seconds)

  defp org(attrs), do: struct(%Organization{status: "active"}, attrs)

  # An organization of its own with a store, a cashier on a shift, and what a
  # service needs (a deposit account and a product).
  defp shop(attrs \\ []) do
    org = organization_fixture(attrs)

    in_org(org, fn ->
      store = store_fixture()
      cashier = user_fixture(store_id: store.id)
      shift = shift_fixture(cashier)
      account = deposit_account_fixture()
      store = assign_account(store, account)
      product = service_product_fixture()

      %{
        org: org,
        store: store,
        cashier: cashier,
        shift: shift,
        account: account,
        product: product
      }
    end)
  end

  defp sale!(ctx, attrs) do
    attrs = Map.new(attrs)

    Repo.insert!(%Sale{
      store_id: ctx.store.id,
      shift_id: ctx.shift.id,
      user_id: ctx.cashier.id,
      code: "S#{System.unique_integer([:positive])}",
      total: Decimal.new(Map.get(attrs, :total, "0")),
      status: Map.get(attrs, :status, "completed"),
      inserted_at: attrs.at,
      updated_at: attrs.at
    })
  end

  defp service!(ctx, attrs) do
    attrs = Map.new(attrs)

    Repo.insert!(%Transaction{
      store_id: ctx.store.id,
      shift_id: ctx.shift.id,
      user_id: ctx.cashier.id,
      service_product_id: ctx.product.id,
      deposit_account_id: ctx.account.id,
      code: "J#{System.unique_integer([:positive])}",
      category: "pulsa",
      product_name: "Pulsa Uji",
      customer_ref: "0899",
      price: Decimal.new(Map.get(attrs, :price, "0")),
      cost: Decimal.new(Map.get(attrs, :cost, "0")),
      amount_paid: Decimal.new(0),
      status: Map.get(attrs, :status, "success"),
      channel: Map.get(attrs, :channel, "manual"),
      refunded_at: attrs[:refunded_at],
      review_reason: attrs[:review_reason],
      corrected_at: attrs[:corrected_at],
      inserted_at: attrs.at,
      updated_at: attrs.at
    })
  end

  defp top_up!(ctx, amount) do
    {:ok, _entry} =
      in_org(ctx.org, fn ->
        Deposits.record_correction(ctx.cashier, ctx.account, %{
          "amount" => amount,
          "note" => "Uji"
        })
      end)
  end

  defp admin_login!(ctx, attrs) do
    attrs = Map.new(attrs)

    Repo.insert!(%UserLogin{
      organization_id: ctx.org.id,
      user_id: ctx.cashier.id,
      store_id: attrs.store_id,
      inserted_at: attrs.at
    })
  end

  # Without a current organization, as on the superadmin's page: a query that
  # forgot skip_org_id raises here instead of being quietly filtered.
  defp without_org(fun) do
    previous = Repo.get_org_id()
    Repo.put_org_id(nil)

    try do
      fun.()
    after
      Repo.put_org_id(previous)
    end
  end

  defp overview(days \\ 30), do: without_org(fn -> Monitoring.overview(days, @now) end)

  defp row_of(overview, org), do: Enum.find(overview.rows, &(&1.organization.id == org.id))

  describe "activity/2" do
    test "the edge of a band belongs to the more active one" do
      assert Monitoring.activity(ago(7 * 86_400), @now) == :active
      assert Monitoring.activity(ago(7 * 86_400 + 1), @now) == :quiet
      assert Monitoring.activity(ago(30 * 86_400), @now) == :quiet
      assert Monitoring.activity(ago(30 * 86_400 + 1), @now) == :asleep
    end

    test "no transaction at all is never" do
      assert Monitoring.activity(nil, @now) == :never
    end
  end

  describe "billing/2" do
    test "an active organization by its paid-until date" do
      assert Monitoring.billing(org(paid_until: nil), @today) == :unrecorded
      assert Monitoring.billing(org(paid_until: ~D[2026-11-04]), @today) == :overdue
      assert Monitoring.billing(org(paid_until: ~D[2026-11-05]), @today) == :due_soon
      assert Monitoring.billing(org(paid_until: ~D[2026-11-12]), @today) == :due_soon
      assert Monitoring.billing(org(paid_until: ~D[2026-11-13]), @today) == :ok
    end

    test "an organization that isn't active has no billing state" do
      for status <- ~w(pending suspended rejected) do
        assert Monitoring.billing(org(status: status, paid_until: ~D[2026-01-01]), @today) == nil
      end
    end
  end

  test "the wait before a service counts as stuck has one source" do
    assert Zahlungs.Services.settle_by_hand_after() == 600
  end

  describe "overview/2 figures" do
    test "runs without a current organization and reads every organization" do
      a = shop()
      b = shop()
      sale!(a, total: "1000", at: ago(3600))
      sale!(b, total: "2000", at: ago(3600))

      overview = overview()

      assert Decimal.equal?(row_of(overview, a.org).sales_total, 1000)
      assert Decimal.equal?(row_of(overview, b.org).sales_total, 2000)
      assert [%{id: id}] = row_of(overview, a.org).stores
      assert id == a.store.id
      assert overview.at == @now
    end

    test "only completed sales count, from the start of the window to now" do
      a = shop()
      sale!(a, total: "100", at: ago(30 * 86_400))
      sale!(a, total: "10", at: ago(30 * 86_400 + 1))
      sale!(a, total: "7", at: NaiveDateTime.add(@now, 1))
      sale!(a, total: "1000", status: "returned", at: ago(3600))
      sale!(a, total: "1000", status: "void", at: ago(3600))

      row = row_of(overview(30), a.org)
      assert Decimal.equal?(row.sales_total, 100)
      assert row.sales_count == 1
      assert row_of(overview(7), a.org).sales_count == 0
    end

    test "goods revenue follows the sales report's rule, also with the current time" do
      org = default_org()
      cashier = user_on_shift_fixture()
      product = product_fixture(price: Decimal.new("1000"), stock: 10)

      sell = fn ->
        {:ok, sale} =
          Sales.create_sale(cashier, [%{product_id: product.id, quantity: 1}], %{
            amount_paid: "100000"
          })

        sale
      end

      sell.()
      {:ok, _returned} = Sales.return_sale(sell.())

      today = LocalTime.today(default_store())
      revenue = Sales.sales_report(store_scope(), today, today).revenue
      row = row_of(without_org(fn -> Monitoring.overview(30) end), org)

      assert Decimal.equal?(revenue, 1000)
      assert Decimal.equal?(row.sales_total, revenue)
    end

    test "only successful services count, by what the customer paid" do
      a = shop()
      service!(a, price: "500", status: "success", at: ago(3600))
      service!(a, price: "70", status: "processing", at: ago(3600))
      service!(a, price: "70", status: "failed", at: ago(3600))

      row = row_of(overview(), a.org)
      assert Decimal.equal?(row.services_total, 500)
      assert row.services_count == 1
    end

    test "any sale or service, whatever its status, is a last transaction" do
      a = shop()
      sale!(a, status: "void", at: ago(3 * 86_400))
      service!(a, status: "failed", at: ago(9 * 86_400))
      row = row_of(overview(), a.org)
      assert row.last_transaction_at == ago(3 * 86_400)
      assert row.activity == :active

      b = shop()
      sale!(b, at: ago(9 * 86_400))
      service!(b, status: "failed", at: ago(3 * 86_400))
      assert row_of(overview(), b.org).last_transaction_at == ago(3 * 86_400)
    end

    test "a closed store has no activity and isn't counted as quiet, but its money counts" do
      a = shop()
      closed = in_org(a.org, fn -> store_fixture(active: false) end)
      sale!(%{a | store: closed}, total: "300", at: ago(3600))

      row = row_of(overview(), a.org)
      assert %{activity: nil, active: false} = Enum.find(row.stores, &(&1.id == closed.id))
      assert row.active_stores == 1
      # The open store, which has no transaction.
      assert row.quiet_stores == 1
      assert Decimal.equal?(row.sales_total, 300)
    end

    test "an organization without a store appears with zeros" do
      org = organization_fixture()
      row = row_of(overview(), org)
      assert row.stores == []
      assert row.activity == :never
      assert row.sales_count == 0
      assert row.services_count == 0
      assert Decimal.equal?(row.sales_total, 0)
      assert Decimal.equal?(row.services_total, 0)
    end

    test "billing is worked out on the local date of the given time" do
      a = shop(paid_until: ~D[2026-11-05])
      b = shop(paid_until: ~D[2026-11-04])
      overview = overview()
      assert row_of(overview, a.org).billing == :due_soon
      assert row_of(overview, b.org).billing == :overdue
    end

    test "open shifts are counted per store and summed" do
      a = shop()
      other = in_org(a.org, fn -> store_fixture() end)

      in_org(a.org, fn ->
        shift_fixture(user_fixture(store_id: other.id))
      end)

      row = row_of(overview(), a.org)
      assert row.open_shifts == 2
      assert Enum.map(row.stores, & &1.open_shifts) == [1, 1]
    end

    test "a login without a store counts for the organization only" do
      a = shop()
      admin_login!(a, store_id: nil, at: ago(3600))
      row = row_of(overview(), a.org)
      assert row.last_login_at == ago(3600)
      assert hd(row.stores).last_login_at == nil
    end

    test "a login at a store counts for the store and the organization" do
      a = shop()
      admin_login!(a, store_id: a.store.id, at: ago(7200))
      row = row_of(overview(), a.org)
      assert row.last_login_at == ago(7200)
      assert hd(row.stores).last_login_at == ago(7200)
    end
  end

  describe "overview/2 problems" do
    test "an api service is stuck from ten minutes, a manual one never" do
      a = shop()
      service!(a, channel: "api", status: "processing", at: ago(599))
      row = row_of(overview(), a.org)
      assert row.stuck == 0
      refute row.problem?

      service!(a, channel: "api", status: "processing", at: ago(600))
      service!(a, channel: "manual", status: "processing", at: ago(86_400))
      row = row_of(overview(), a.org)
      assert row.stuck == 1
      assert hd(row.stores).stuck == 1
      assert row.problem?
    end

    test "a manual service failed by a correction is due a refund too" do
      a = shop()
      service!(a, channel: "manual", status: "failed", corrected_at: ago(60), at: ago(3600))

      assert row_of(overview(), a.org).refunds_due == 1
    end

    test "a failed api service is due a refund until refunded, unless in review" do
      a = shop()
      service!(a, channel: "api", status: "failed", at: ago(3600))
      service!(a, channel: "api", status: "failed", refunded_at: ago(60), at: ago(3600))
      service!(a, channel: "manual", status: "failed", at: ago(3600))
      service!(a, channel: "api", status: "failed", review_reason: "Uji", at: ago(3600))

      row = row_of(overview(), a.org)
      assert row.refunds_due == 1
      assert row.in_review == 1
      assert hd(row.stores).refunds_due == 1
      assert hd(row.stores).in_review == 1
      assert row.problem?
    end

    test "a balance is the same as the deposit page's estimate" do
      a = shop()
      top_up!(a, "1000")
      service!(a, cost: "300", status: "success", at: ago(3600))
      service!(a, cost: "200", status: "processing", at: ago(3600))
      service!(a, cost: "999", status: "failed", at: ago(3600))

      [deposit] = row_of(overview(), a.org).deposits
      expected = in_org(a.org, fn -> Deposits.estimated_balance(a.account) end)
      assert deposit.id == a.account.id
      assert deposit.name == a.account.name
      assert Decimal.equal?(expected, 500)
      assert Decimal.equal?(deposit.balance, expected)
    end

    test "only a balance below zero counts" do
      a = shop()
      row = row_of(overview(), a.org)
      assert row.negative_deposits == 0
      refute row.problem?

      service!(a, cost: "1", status: "success", at: ago(3600))
      row = row_of(overview(), a.org)
      assert row.negative_deposits == 1
      assert row.problem?
    end

    test "an inactive account is neither listed nor counted" do
      a = shop()
      service!(a, cost: "1", status: "success", at: ago(3600))
      {:ok, _} = in_org(a.org, fn -> Deposits.update_account(a.account, %{active: false}) end)

      row = row_of(overview(), a.org)
      assert row.deposits == []
      assert row.negative_deposits == 0
    end

    test "an account two stores share counts once" do
      a = shop()
      other = in_org(a.org, fn -> assign_account(store_fixture(), a.account) end)
      service!(a, cost: "1", status: "success", at: ago(3600))
      service!(%{a | store: other}, cost: "1", status: "success", at: ago(3600))

      row = row_of(overview(), a.org)
      assert [deposit] = row.deposits
      assert Decimal.equal?(deposit.balance, -2)
      assert row.negative_deposits == 1
    end

    test "one organization's problems and accounts stay its own" do
      a = shop()
      b = shop()
      service!(a, channel: "api", status: "processing", cost: "5", at: ago(3600))

      overview = overview()
      assert row_of(overview, a.org).stuck == 1
      refute row_of(overview, b.org).problem?
      assert [%{id: id}] = row_of(overview, b.org).deposits
      assert id == b.account.id
    end
  end

  describe "overview/2 order and summary" do
    test "what needs handling comes first, then by name in any case" do
      problem = shop(name: "Zeta")
      service!(problem, channel: "api", status: "processing", at: ago(3600))
      overdue = shop(name: "Yota", paid_until: ~D[2026-11-04])
      asleep = shop(name: "Xeno")
      sale!(asleep, at: ago(31 * 86_400))
      quiet = shop(name: "Wira")
      sale!(quiet, at: ago(8 * 86_400))
      busy_b = shop(name: "Beta")
      sale!(busy_b, at: ago(3600))
      busy_a = shop(name: "alfa")
      sale!(busy_a, at: ago(3600))

      ids = Enum.map(overview().rows, & &1.organization.id)
      wanted = Enum.map([problem, overdue, asleep, quiet, busy_a, busy_b], & &1.org.id)

      assert Enum.filter(ids, &(&1 in wanted)) == wanted
    end

    test "the same name falls back to the id" do
      first = organization_fixture(name: "Kembar")
      second = organization_fixture(name: "Kembar")

      ids = Enum.map(overview().rows, & &1.organization.id)

      assert Enum.filter(ids, &(&1 in [first.id, second.id])) == [first.id, second.id]
    end

    test "the summary covers active organizations only" do
      before = overview().summary

      a = shop()
      sale!(a, total: "100", at: ago(3600))
      service!(a, price: "40", status: "success", at: ago(3600))

      for status <- ~w(pending suspended rejected) do
        other = shop(status: status, paid_until: ~D[2020-01-01])
        sale!(other, total: "9000", at: ago(3600))
        service!(other, channel: "api", status: "processing", at: ago(3600))
      end

      shop(paid_until: ~D[2020-01-01])
      troubled = shop()
      service!(troubled, channel: "api", status: "processing", at: ago(3600))

      now = overview().summary
      assert now.active_organizations - before.active_organizations == 3
      assert Decimal.equal?(Decimal.sub(now.sales_total, before.sales_total), 100)
      assert Decimal.equal?(Decimal.sub(now.services_total, before.services_total), 40)
      assert now.overdue - before.overdue == 1
      assert now.with_problems - before.with_problems == 1
    end

    test "the summary follows the chosen period" do
      a = shop()
      before = {overview(7).summary, overview(30).summary}
      sale!(a, total: "100", at: ago(10 * 86_400))
      {before_7, before_30} = before

      assert Decimal.equal?(overview(7).summary.sales_total, before_7.sales_total)

      assert Decimal.equal?(
               Decimal.sub(overview(30).summary.sales_total, before_30.sales_total),
               100
             )
    end
  end

  describe "filter/2" do
    defp listed(name, attrs \\ []) do
      %{
        organization: %Organization{name: name, status: Keyword.get(attrs, :status, "active")},
        activity: Keyword.get(attrs, :activity, :active),
        billing: Keyword.get(attrs, :billing, :ok),
        problem?: Keyword.get(attrs, :problem?, false)
      }
    end

    defp names(rows), do: Enum.map(rows, & &1.organization.name)

    test "status: one, every, or an unknown value means every" do
      rows = [listed("Alfa"), listed("Beta", status: "suspended")]

      assert names(Monitoring.filter(rows, status: "active")) == ["Alfa"]
      assert names(Monitoring.filter(rows, status: "suspended")) == ["Beta"]
      assert Monitoring.filter(rows, status: "") == rows
      assert Monitoring.filter(rows, status: "entah") == rows
    end

    test "quick quiet takes quiet, asleep and never; not active" do
      rows = [
        listed("Aktif"),
        listed("Sepi", activity: :quiet),
        listed("Tidur", activity: :asleep),
        listed("Belum", activity: :never)
      ]

      assert names(Monitoring.filter(rows, quick: "quiet")) == ["Sepi", "Tidur", "Belum"]
    end

    test "quick billing takes overdue, due soon and unrecorded; not ok or no billing" do
      rows = [
        listed("Beres"),
        listed("Lewat", billing: :overdue),
        listed("Segera", billing: :due_soon),
        listed("Kosong", billing: :unrecorded),
        listed("Tangguh", billing: nil, status: "suspended")
      ]

      assert names(Monitoring.filter(rows, quick: "billing")) == ["Lewat", "Segera", "Kosong"]
    end

    test "quick problems takes only organizations with a problem" do
      rows = [listed("Beres"), listed("Masalah", problem?: true)]

      assert names(Monitoring.filter(rows, quick: "problems")) == ["Masalah"]
    end

    test "an empty or unknown quick means no such filter" do
      rows = [listed("Beres"), listed("Masalah", problem?: true)]

      assert Monitoring.filter(rows, quick: "") == rows
      assert Monitoring.filter(rows, quick: "entah") == rows
    end

    test "search: part of the name, any case; % and _ are text" do
      rows = [listed("Alfa Mart"), listed("Beta")]

      assert names(Monitoring.filter(rows, search: "aLf")) == ["Alfa Mart"]
      assert Monitoring.filter(rows, search: "%") == []
      assert Monitoring.filter(rows, search: "_") == []
    end

    test "search: edge spaces are ignored and only spaces is no search" do
      rows = [listed("Alfa Mart"), listed("Beta")]

      assert names(Monitoring.filter(rows, search: "  alf ")) == ["Alfa Mart"]
      assert names(Monitoring.filter(rows, search: "a m")) == ["Alfa Mart"]
      assert Monitoring.filter(rows, search: "   ") == rows
    end

    test "filters combine, and keep the order" do
      rows = [
        listed("Zeta", problem?: true),
        listed("Alfa", problem?: true),
        listed("Mira", problem?: true, status: "suspended"),
        listed("Beta")
      ]

      filtered = Monitoring.filter(rows, status: "active", quick: "problems", search: "a")

      assert names(filtered) == ["Zeta", "Alfa"]
    end
  end
end
