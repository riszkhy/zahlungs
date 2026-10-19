defmodule Zahlungs.Services.Provider.Fake do
  @moduledoc """
  A PPOB provider that answers without a network, for development and tests,
  until a real vendor is chosen. What it answers is decided by the **last digit
  of the customer's number**:

  | Digit | `inquiry`      | `pay`     | `status`   |
  | ----- | -------------- | --------- | ---------- |
  | 0     | ok             | failed    | failed     |
  | 9     | ok             | pending   | success    |
  | 8     | ok             | pending   | failed     |
  | 7     | unavailable    | timeout   | success    |
  | 6     | not found      | success   | success    |
  | 5     | already paid   | success   | success    |
  | 4     | ok             | timeout   | not found  |
  | other | ok             | success   | success    |

  An inquiry has 3 sheets when the second-to-last digit is 3, otherwise 1, at
  Rp 245.000 a sheet. Every `pay` and `status` call sends
  `{:fake_provider, :pay | :status, ref_id}` to the calling process, so tests
  can count them.
  """
  @behaviour Zahlungs.Services.Provider

  @sheet Decimal.new(245_000)

  @impl true
  def credential_fields, do: [{"secret", "Secret callback"}]

  @impl true
  def inquiry(_credentials, %{customer_ref: number}) do
    case last_digit(number) do
      "7" -> {:error, :unavailable}
      "6" -> {:error, :not_found}
      "5" -> {:error, :already_paid}
      _ -> {:ok, bill(number)}
    end
  end

  defp bill(number) do
    sheets = if String.at(number, -2) == "3", do: 3, else: 1

    %{
      customer_name: "PELANGGAN " <> String.slice(number, -4, 4),
      period: if(sheets == 3, do: "AGU–OKT 2026", else: "OKT 2026"),
      sheets: sheets,
      bill_amount: Decimal.mult(@sheet, sheets),
      inquiry_ref: "INQ-" <> number
    }
  end

  @impl true
  def pay(_credentials, %{ref_id: ref_id, customer_ref: number} = request) do
    send(self(), {:fake_provider, :pay, ref_id})

    case last_digit(number) do
      "0" ->
        {:ok, failed()}

      digit when digit in ["9", "8"] ->
        {:ok, %{status: :pending, provider_ref: "FAKE-" <> ref_id}}

      digit when digit in ["7", "4"] ->
        {:error, :timeout}

      _ ->
        {:ok, success(request)}
    end
  end

  @impl true
  def status(_credentials, %{ref_id: ref_id, customer_ref: number} = request) do
    send(self(), {:fake_provider, :status, ref_id})

    case last_digit(number) do
      digit when digit in ["0", "8"] -> {:ok, failed()}
      "4" -> {:error, :not_found}
      _ -> {:ok, success(request)}
    end
  end

  defp failed, do: %{status: :failed, message: "Nomor tidak aktif"}

  defp success(%{ref_id: ref_id, customer_ref: number, product_code: code}) do
    token_sn = if String.starts_with?(code || "", "PLN"), do: token(number), else: "SN" <> ref_id
    %{status: :success, token_sn: token_sn, provider_ref: "FAKE-" <> ref_id}
  end

  # 20 digits made from the number, like a PLN prepaid token.
  defp token(number) do
    digits = String.replace(number, ~r/\D/, "")
    digits |> String.duplicate(div(20, max(String.length(digits), 1)) + 1) |> String.slice(0, 20)
  end

  defp last_digit(number), do: String.last(number || "")

  @impl true
  def verify_callback(credentials, params, headers) do
    expected = sign(credentials["secret"] || "", params["ref_id"] || "", params["status"] || "")

    if Plug.Crypto.secure_compare(expected, headers["x-fake-signature"] || ""),
      do: {:ok, params["ref_id"], callback_result(params)},
      else: {:error, :invalid_signature}
  end

  defp callback_result(%{"status" => "success"} = params),
    do: %{status: :success, token_sn: params["token_sn"], provider_ref: params["provider_ref"]}

  defp callback_result(%{"status" => "failed"} = params),
    do: %{status: :failed, message: params["message"] || "Gagal di penyedia"}

  defp callback_result(params), do: %{status: :pending, provider_ref: params["provider_ref"]}

  @doc "The signature a callback for `ref_id` with `status` carries."
  def sign(secret, ref_id, status) do
    :hmac |> :crypto.mac(:sha256, secret, ref_id <> "|" <> status) |> Base.encode16(case: :lower)
  end

  @impl true
  def ping(_credentials), do: :ok

  @impl true
  def balance(_credentials), do: {:ok, Decimal.new("1000000")}
end
