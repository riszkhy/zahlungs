defmodule Zahlungs.Services.Provider.Broken do
  @moduledoc """
  A provider for tests whose status check raises, as a real adapter might on
  an answer it doesn't expect. Registered as `"broken"` in `config/test.exs`.
  """
  @behaviour Zahlungs.Services.Provider

  @impl true
  def credential_fields, do: []

  @impl true
  def inquiry(_credentials, _request), do: {:error, :unavailable}

  @impl true
  def pay(_credentials, %{ref_id: ref_id}),
    do: {:ok, %{status: :pending, provider_ref: "BROKEN-" <> ref_id}}

  @impl true
  def status(_credentials, _request), do: raise("unexpected answer from the provider")

  @impl true
  def verify_callback(_credentials, _params, _headers), do: {:error, :invalid_signature}

  @impl true
  def ping(_credentials), do: :ok
end
