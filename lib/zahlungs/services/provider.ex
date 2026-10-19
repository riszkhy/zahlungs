defmodule Zahlungs.Services.Provider do
  @moduledoc """
  What Zahlungs needs from a PPOB provider (an aggregator), whichever vendor it
  is. Each adapter gets the deposit account's decrypted credentials.

  A network error or a timeout on `pay/2` or `status/2` means the outcome is
  **not known yet**: callers treat it as pending, never as failed.

  Adapters are listed in `adapters/0`; an account stores the key, and a module
  name is never taken from input.
  """

  @type credentials :: %{String.t() => String.t()}
  @type result ::
          %{status: :success, token_sn: String.t() | nil, provider_ref: String.t() | nil}
          | %{status: :failed, message: String.t()}
          | %{status: :pending, provider_ref: String.t() | nil}
  @type request :: %{ref_id: String.t(), product_code: String.t(), customer_ref: String.t()}

  @doc "The credential inputs the admin fills in, as `{key, label}`."
  @callback credential_fields() :: [{String.t(), String.t()}]

  @callback inquiry(credentials, %{product_code: String.t(), customer_ref: String.t()}) ::
              {:ok,
               %{
                 customer_name: String.t(),
                 period: String.t(),
                 sheets: pos_integer,
                 bill_amount: Decimal.t(),
                 inquiry_ref: String.t()
               }}
              | {:error, :not_found | :already_paid | :unavailable | {:rejected, String.t()}}

  @callback pay(credentials, request) :: {:ok, result} | {:error, :timeout | :unavailable}
  @callback status(credentials, request) ::
              {:ok, result} | {:error, :timeout | :unavailable | :not_found}
  @callback verify_callback(credentials, params :: map, headers :: map) ::
              {:ok, ref_id :: String.t(), result} | {:error, :invalid_signature}
  @callback ping(credentials) :: :ok | {:error, String.t()}
  @callback balance(credentials) :: {:ok, Decimal.t()} | {:error, term}

  @optional_callbacks balance: 1

  @adapters %{"fake" => Zahlungs.Services.Provider.Fake}

  @doc """
  The adapters Zahlungs knows, by the key an account stores
  (`config :zahlungs, :provider_adapters`; the fake one by default).
  """
  def adapters, do: Application.get_env(:zahlungs, :provider_adapters, @adapters)

  @doc "The adapter for a key, or `:error` for one Zahlungs doesn't know."
  def adapter(key), do: Map.fetch(adapters(), key)

  @doc "The adapters as `{label, key}` options for a select."
  def options, do: [{"Penyedia tiruan (uji coba)", "fake"}]
end
