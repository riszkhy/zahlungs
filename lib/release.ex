defmodule Release do
  @moduledoc """
  Responsible for custom release commands
  """
  @app :zahlungs

  def migrate do
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Runs priv/repo/seeds.exs inside a release:

      bin/zahlungs eval "Release.seed"

  In prod the seeds only create accounts when SEED_ADMIN_EMAIL /
  SEED_ADMIN_PASSWORD (and optionally SEED_CASHIER_*) are set, and they never
  insert the sample catalog.
  """
  def seed do
    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seeds = Application.app_dir(@app, "priv/repo/seeds.exs")
          Code.eval_file(seeds)
        end)
    end
  end

  defp repos do
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
