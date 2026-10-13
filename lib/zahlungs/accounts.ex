defmodule Zahlungs.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Zahlungs.Repo

  alias Zahlungs.Accounts.{User, UserToken, UserNotifier, UserLogin}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    # Before login there is no current organization: emails are unique across all.
    Repo.get_by(User, [email: email], skip_org_id: true)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, [email: email], skip_org_id: true)
    # A deactivated user cannot authenticate even with the correct password.
    if User.valid_password?(user, password) and user.active, do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User roles

  @doc """
  Returns `true` if the given user is an admin.

  ## Examples

      iex> admin?(%User{role: "admin"})
      true

      iex> admin?(%User{role: "cashier"})
      false

  """
  def admin?(%User{role: "admin"}), do: true
  def admin?(_), do: false

  @doc """
  Sets the role of a user. Intended for admin use only.

  ## Examples

      iex> set_user_role(user, "admin")
      {:ok, %User{}}

      iex> set_user_role(user, "bogus")
      {:error, %Ecto.Changeset{}}

  """
  def set_user_role(%User{} = user, role) do
    user
    |> User.role_changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Sets or clears a user's confirmation (admin-only): `true` stamps `confirmed_at`
  with the current time, `false` clears it back to unconfirmed.
  """
  def set_user_confirmed(%User{} = user, confirmed?) when is_boolean(confirmed?) do
    confirmed_at =
      if confirmed?, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second), else: nil

    user
    |> Ecto.Changeset.change(confirmed_at: confirmed_at)
    |> Repo.update()
  end

  @doc """
  Activates or deactivates a user (admin-only). Deactivating also deletes all of
  the user's tokens so any live session is terminated immediately; a deactivated
  user can no longer log in (see `get_user_by_email_and_password/2` and
  `get_user_by_session_token/1`).
  """
  def set_user_active(%User{} = user, active) when is_boolean(active) do
    multi = Ecto.Multi.update(Ecto.Multi.new(), :user, User.active_changeset(user, active))

    multi =
      if active,
        do: multi,
        else: Ecto.Multi.delete_all(multi, :tokens, UserToken.user_and_contexts_query(user, :all))

    case Repo.transaction(multi) do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Admin user management

  @doc "Lists all users with their store, ordered by email."
  def list_users do
    Repo.all(from u in User, order_by: u.email, preload: :store)
  end

  @doc """
  Moves a user to another store (admin-only). A cashier must always have one;
  an admin may be given none (`nil`).
  """
  def set_user_store(%User{} = user, store_id) do
    user
    |> User.store_changeset(%{store_id: store_id})
    |> Repo.update()
  end

  ## Login log

  @doc """
  Records a successful login and where it was made from. Pure bookkeeping: it
  never decides whether the login is allowed, and callers ignore its result.

  `position` holds `"latitude"`, `"longitude"` and `"accuracy"` as sent by the
  browser (strings or numbers); anything missing or out of range is stored as
  unknown. `meta` may carry `:ip` and `:user_agent`.
  """
  def record_login(%User{} = user, position \\ %{}, meta \\ %{}) do
    store = Zahlungs.Stores.get_active_store(user.store_id)
    {latitude, longitude} = coordinates(position)

    Repo.insert(%UserLogin{
      organization_id: user.organization_id,
      user_id: user.id,
      store_id: store && store.id,
      latitude: latitude,
      longitude: longitude,
      accuracy_m: latitude && non_negative(position["accuracy"]),
      distance_m: distance_to_store(store, latitude, longitude),
      ip: meta[:ip],
      user_agent: meta[:user_agent] && String.slice(meta[:user_agent], 0, 255)
    })
  end

  defp coordinates(position) do
    with latitude when is_float(latitude) <- to_float(position["latitude"]),
         longitude when is_float(longitude) <- to_float(position["longitude"]),
         true <- abs(latitude) <= 90 and abs(longitude) <= 180 do
      {latitude, longitude}
    else
      _ -> {nil, nil}
    end
  end

  defp distance_to_store(%{latitude: slat, longitude: slng}, lat, lng)
       when is_float(slat) and is_float(slng) and is_float(lat) and is_float(lng) do
    Zahlungs.Geo.distance_m({slat, slng}, {lat, lng})
  end

  defp distance_to_store(_store, _lat, _lng), do: nil

  defp non_negative(value) do
    case to_float(value) do
      n when is_float(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp to_float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_float(_), do: nil

  @doc """
  Lists the login log, most recent first, with user and store preloaded.

  Options: `:user_id`, `:store_id` (filters), `:limit` (default 100).
  """
  def list_user_logins(opts \\ []) do
    UserLogin
    |> filter_login(:user_id, opts[:user_id])
    |> filter_login(:store_id, opts[:store_id])
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^(opts[:limit] || 100))
    |> preload([:user, :store])
    |> Repo.all()
  end

  defp filter_login(query, _field, nil), do: query
  defp filter_login(query, field, value), do: where(query, [l], field(l, ^field) == ^value)

  @doc "Deletes login-log rows older than `days` days. Returns how many were removed."
  def prune_user_logins(days) when is_integer(days) and days > 0 do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -days * 86_400)
    # Maintenance across every organization.
    {count, _} =
      Repo.delete_all(from(l in UserLogin, where: l.inserted_at < ^cutoff), skip_org_id: true)

    count
  end

  @doc "Returns a changeset for an admin creating a user (no password hashing)."
  def change_user(%User{} = user, attrs \\ %{}) do
    User.admin_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Creates a user as an admin (email + password + role) and marks it confirmed.
  """
  def create_user(attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %User{organization_id: Repo.get_org_id()}
    |> User.admin_changeset(attrs)
    |> Ecto.Changeset.put_change(:confirmed_at, now)
    |> Repo.insert()
  end

  @doc """
  Creates a platform operator (role `superadmin`): confirmed, and belonging to
  no organization. For seeds and the console - there is no screen for it.
  """
  def create_platform_admin(attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %User{organization_id: nil}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.change(role: "superadmin", confirmed_at: now)
    |> Repo.insert()
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{organization_id: Repo.get_org_id()}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user's display name.
  """
  def change_user_name(user, attrs \\ %{}) do
    User.name_changeset(user, attrs)
  end

  @doc """
  Updates the user's display name.
  """
  def update_user_name(user, attrs) do
    user
    |> User.name_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context) do
    changeset = user |> User.email_changeset(%{email: email}) |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  @doc """
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_update_email_instructions(user, current_email, &Routes.user_update_email_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    # Reject sessions belonging to a deactivated user (belt-and-suspenders: their
    # tokens are already deleted on deactivation).
    case Repo.one(query) do
      %User{active: true} = user -> user
      _ -> nil
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  ## Confirmation

  @doc """
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &Routes.user_confirmation_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &Routes.user_confirmation_url(conn, :edit, &1))
      {:error, :already_confirmed}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc """
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &Routes.user_reset_password_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end
end
