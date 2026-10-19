defmodule Zahlungs.Deposits.Credentials do
  @moduledoc """
  Encrypts a deposit account's provider credentials for the database, with a
  key derived from the endpoint's `secret_key_base`. Changing that secret makes
  stored credentials unreadable (see `docs/DEPLOYMENT.md`).
  """

  alias Plug.Crypto.{KeyGenerator, MessageEncryptor}

  @doc "The credentials map, encrypted."
  def encrypt(credentials) when is_map(credentials) do
    credentials
    |> Jason.encode!()
    |> MessageEncryptor.encrypt(key("deposit credentials"), key("deposit credentials sign"))
  end

  @doc "The credentials map, or `:error` for a value that wasn't encrypted with this key."
  def decrypt(nil), do: {:ok, %{}}

  def decrypt(encrypted) when is_binary(encrypted) do
    with {:ok, json} <-
           MessageEncryptor.decrypt(
             encrypted,
             key("deposit credentials"),
             key("deposit credentials sign")
           ),
         {:ok, %{} = credentials} <- Jason.decode(json) do
      {:ok, credentials}
    else
      _ -> :error
    end
  end

  defp key(salt) do
    :zahlungs
    |> Application.fetch_env!(ZahlungsWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
    |> KeyGenerator.generate(salt)
  end
end
