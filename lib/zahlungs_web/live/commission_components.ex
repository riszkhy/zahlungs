defmodule ZahlungsWeb.CommissionComponents do
  @moduledoc """
  Pieces shared by the admin's commission report and the cashier's own page:
  the date filter and the list of services behind a commission.
  """
  use Phoenix.Component

  import ZahlungsWeb.CoreComponents

  alias Zahlungs.{LocalTime, Services}

  @doc "The from–to date filter; sends `filter` with ISO dates."
  attr :from, :string, required: true
  attr :to, :string, required: true

  def date_filter(assigns) do
    ~H"""
    <form phx-change="filter" class="mt-6 flex flex-wrap items-end gap-3">
      <label class="text-sm">Dari <input type="date" name="from" value={@from} class="form-control" /></label>
      <label class="text-sm">Sampai <input type="date" name="to" value={@to} class="form-control" /></label>
    </form>
    """
  end

  @doc "The services behind a commission (from `Services.commission_details/4`)."
  attr :id, :string, required: true
  attr :details, :list, required: true
  attr :store, :any, default: nil, doc: "for the local time"

  def details_table(assigns) do
    ~H"""
    <.table id={@id} rows={@details}>
      <:col :let={row} label="Waktu">
        {Calendar.strftime(LocalTime.to_local(row.inserted_at, @store), "%d %b %Y %H:%M")}
      </:col>
      <:col :let={row} label="Kode">{row.code}</:col>
      <:col :let={row} label="Produk">{row.product_name} <span class="text-gray-500">· {category_label(row.category)}</span></:col>
      <:col :let={row} label="Margin">{format_money(row.margin)}</:col>
      <:col :let={row} label="Aturan">{rule(row)}</:col>
      <:col :let={row} label="Komisi">{format_money(row.commission)}</:col>
    </.table>
    """
  end

  @doc "The dates of a filter, or `:error` when either isn't a date."
  def parse_range(from, to) do
    with {:ok, from} <- Date.from_iso8601(from || ""),
         {:ok, to} <- Date.from_iso8601(to || "") do
      {:ok, from, to}
    else
      _ -> :error
    end
  end

  # What a service earned by: one of the two is 0.
  defp rule(%{amount: amount, percent: percent}) do
    if Decimal.gt?(amount, 0),
      do: format_price(amount),
      else: "#{Decimal.to_string(Decimal.normalize(percent), :normal)}%"
  end

  defp category_label(category) do
    Enum.find_value(Services.categories(), category, fn {value, label} ->
      if value == category, do: label
    end)
  end
end
