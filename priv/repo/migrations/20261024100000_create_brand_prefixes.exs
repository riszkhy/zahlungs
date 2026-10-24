defmodule Zahlungs.Repo.Migrations.CreateBrandPrefixes do
  use Ecto.Migration

  # The first four digits of a mobile number that name its brand, kept by the
  # platform operator for every organization (no organization_id). Filled with
  # the defaults that were in Zahlungs.Services.Brand, so detection is the
  # same after the deploy.

  @defaults %{
    "telkomsel" => ~w(0811 0812 0813 0821 0822 0823 0851 0852 0853),
    "indosat" => ~w(0814 0815 0816 0855 0856 0857 0858),
    "xl" => ~w(0817 0818 0819 0859 0877 0878),
    "axis" => ~w(0831 0832 0833 0838),
    "tri" => ~w(0895 0896 0897 0898 0899),
    "smartfren" => ~w(0881 0882 0883 0884 0885 0886 0887 0888 0889)
  }

  def up do
    create table(:brand_prefixes) do
      add :brand, :string, size: 20, null: false
      add :prefix, :string, size: 4, null: false

      timestamps()
    end

    create unique_index(:brand_prefixes, [:prefix])

    flush()

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for {brand, prefixes} <- @defaults, prefix <- prefixes do
        %{brand: brand, prefix: prefix, inserted_at: now, updated_at: now}
      end

    repo().insert_all("brand_prefixes", rows)
  end

  def down do
    drop table(:brand_prefixes)
  end
end
