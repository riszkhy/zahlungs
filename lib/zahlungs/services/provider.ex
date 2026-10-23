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
  # Any result may also carry `actual_cost` (what the vendor charged) and
  # `payload` (the raw answer, as text).
  @type result ::
          %{status: :success, token_sn: String.t() | nil, provider_ref: String.t() | nil}
          | %{status: :failed, message: String.t()}
          | %{status: :pending, provider_ref: String.t() | nil}
          | %{status: :refunded, message: String.t()}
  @type request :: %{ref_id: String.t(), product_code: String.t(), customer_ref: String.t()}

  @doc "The credential inputs the admin fills in, as `{key, label}`."
  @callback credential_fields() :: [{String.t(), String.t()}]

  @doc """
  The credential fields that aren't secret (e.g. a member ID): shown as plain
  text, with their stored value. The others are write-only.
  """
  @callback public_credentials() :: [String.t()]

  # The request also carries `ref_id`, `kind` (`:bill` | `:customer`) and, for a
  # token PLN owner check, the product's `check_code` (blank: the default).
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

  @typedoc "A product in the vendor's catalog (`catalog/1`)."
  @type catalog_item :: %{
          code: String.t(),
          name: String.t(),
          category_hint: String.t() | nil,
          price: Decimal.t() | nil,
          admin: Decimal.t() | nil,
          commission: Decimal.t() | nil,
          status: String.t()
        }

  @doc "The vendor's whole catalog (no credentials needed)."
  @callback catalog(config :: keyword) :: {:ok, [catalog_item]} | {:error, term}

  @doc "The member's price and status for each vendor code."
  @callback prices(credentials, [String.t()]) ::
              {:ok, %{String.t() => %{price: Decimal.t() | nil, status: String.t()}}}
              | {:error, term}

  @doc "The ref a callback is about, for callbacks without a token in the URL."
  @callback callback_ref(params :: map) :: {:ok, String.t()} | :error

  @optional_callbacks balance: 1, catalog: 1, prices: 2, callback_ref: 1, public_credentials: 0

  @adapters %{"fake" => Zahlungs.Services.Provider.Fake}

  @doc """
  The adapters Zahlungs knows, by the key an account stores
  (`config :zahlungs, :provider_adapters`; the fake one by default).
  """
  def adapters, do: Application.get_env(:zahlungs, :provider_adapters, @adapters)

  @doc "The adapter for a key, or `:error` for one Zahlungs doesn't know."
  def adapter(key), do: Map.fetch(adapters(), key)

  @labels [
    {"Smart Biller Indonesia (SBI)", "sbi"},
    {"Penyedia tiruan (uji coba)", "fake"}
  ]

  @doc "The registered adapters as `{label, key}` options for a select."
  def options do
    adapters = adapters()
    Enum.filter(@labels, fn {_label, key} -> Map.has_key?(adapters, key) end)
  end
end
