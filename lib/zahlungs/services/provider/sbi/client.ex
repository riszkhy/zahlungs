defmodule Zahlungs.Services.Provider.Sbi.Client do
  @moduledoc """
  HTTP for `Zahlungs.Services.Provider.Sbi`, on OTP's `:httpc`: JSON both ways,
  TLS verified against the system's CA certificates and the host name. Only
  `https://` addresses, unless `allow_http: true` (tests against a local
  server).

  Returns `{:ok, http_status, map}` (or the raw text when the body isn't JSON),
  `{:error, :timeout}` when no answer came in time, or `{:error, :network}`.
  """

  @connect_timeout 10_000

  @doc "POSTs `body` to `<base_url>/api/<action>`."
  def post(action, body, headers, timeout, opts \\ []) do
    opts = Keyword.merge(config(), opts)
    url = Keyword.fetch!(opts, :base_url) <> "/api/" <> action
    check_scheme!(url, opts)

    headers =
      for {name, value} <- headers,
          String.downcase(name) != "content-type",
          do: {to_charlist(name), to_charlist(value)}

    request(
      :post,
      {to_charlist(url), headers, ~c"application/json", Jason.encode!(body)},
      timeout
    )
  end

  @doc "GETs JSON from `url` (SBI's public price list)."
  def get_json(url, timeout, opts \\ []) do
    check_scheme!(url, Keyword.merge(config(), opts))
    request(:get, {to_charlist(url), []}, timeout)
  end

  defp request(method, request, timeout) do
    http_options = [timeout: timeout, connect_timeout: @connect_timeout, ssl: tls_options()]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, decode(body)}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :network}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp tls_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp check_scheme!(url, opts) do
    unless String.starts_with?(url, "https://") or
             (Keyword.get(opts, :allow_http, false) and String.starts_with?(url, "http://")) do
      raise ArgumentError, "SBI must be reached over HTTPS, got #{inspect(url)}"
    end
  end

  defp config, do: Application.get_env(:zahlungs, Zahlungs.Services.Provider.Sbi, [])
end
