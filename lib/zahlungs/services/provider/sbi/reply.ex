defmodule Zahlungs.Services.Provider.Sbi.Reply do
  @moduledoc """
  Reads Smart Biller Indonesia's answers into what `Zahlungs.Services.Provider`
  promises. Pure: no network, no database.

  The rule throughout: when in doubt, **pending** — a failure means the money
  goes back to the customer, while SBI may already have charged the deposit.

  - `status` 1 is success, 2 pending, 11 failed; another status is pending.
  - An RC in the message decides over the status: RC:94 (duplicate ref) and
    RC:08 (biller timeout) are pending, RC:31 a refund, RC:91/92/93/95 a failure
    the admin must fix in SBI's settings.
  - The SN is read from `msg` (`SN:` up to `REFID:`), the actual cost from
    `total_payment` (or `HRG:`), a failure's reason from `KET:`.
  """

  @config_rcs ~w(91 92 93 95)
  @pending_rcs ~w(02 08 94)
  @failed_rcs ~w(05 12 14 15 16 17 21 22 23 24 25 26 27 30 405 406 407 47 53 83 84 85 86 87 88 89 90 96 97 98 99)
  @config_message "Periksa kredensial / IP server di SBI"
  @payload_limit 4000

  @doc """
  A transaction's answer (the `data` of `topup`/`payment`/`status`, or a
  callback's body) as a provider result.
  """
  def transaction(answer) when is_map(answer) do
    msg = text(answer["msg"])

    result =
      case rc_of(msg) do
        rc when rc in ["31" | @pending_rcs] ->
          rc(rc, reason(msg))

        rc when rc in @config_rcs ->
          rc(rc, reason(msg))

        _ ->
          if inquiry_row?(msg),
            do: by_status(2, answer, nil),
            else: by_status(status(answer["status"]), answer, msg)
      end

    {:ok, Map.put(result, :payload, payload(answer))}
  end

  def transaction(_answer), do: {:error, :not_found}

  # A bill is paid with its inquiry's ref_1, so SBI may answer a status check
  # (during a slow payment) with the inquiry itself — successful, but not a
  # payment. It says so in its message: "INQ …" or "… CEK TAGIHAN …".
  defp inquiry_row?(nil), do: false
  defp inquiry_row?(msg), do: msg =~ ~r/^\s*INQ\b|CEK TAGIHAN/i

  defp by_status(1, answer, msg) do
    %{
      status: :success,
      token_sn: sn(msg),
      provider_ref: text(answer["ref_2"]),
      actual_cost: money(answer["total_payment"]) || hrg(msg)
    }
  end

  defp by_status(11, _answer, msg), do: %{status: :failed, message: reason(msg)}

  defp by_status(_pending, answer, msg),
    do: %{status: :pending, provider_ref: text(answer["ref_2"]), message: nil_if_blank(msg)}

  @doc """
  What a request's whole answer is: `{:data, map}` for SBI's `data` object,
  `{:rc, code, message}` for an error answer carrying an RC, or `:unknown`
  (a server error, an HTML page, nothing to go on).
  """
  def envelope(http_status, _body) when http_status >= 500, do: :unknown
  def envelope(_http_status, %{"data" => data}) when is_map(data), do: {:data, data}

  def envelope(_http_status, %{} = body) do
    message = text(body["message"]) || text(body["msg"])
    rc_envelope(message)
  end

  def envelope(_http_status, body) when is_binary(body), do: rc_envelope(body)
  def envelope(_http_status, _body), do: :unknown

  defp rc_envelope(message) do
    case rc_of(message) do
      nil -> :unknown
      code -> {:rc, code, message}
    end
  end

  @doc "The result an RC alone stands for (an error answer without `data`)."
  def rc("31", message), do: %{status: :refunded, message: reason(message)}

  def rc(code, _message) when code in @config_rcs,
    do: %{status: :failed, message: @config_message}

  def rc(code, message) when code in @failed_rcs, do: %{status: :failed, message: reason(message)}
  def rc(_pending_or_unknown, message), do: %{status: :pending, message: nil_if_blank(message)}

  @doc """
  An inquiry's answer: a PLN bill (`:bill`) or the owner of a token PLN meter
  (`:customer`). Takes what `envelope/2` returned.
  """
  def inquiry({:data, answer}, kind) do
    msg = text(answer["msg"])

    case {status(answer["status"]), rc_of(msg)} do
      {1, _rc} -> {:ok, inquiry_answer(answer, msg, kind)}
      {_status, nil} -> {:error, {:rejected, reason(msg) || "Ditolak penyedia."}}
      {_status, rc} -> inquiry_rc(rc, msg)
    end
  end

  def inquiry({:rc, rc, message}, _kind), do: inquiry_rc(rc, message)
  def inquiry(_unknown, _kind), do: {:error, :unavailable}

  defp inquiry_rc(rc, _msg) when rc in ~w(05 14 15), do: {:error, :not_found}
  defp inquiry_rc("88", _msg), do: {:error, :already_paid}
  defp inquiry_rc("83", _msg), do: {:error, {:rejected, "Tagihan belum tersedia."}}
  defp inquiry_rc("16", _msg), do: {:error, {:rejected, "Nomor meter diblokir."}}
  defp inquiry_rc(rc, _msg) when rc in ~w(84 98 99 08), do: {:error, :unavailable}
  defp inquiry_rc(rc, _msg) when rc in @config_rcs, do: {:error, {:rejected, @config_message}}
  defp inquiry_rc(_rc, msg), do: {:error, {:rejected, reason(msg) || "Ditolak penyedia."}}

  defp inquiry_answer(answer, msg, kind) do
    detail = if is_map(answer["detail"]), do: answer["detail"], else: %{}
    bill? = kind == :bill

    %{
      customer_name: trimmed(detail["data_1"]) || field(msg, "Nama"),
      details: tidy_details(text(detail["data_2"])) || field(msg, "Tarif daya"),
      sheets: months(msg),
      period: field(msg, "Blth"),
      bill_amount: if(bill?, do: money(answer["price"])),
      provider_admin: if(bill?, do: money(answer["admin"])),
      provider_total:
        if(bill?, do: money(answer["total_payment"]) || money(answer["total_price"])),
      inquiry_ref: text(answer["ref_2"])
    }
  end

  @doc "A number SBI sent, as a string or a number; anything else is `nil`."
  def money(value) when is_integer(value), do: Decimal.new(value)
  def money(value) when is_float(value), do: Decimal.from_float(value)

  def money(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  def money(_value), do: nil

  # What SBI's message says, piece by piece.

  defp rc_of(nil), do: nil

  defp rc_of(message) do
    case Regex.run(~r/RC\s*:\s*(\d+)/i, message) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp sn(msg) do
    case msg && Regex.run(~r/SN\s*:\s*(.*?)\s*(?:SALDO\s*:|REFID\s*:|$)/s, msg) do
      [_, sn] -> sn |> String.trim() |> String.trim_trailing(".") |> nil_if_blank()
      _ -> nil
    end
  end

  defp hrg(msg) do
    case msg && Regex.run(~r/HRG\s*:\s*(-?\d+)/, msg) do
      [_, amount] -> money(amount)
      _ -> nil
    end
  end

  # A failure's reason: SBI's KET when it has one, else the whole message.
  defp reason(nil), do: nil

  defp reason(msg) do
    case Regex.run(~r/KET\s*:\s*(.*?)(?:\s+SALDO\s*:|\s+REFID\s*:|$)/s, msg) do
      [_, ket] -> nil_if_blank(String.trim(ket)) || msg
      _ -> msg
    end
  end

  # `Nama:SUTARTO/Tarif daya:R1 450/...`: a field up to the next slash.
  defp field(nil, _name), do: nil

  defp field(msg, name) do
    case Regex.run(~r/#{name}\s*:\s*([^\/]*)/i, msg) do
      [_, value] -> value |> String.trim() |> String.trim_trailing(".") |> nil_if_blank()
      _ -> nil
    end
  end

  defp months(msg) do
    case msg && Regex.run(~r/Jml bulan\s*:\s*(\d+)/i, msg) do
      [_, n] -> max(String.to_integer(n), 1)
      _ -> nil
    end
  end

  defp tidy_details(nil), do: nil

  defp tidy_details(details),
    do: details |> String.trim() |> String.trim_trailing("/") |> String.trim() |> nil_if_blank()

  defp status(value) when is_integer(value), do: value

  defp status(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp status(_value), do: nil

  defp payload(answer), do: answer |> Jason.encode!() |> String.slice(0, @payload_limit)

  @doc false
  def text(nil), do: nil
  def text(value) when is_binary(value), do: value
  def text(value) when is_number(value), do: to_string(value)
  def text(_value), do: nil

  defp trimmed(value), do: value |> text() |> then(&(&1 && String.trim(&1))) |> nil_if_blank()

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(value), do: if(String.trim(value) == "", do: nil, else: value)
end
