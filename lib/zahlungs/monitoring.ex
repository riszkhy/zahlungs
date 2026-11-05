defmodule Zahlungs.Monitoring do
  @moduledoc """
  The platform operator's view of every organization: is it still in use, how
  big is its business, should it be billed, and do its services have a problem.

  This is the one place monitoring reads across organizations, reachable only
  from the `/platform` pages. It writes nothing and calls no provider.
  """

  alias Zahlungs.Organizations.Organization

  @quiet_after 7 * 86_400
  @asleep_after 30 * 86_400
  @due_soon_days 7

  @doc """
  How recently an organization or store was used, from its last transaction:
  `:active`, `:quiet`, `:asleep`, or `:never`. Counted in hours, so it doesn't
  depend on a store's time zone; the edge of a band belongs to the more active one.
  """
  def activity(nil, _now), do: :never

  def activity(%NaiveDateTime{} = last_at, %NaiveDateTime{} = now) do
    case NaiveDateTime.diff(now, last_at) do
      waited when waited <= @quiet_after -> :active
      waited when waited <= @asleep_after -> :quiet
      _waited -> :asleep
    end
  end

  @doc """
  Where an active organization stands with its bill: `:unrecorded`, `:overdue`,
  `:due_soon` (today up to a week ahead) or `:ok`; `nil` for any other status.
  """
  def billing(%Organization{status: "active", paid_until: nil}, _today), do: :unrecorded

  def billing(%Organization{status: "active", paid_until: %Date{} = paid_until}, today) do
    cond do
      Date.compare(paid_until, today) == :lt -> :overdue
      Date.compare(paid_until, Date.add(today, @due_soon_days)) != :gt -> :due_soon
      true -> :ok
    end
  end

  def billing(%Organization{}, _today), do: nil
end
