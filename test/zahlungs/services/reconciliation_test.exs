defmodule Zahlungs.Services.ReconciliationTest do
  @moduledoc """
  Matching a deposit account's api services with SBI's transaction history.
  Every value here is made up.
  """
  use ExUnit.Case, async: true

  alias Zahlungs.Services.{Reconciliation, Transaction}

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
end
