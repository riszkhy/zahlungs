defmodule ZahlungsWeb.SignupController do
  @moduledoc """
  Public sign-up for a new business. Nobody is logged in afterwards: the
  organization waits for the platform operator's approval first.
  """
  use ZahlungsWeb, :controller

  alias Zahlungs.Organizations
  alias ZahlungsWeb.LoginThrottle

  def new(conn, _params) do
    render(conn, :new, changeset: Organizations.change_signup(), error_message: nil)
  end

  def create(conn, %{"signup" => params}) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    # Sign-up is open to anyone, so it is rationed per address (the same
    # counter as failed logins, under its own key).
    case LoginThrottle.check("signup", ip) do
      :ok ->
        LoginThrottle.record_failure("signup", ip)
        register(conn, params)

      {:error, _seconds} ->
        render(conn, :new,
          changeset: Organizations.change_signup(params),
          error_message: "Terlalu banyak pendaftaran dari perangkat ini. Coba lagi nanti."
        )
    end
  end

  defp register(conn, params) do
    case Organizations.register(params) do
      {:ok, _result} ->
        redirect(conn, to: ~p"/signup/pending")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset, error_message: nil)
    end
  end

  def pending(conn, _params) do
    render(conn, :pending)
  end
end
