defmodule Zahlungs.LocalTime do
  @moduledoc """
  Shop-local time helpers.

  Timestamps are stored in UTC. "Today", report date ranges, and anything shown
  to a person must use the shop's wall clock instead, otherwise a sale made at
  06:00 WIB lands on the previous day.

  The shop's zone is a fixed UTC offset in hours (`config :zahlungs,
  :utc_offset_hours`, default `7` = WIB). Indonesia has no daylight saving, so a
  fixed offset is exact and no time zone database is needed.
  """

  @doc "The configured UTC offset in seconds."
  def offset_seconds, do: Application.get_env(:zahlungs, :utc_offset_hours, 7) * 3600

  @doc "The current shop-local time."
  def now, do: to_local(NaiveDateTime.utc_now())

  @doc "The current shop-local date."
  def today, do: NaiveDateTime.to_date(now())

  @doc "Converts a stored UTC timestamp to shop-local time, for display."
  def to_local(nil), do: nil
  def to_local(%NaiveDateTime{} = utc), do: NaiveDateTime.add(utc, offset_seconds())
  def to_local(%DateTime{} = utc), do: utc |> DateTime.to_naive() |> to_local()

  @doc """
  The UTC `{start, finish}` timestamps covering the inclusive range of
  shop-local dates, for filtering stored (UTC) timestamps.
  """
  def day_range(%Date{} = date_from, %Date{} = date_to) do
    {to_utc(NaiveDateTime.new!(date_from, ~T[00:00:00])),
     to_utc(NaiveDateTime.new!(date_to, ~T[23:59:59]))}
  end

  defp to_utc(%NaiveDateTime{} = local), do: NaiveDateTime.add(local, -offset_seconds())
end
