defmodule ZahlungsWeb.AmountInput do
  @moduledoc """
  Reads a rupiah amount as people type it: dots between thousands and a comma
  before the cents ("245.000" or "245.000,00"). Dropping every non-digit
  instead would read "245.000,00" as 24.500.000.
  """

  @doc """
  The amount as a plain decimal string for the contexts: "245.000,50" →
  "245000.50", "Rp 12.000" → "12000", "" → "".
  """
  def parse(value) when is_binary(value) do
    case value |> String.replace(~r/[^\d,]/, "") |> String.split(",") do
      [whole] ->
        whole

      [whole, cents | _] ->
        if cents == "", do: whole, else: whole <> "." <> String.slice(cents, 0, 2)
    end
  end

  def parse(_value), do: ""
end
