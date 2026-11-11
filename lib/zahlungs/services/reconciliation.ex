defmodule Zahlungs.Services.Reconciliation do
  @moduledoc """
  Matching one deposit account's api services with the provider's transaction
  history for one day (spec
  `docs/superpowers/specs/2026-11-12-rekonsiliasi-layanan-design.md`). Called
  through `Zahlungs.Services`.

  `classify/2`, `compare/3` and `summarize/1` are pure. Each service and each
  history row ends up in exactly one row, of one kind:

  - `:follow` — processing here, final at the provider.
  - `:conflict` — successful here and failed (or refunded) there, or the other
    way round.
  - `:pending_there` — final here, still pending at the provider.
  - `:ours_only` — sent, but not in the provider's history.
  - `:cost_diff` — successful on both sides at a different cost.
  - `:theirs_only` — a history row no service of the account has the ref of.
  - `:matched` — the same final status (and cost), or pending on both sides.

  A refund at the provider counts as a failure. Inquiry rows are left out, and
  of several rows for one ref the latest is used. Services never sent are left
  out. Nothing here changes a service: fixes go through `Services.recheck_row/2`.
  """

  alias Zahlungs.Services.Transaction

  @kinds [:follow, :conflict, :pending_there, :ours_only, :cost_diff, :theirs_only, :matched]

  @doc "The kinds, in the order rows are listed."
  def kinds, do: @kinds

  @doc """
  The rows for a day: `services` (the account's api services of that day, and
  any other of the account whose ref is in `day`), the provider's history of
  that `day`, and of the `next_day` (only used to find services of the day
  that aren't in `day`). Rows that don't match come first.
  """
  def compare(services, day, next_day) do
    services = Enum.reject(services, &is_nil(&1.sent_at))
    {day_by_ref, day_blank} = latest_by_ref(day)
    {next_by_ref, _blank} = latest_by_ref(next_day)

    ours_refs = for %{ref_id: ref} <- services, is_binary(ref), into: MapSet.new(), do: ref

    ours_rows =
      for service <- services do
        theirs =
          case service.ref_id do
            ref when is_binary(ref) -> Map.get(day_by_ref, ref) || Map.get(next_by_ref, ref)
            _ -> nil
          end

        classify(service, theirs)
      end

    theirs_rows =
      for row <- Map.values(day_by_ref) ++ day_blank,
          not MapSet.member?(ours_refs, row.ref || ""),
          do: classify(nil, row)

    rows = Enum.sort_by(ours_rows ++ theirs_rows, &sort_key/1)
    %{rows: rows, summary: summarize(rows)}
  end

  # Inquiry rows out; one row per ref, the latest (a row without a time is the
  # oldest). Rows without a ref are kept apart: they never match anything.
  defp latest_by_ref(rows) do
    rows = Enum.reject(rows, & &1.inquiry?)
    {blank, with_ref} = Enum.split_with(rows, &is_nil(&1.ref))

    by_ref =
      with_ref
      |> Enum.group_by(& &1.ref)
      |> Map.new(fn {ref, rows} -> {ref, Enum.max_by(rows, &seconds(&1.at))} end)

    {by_ref, blank}
  end

  @doc "The row for a service and its history row (either may be `nil`)."
  def classify(ours, theirs) do
    %{
      kind: kind(ours, theirs),
      ref: (ours && ours.ref_id) || (theirs && theirs.ref),
      ours: ours,
      theirs: theirs,
      in_review?: in_review?(ours)
    }
  end

  defp kind(nil, _theirs), do: :theirs_only
  defp kind(%Transaction{}, nil), do: :ours_only

  defp kind(%Transaction{status: "processing"}, %{status: :pending}), do: :matched
  defp kind(%Transaction{status: "processing"}, _theirs), do: :follow
  defp kind(%Transaction{}, %{status: :pending}), do: :pending_there

  defp kind(%Transaction{status: "success"} = ours, %{status: :success} = theirs) do
    if is_nil(theirs.cost) or (ours.cost && Decimal.equal?(ours.cost, theirs.cost)),
      do: :matched,
      else: :cost_diff
  end

  defp kind(%Transaction{status: "success"}, _failed_or_refunded), do: :conflict
  defp kind(%Transaction{status: "failed"}, %{status: :success}), do: :conflict
  defp kind(%Transaction{status: "failed"}, _failed_or_refunded), do: :matched

  defp in_review?(%Transaction{review_reason: reason}) when is_binary(reason),
    do: String.trim(reason) != ""

  defp in_review?(_ours), do: false

  @doc """
  How many rows of each kind, the cost difference (the provider's charge minus
  ours, over `:cost_diff` rows) and what the provider charged for successful
  rows that have no service here.
  """
  def summarize(rows) do
    counts = Map.new(@kinds, &{&1, 0})

    %{
      counts: Enum.reduce(rows, counts, &Map.update!(&2, &1.kind, fn n -> n + 1 end)),
      cost_difference:
        sum(for %{kind: :cost_diff} = row <- rows, do: diff(row.theirs.cost, row.ours.cost)),
      theirs_only_total:
        sum(
          for %{kind: :theirs_only, theirs: %{status: :success}} = row <- rows,
              do: row.theirs.cost
        )
    }
  end

  defp diff(theirs, ours), do: Decimal.sub(theirs || 0, ours || 0)

  defp sum(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add(&2, &1 || 0))

  defp sort_key(row) do
    time = (row.ours && row.ours.inserted_at) || (row.theirs && row.theirs.at)
    {Enum.find_index(@kinds, &(&1 == row.kind)), seconds(time), row.ref || ""}
  end

  defp seconds(nil), do: 0

  defp seconds(%NaiveDateTime{} = time),
    do: time |> NaiveDateTime.to_gregorian_seconds() |> elem(0)
end
