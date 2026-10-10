defmodule Zahlungs.LocalTime do
  @moduledoc """
  Shop-local time helpers.

  Timestamps are stored in UTC. "Today", report date ranges, and anything shown
  to a person must use the shop's wall clock instead, otherwise a sale made at
  06:00 WIB lands on the previous day.

  A time zone is a fixed UTC offset in hours — Indonesia has no daylight saving,
  so that is exact and no time zone database is needed. Each store has its own
  (`stores.utc_offset_hours`); every function takes the store as its last
  argument. Without one (an admin looking at all stores) the default applies:
  `config :zahlungs, :utc_offset_hours`, `7` = WIB.
  """

  alias Zahlungs.Stores.Store

  @doc "The UTC offset in seconds of the store, or the default one for nil."
  def offset_seconds(store \\ nil)
  def offset_seconds(%Store{utc_offset_hours: hours}), do: hours * 3600
  # nil, or an association that wasn't loaded: fall back to the default zone.
  def offset_seconds(_no_store), do: Application.get_env(:zahlungs, :utc_offset_hours, 7) * 3600

  @doc "The current shop-local time."
  def now(store \\ nil), do: to_local(NaiveDateTime.utc_now(), store)

  @doc "The current shop-local date."
  def today(store \\ nil), do: NaiveDateTime.to_date(now(store))

  @doc "Converts a stored UTC timestamp to shop-local time, for display."
  def to_local(utc, store \\ nil)
  def to_local(nil, _store), do: nil

  def to_local(%NaiveDateTime{} = utc, store),
    do: NaiveDateTime.add(utc, offset_seconds(store))

  def to_local(%DateTime{} = utc, store), do: utc |> DateTime.to_naive() |> to_local(store)

  @doc """
  The UTC `{start, finish}` timestamps covering the inclusive range of
  shop-local dates, for filtering stored (UTC) timestamps.
  """
  def day_range(%Date{} = date_from, %Date{} = date_to, store \\ nil) do
    offset = offset_seconds(store)

    {NaiveDateTime.add(NaiveDateTime.new!(date_from, ~T[00:00:00]), -offset),
     NaiveDateTime.add(NaiveDateTime.new!(date_to, ~T[23:59:59]), -offset)}
  end
end
