defmodule Zahlungs.Services.TokenAnswer do
  @moduledoc """
  Reads what a token PLN's serial number holds at SBI: one text, `token/owner/
  tariff/power/kWh`. Only to show it; `token_sn` keeps the whole answer.

  Only that exact shape is read: a token of 20 digits and five parts. Anything
  else is `nil`, and is shown as it came, so a token is never lost to a format
  not seen yet.
  """

  @doc "`%{token, name, tariff, kwh}` (a blank part is `nil`), or `nil`."
  def parse(answer) when is_binary(answer) do
    with [token, name, tariff, power, kwh] <-
           answer |> String.split("/") |> Enum.map(&String.trim/1),
         digits = String.replace(token, ~r/[\s\-]/, ""),
         true <- digits =~ ~r/^\d{20}$/ do
      %{
        token: digits,
        name: blank_to_nil(name),
        tariff: [tariff, power] |> Enum.reject(&(&1 == "")) |> Enum.join("/") |> blank_to_nil(),
        kwh: kwh(kwh)
      }
    else
      _ -> nil
    end
  end

  def parse(_answer), do: nil

  defp kwh(text) do
    case Regex.run(~r/^([\d.,]+)\s*kwh$/i, text) do
      [_, amount] -> amount <> " kWh"
      _ -> blank_to_nil(text)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
