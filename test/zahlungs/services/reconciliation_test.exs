defmodule Zahlungs.Services.ReconciliationTest do
  @moduledoc """
  Matching a deposit account's api services with SBI's transaction history.
  Every value here is made up.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.{AccountsFixtures, ServicesFixtures, ShiftsFixtures, StoresFixtures}

  alias Zahlungs.Services
  alias Zahlungs.Services.{Reconciliation, Transaction}
  alias Zahlungs.Services.Provider.Sbi.StubClient

  defp d(value), do: Decimal.new(value)

  defp ours(attrs \\ []) do
    struct(
      %Transaction{
        id: System.unique_integer([:positive]),
        channel: "api",
        status: "processing",
        ref_id: "Z1",
        sent_at: ~N[2026-11-12 03:00:01],
        cost: d(5150),
        inserted_at: ~N[2026-11-12 03:00:00]
      },
      attrs
    )
  end

  defp theirs(attrs \\ []) do
    Map.merge(
      %{
        ref: "Z1",
        status: :success,
        inquiry?: false,
        cost: d(5150),
        product_code: "T5",
        customer_id: "089900001111",
        at: ~N[2026-11-12 03:00:05]
      },
      Map.new(attrs)
    )
  end

  defp kind(ours, theirs), do: Reconciliation.classify(ours, theirs).kind

  describe "classify/2" do
    test "the same final status is a match" do
      assert kind(ours(status: "success"), theirs(status: :success)) == :matched
      assert kind(ours(status: "success"), theirs(status: :success, cost: nil)) == :matched
      assert kind(ours(status: "failed"), theirs(status: :failed)) == :matched
      assert kind(ours(status: "failed"), theirs(status: :refunded)) == :matched
      assert kind(ours(status: "processing"), theirs(status: :pending)) == :matched
    end

    test "a service still processing follows SBI's final status" do
      for status <- [:success, :failed, :refunded] do
        assert kind(ours(status: "processing"), theirs(status: status)) == :follow
      end
    end

    test "opposite final statuses are a conflict" do
      assert kind(ours(status: "success"), theirs(status: :failed)) == :conflict
      assert kind(ours(status: "success"), theirs(status: :refunded)) == :conflict
      assert kind(ours(status: "failed"), theirs(status: :success)) == :conflict
    end

    test "final here, still pending at SBI" do
      assert kind(ours(status: "success"), theirs(status: :pending)) == :pending_there
      assert kind(ours(status: "failed"), theirs(status: :pending)) == :pending_there
    end

    test "both successful at a different cost" do
      assert kind(ours(status: "success"), theirs(status: :success, cost: d(5200))) == :cost_diff
    end

    test "only on one side" do
      assert kind(ours(status: "success"), nil) == :ours_only
      assert kind(ours(status: "processing"), nil) == :ours_only
      assert kind(nil, theirs()) == :theirs_only
      assert kind(nil, theirs(status: :failed)) == :theirs_only
    end

    test "a service in review keeps its kind and is marked" do
      row =
        Reconciliation.classify(
          ours(status: "success", review_reason: "Uji"),
          theirs(status: :failed)
        )

      assert %{kind: :conflict, in_review?: true, ref: "Z1"} = row

      refute Reconciliation.classify(ours(status: "success"), theirs()).in_review?
    end
  end

  describe "compare/3" do
    test "inquiry rows are left out" do
      bill = ours(ref_id: "Q1", status: "success")

      day = [
        theirs(ref: "Q1", inquiry?: true, status: :success, at: ~N[2026-11-12 02:59:00]),
        theirs(ref: "Q1", status: :success, at: ~N[2026-11-12 03:00:05])
      ]

      assert %{rows: [%{kind: :matched, ref: "Q1"}]} = Reconciliation.compare([bill], day, [])

      assert %{rows: []} =
               Reconciliation.compare([], [theirs(ref: "Q2", inquiry?: true)], [])
    end

    test "the latest of two rows for one ref is used" do
      day = [
        theirs(status: :success, at: ~N[2026-11-12 03:10:00]),
        theirs(status: :failed, at: ~N[2026-11-12 03:00:05])
      ]

      assert %{rows: [%{kind: :matched, theirs: %{status: :success}}]} =
               Reconciliation.compare([ours(status: "success")], day, [])
    end

    test "a service never sent is left out" do
      assert %{rows: []} = Reconciliation.compare([ours(sent_at: nil, ref_id: "Z9")], [], [])
    end

    test "the next day only finds ours" do
      next_day = [
        theirs(ref: "Z1", status: :success, at: ~N[2026-11-12 17:00:30]),
        theirs(ref: "Z7", status: :success)
      ]

      assert %{rows: [%{kind: :follow, ref: "Z1"}]} =
               Reconciliation.compare([ours()], [], next_day)
    end

    test "a blank ref never matches" do
      %{rows: rows} =
        Reconciliation.compare([ours(ref_id: nil, status: "success")], [theirs(ref: nil)], [])

      assert rows |> Enum.map(& &1.kind) |> Enum.sort() == [:ours_only, :theirs_only]
      assert Enum.all?(rows, &(is_nil(&1.ours) or is_nil(&1.theirs)))
    end

    test "unmatched first, by kind then time" do
      services = [
        ours(ref_id: "A", status: "success"),
        ours(ref_id: "B", status: "processing", inserted_at: ~N[2026-11-12 05:00:00]),
        ours(ref_id: "C", status: "processing", inserted_at: ~N[2026-11-12 04:00:00]),
        ours(ref_id: "D", status: "success"),
        ours(ref_id: "E", status: "success")
      ]

      day = [
        theirs(ref: "A", status: :success),
        theirs(ref: "B", status: :success),
        theirs(ref: "C", status: :failed),
        theirs(ref: "D", status: :failed),
        theirs(ref: "F", status: :success)
      ]

      %{rows: rows} = Reconciliation.compare(services, day, [])

      assert Enum.map(rows, &{&1.kind, &1.ref}) == [
               {:follow, "C"},
               {:follow, "B"},
               {:conflict, "D"},
               {:ours_only, "E"},
               {:theirs_only, "F"},
               {:matched, "A"}
             ]
    end
  end

  describe "summarize/1" do
    test "counts every kind and adds up the money" do
      rows = [
        Reconciliation.classify(ours(status: "success"), theirs(cost: d(5200))),
        Reconciliation.classify(
          ours(ref_id: "Z2", status: "success", cost: d(1000)),
          theirs(ref: "Z2", cost: d(900))
        ),
        Reconciliation.classify(nil, theirs(ref: "Z3", cost: d(2000))),
        Reconciliation.classify(nil, theirs(ref: "Z4", status: :failed, cost: d(3000))),
        Reconciliation.classify(nil, theirs(ref: "Z5", cost: nil))
      ]

      summary = Reconciliation.summarize(rows)

      assert summary.counts == %{
               follow: 0,
               conflict: 0,
               pending_there: 0,
               ours_only: 0,
               cost_diff: 2,
               theirs_only: 3,
               matched: 0
             }

      assert Decimal.equal?(summary.cost_difference, d(-50))
      assert Decimal.equal?(summary.theirs_only_total, d(2000))
    end
  end

  ## With the database and SBI's stub

  @today ~D[2026-11-13]
  @day ~D[2026-11-12]

  defp sbi_account(attrs \\ %{}) do
    deposit_account_fixture(
      Map.merge(
        %{
          mode: "api",
          provider: "sbi",
          credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => "pw"}
        },
        attrs
      )
    )
  end

  defp setup_report(_ctx), do: report_context(default_store())

  defp report_context(store) do
    account = sbi_account()
    store = assign_account(store, account)
    cashier = user_on_shift_fixture(store_id: store.id)
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(store_id: store.id), "admin")
    product = service_product_fixture()
    shift = Zahlungs.Shifts.current_shift(cashier)

    %{
      account: account,
      store: store,
      cashier: cashier,
      admin: admin,
      product: product,
      shift: shift
    }
  end

  # An api service of the account, written directly: nothing is sent.
  defp service!(ctx, attrs) do
    n = System.unique_integer([:positive])

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
          sent_at: ~N[2026-11-12 03:00:01],
          inserted_at: ~N[2026-11-12 03:00:00],
          updated_at: ~N[2026-11-12 03:00:00],
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

  defp sbi_row(ref, status \\ 1) do
    %{
      "ref_1" => ref,
      "status" => status,
      "total_payment" => "5150",
      "created_at" => "2026-11-12 10:00:05",
      "msg" => "TRX T5.089900001111 SUKSES, HRG:5150 SN:1 REFID:#{ref}."
    }
  end

  defp page(rows, last_page \\ 1),
    do: {:ok, 200, %{"data" => %{"data" => rows, "meta" => %{"last_page" => last_page}}}}

  defp history_requests, do: for({"history", body, _} <- StubClient.requests(), do: body)

  defp kinds(rows), do: Map.new(rows, &{&1.ref, &1.kind})

  describe "reconcile/4" do
    setup :setup_report

    test "reads every page and matches by ref", ctx do
      a = service!(ctx, status: "success")
      b = service!(ctx, status: "success")

      StubClient.expect("history", page([sbi_row(a.ref_id)], 3))
      StubClient.expect("history", page([], 3))
      StubClient.expect("history", page([sbi_row(b.ref_id)], 3))

      assert {:ok, %{rows: rows, date: @day}} =
               Services.reconcile(ctx.admin, ctx.account, @day, @today)

      assert kinds(rows) == %{a.ref_id => :matched, b.ref_id => :matched}
      assert Enum.map(history_requests(), & &1["page"]) == [1, 2, 3]
      assert Enum.all?(history_requests(), &(&1["date"] == "2026-11-12"))
    end

    test "one failed page fails the whole report", ctx do
      StubClient.expect("history", page([], 2))
      StubClient.expect("history", {:error, :timeout})

      assert Services.reconcile(ctx.admin, ctx.account, @day, @today) == {:error, :unavailable}
    end

    test "more than 20 pages is refused", ctx do
      StubClient.expect("history", page([], 21))

      assert Services.reconcile(ctx.admin, ctx.account, @day, @today) == {:error, :unavailable}
      assert length(history_requests()) == 1
    end

    test "the next day is asked only when something is missing", ctx do
      a = service!(ctx, status: "success")
      StubClient.expect("history", page([sbi_row(a.ref_id)]))

      assert {:ok, _} = Services.reconcile(ctx.admin, ctx.account, @day, @today)
      assert Enum.map(history_requests(), & &1["date"]) == ["2026-11-12"]

      b = service!(ctx, status: "processing")
      StubClient.expect("history", page([sbi_row(a.ref_id)]))
      StubClient.expect("history", page([sbi_row(b.ref_id)]))

      assert {:ok, %{rows: rows}} = Services.reconcile(ctx.admin, ctx.account, @day, @today)
      assert kinds(rows)[b.ref_id] == :follow

      assert Enum.map(history_requests(), & &1["date"]) ==
               ["2026-11-12", "2026-11-12", "2026-11-13"]
    end

    test "a service of another day is matched by its ref", ctx do
      late = service!(ctx, status: "success", inserted_at: ~N[2026-11-11 16:59:00])
      StubClient.expect("history", page([sbi_row(late.ref_id)]))

      assert {:ok, %{rows: [%{kind: :matched, ours: %{id: id}}]}} =
               Services.reconcile(ctx.admin, ctx.account, @day, @today)

      assert id == late.id
    end

    test "only this account's services", ctx do
      other_account = sbi_account()
      other = service!(%{ctx | account: other_account}, status: "success")

      foreign_ref =
        in_org(organization_fixture(), fn ->
          foreign = report_context(store_fixture())
          service!(foreign, status: "success").ref_id
        end)

      StubClient.expect("history", page([sbi_row(other.ref_id), sbi_row(foreign_ref)]))

      assert {:ok, %{rows: rows}} = Services.reconcile(ctx.admin, ctx.account, @day, @today)
      assert kinds(rows) == %{other.ref_id => :theirs_only, foreign_ref => :theirs_only}
      assert Enum.all?(rows, &is_nil(&1.ours))
    end

    test "the day is the default zone's", ctx do
      first = service!(ctx, status: "success", inserted_at: ~N[2026-11-11 17:00:00])
      before = service!(ctx, status: "success", inserted_at: ~N[2026-11-11 16:59:59])
      StubClient.expect("history", page([]))
      StubClient.expect("history", page([]))

      assert {:ok, %{rows: rows}} = Services.reconcile(ctx.admin, ctx.account, @day, @today)
      assert kinds(rows) == %{first.ref_id => :ours_only}
      refute Map.has_key?(kinds(rows), before.ref_id)
    end

    test "refused before asking SBI", ctx do
      assert Services.reconcile(ctx.cashier, ctx.account, @day, @today) == {:error, :not_admin}

      assert Services.reconcile(ctx.admin, ctx.account, ~D[2026-11-14], @today) ==
               {:error, :future_date}

      manual = deposit_account_fixture()
      assert Services.reconcile(ctx.admin, manual, @day, @today) == {:error, :unsupported}

      fake = api_account_fixture()
      assert Services.reconcile(ctx.admin, fake, @day, @today) == {:error, :unsupported}

      assert StubClient.requests() == []
    end

    test "credentials that can't be read", ctx do
      account = Repo.update!(Ecto.Changeset.change(ctx.account, credentials: "x"))

      assert Services.reconcile(ctx.admin, account, @day, @today) == {:error, :credentials}
      assert StubClient.requests() == []
    end
  end

  describe "recheck_row/2" do
    setup :setup_report

    defp status_answer(ref, status) do
      {:ok, 200,
       %{
         "data" => %{
           "ref_1" => ref,
           "ref_2" => "R1",
           "status" => status,
           "total_payment" => "5150",
           "msg" =>
             if(status == 1,
               do: "TRX SUKSES SN:1 REFID:#{ref}.",
               else: "TRX GAGAL KET:Nomor salah"
             )
         }
       }}
    end

    defp row_for(service, theirs_status),
      do: Reconciliation.classify(service, theirs(ref: service.ref_id, status: theirs_status))

    test "a processing service follows SBI", ctx do
      service = service!(ctx, status: "processing")
      StubClient.expect("status", status_answer(service.ref_id, 1))

      assert {:ok, %{kind: :matched, ours: %{status: "success"}}} =
               Services.recheck_row(ctx.admin, row_for(service, :success))

      assert [{"status", %{"ref_1" => ref}, _}] = StubClient.requests()
      assert ref == service.ref_id
    end

    test "a contradiction goes to review without changing the status", ctx do
      service = service!(ctx, status: "success")
      StubClient.expect("status", status_answer(service.ref_id, 11))

      assert {:ok, %{kind: :conflict, in_review?: true, ours: %{status: "success"}}} =
               Services.recheck_row(ctx.admin, row_for(service, :failed))
    end

    test "pressed twice changes nothing more", ctx do
      service = service!(ctx, status: "processing")
      StubClient.expect("status", status_answer(service.ref_id, 11))
      StubClient.expect("status", status_answer(service.ref_id, 11))
      row = row_for(service, :failed)

      assert {:ok, first} = Services.recheck_row(ctx.admin, row)
      cash = Zahlungs.Shifts.expected_cash(ctx.shift)

      assert {:ok, second} = Services.recheck_row(ctx.admin, first)
      assert second.kind == :matched
      assert second.ours.status == "failed"
      assert is_nil(second.ours.refunded_at)
      assert Decimal.equal?(Zahlungs.Shifts.expected_cash(ctx.shift), cash)
    end

    test "SBI's final answer replaces a pending history row", ctx do
      service = service!(ctx, status: "success")
      StubClient.expect("status", status_answer(service.ref_id, 1))

      assert {:ok, %{kind: :matched, theirs: %{status: :success}}} =
               Services.recheck_row(ctx.admin, row_for(service, :pending))
    end

    test "a service missing from the history is found by its status", ctx do
      service = service!(ctx, status: "success")
      StubClient.expect("status", status_answer(service.ref_id, 1))

      assert {:ok, %{kind: :matched, theirs: %{ref: ref, status: :success}}} =
               Services.recheck_row(ctx.admin, Reconciliation.classify(service, nil))

      assert ref == service.ref_id
    end

    test "no answer keeps the row as it was", ctx do
      service = service!(ctx, status: "success")
      StubClient.expect("status", {:error, :timeout})

      assert {:ok, %{kind: :ours_only, theirs: nil}} =
               Services.recheck_row(ctx.admin, Reconciliation.classify(service, nil))
    end

    test "never sends", ctx do
      service = service!(ctx, sent_at: nil)

      assert Services.recheck_row(ctx.admin, Reconciliation.classify(service, nil)) ==
               {:error, :not_sent}

      assert StubClient.requests() == []
    end

    test "a manual service", ctx do
      service = service!(ctx, channel: "manual", ref_id: nil)

      assert Services.recheck_row(ctx.admin, Reconciliation.classify(service, nil)) ==
               {:error, :not_api}
    end

    test "a cashier", ctx do
      service = service!(ctx, status: "processing")

      assert Services.recheck_row(ctx.cashier, row_for(service, :success)) ==
               {:error, :not_admin}

      assert StubClient.requests() == []
    end

    test "another organization's service", ctx do
      foreign =
        in_org(organization_fixture(), fn ->
          service!(report_context(store_fixture()), status: "processing")
        end)

      assert_raise Ecto.NoResultsError, fn ->
        Services.recheck_row(ctx.admin, Reconciliation.classify(foreign, nil))
      end

      assert StubClient.requests() == []
    end
  end
end
