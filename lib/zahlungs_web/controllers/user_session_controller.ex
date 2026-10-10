defmodule ZahlungsWeb.UserSessionController do
  use ZahlungsWeb, :controller

  require Logger

  alias Zahlungs.Accounts
  alias Zahlungs.Scope
  alias ZahlungsWeb.{LoginThrottle, UserAuth}

  def new(conn, _params) do
    render(conn, :new, error_message: nil)
  end

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    with :ok <- LoginThrottle.check(email, ip),
         %{} = user <- Accounts.get_user_by_email_and_password(email, password),
         true <- Scope.usable?(Scope.for_user(user)) do
      LoginThrottle.reset(email, ip)
      record_login(conn, user, user_params, ip)
      UserAuth.log_in_user(conn, user, user_params)
    else
      {:error, seconds} ->
        minutes = max(1, ceil(seconds / 60))

        render(conn, :new,
          error_message: "Terlalu banyak percobaan login. Coba lagi dalam #{minutes} menit."
        )

      nil ->
        LoginThrottle.record_failure(email, ip)

        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        render(conn, :new, error_message: "Invalid email or password")

      false ->
        render(conn, :new, error_message: UserAuth.no_store_message())
    end
  end

  # Where the login was made from is bookkeeping: a failure to write it down
  # must never keep someone from logging in.
  defp record_login(conn, user, user_params, ip) do
    user_agent = conn |> get_req_header("user-agent") |> List.first()
    Accounts.record_login(user, user_params, %{ip: ip, user_agent: user_agent})
  rescue
    error -> Logger.error("Could not record the login: #{Exception.message(error)}")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
