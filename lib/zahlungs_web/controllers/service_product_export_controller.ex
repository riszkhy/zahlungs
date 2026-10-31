defmodule ZahlungsWeb.ServiceProductExportController do
  use ZahlungsWeb, :controller

  alias Zahlungs.{LocalTime, Services}
  alias Zahlungs.Services.{Brand, Product}
  alias ZahlungsWeb.Xlsx

  @header [
    "Nama",
    "Kategori",
    "Operator",
    "Kode produk vendor",
    "Modal",
    "Jenis margin",
    "Margin",
    "Harga jual",
    "Pembulatan",
    "Status",
    "Status vendor"
  ]

  @doc """
  The service products as an Excel file, filtered like the page
  (`category`, `operator`). Admin only (router).
  """
  def show(conn, params) do
    category = params["category"] || ""
    operator = params["operator"] || ""

    rows =
      [category: category, operator: operator]
      |> Services.list_products()
      |> Enum.map(&row/1)

    today = LocalTime.today(conn.assigns.current_scope.store)
    filename = "produk-layanan-#{if category == "", do: "semua", else: category}-#{today}.xlsx"

    send_download(conn, {:binary, Xlsx.build("Produk layanan", @header, rows)},
      filename: filename,
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end

  defp row(%Product{} = product) do
    [
      product.name,
      category_label(product.category),
      if(product.category in ~w(pulsa paket_data), do: Brand.label(product.operator)),
      product.provider_code,
      product.cost,
      if(product.margin_type == "percent", do: "Persen", else: "Rupiah"),
      product.margin_value,
      price(product),
      product.price_rounding,
      if(product.active, do: "Aktif", else: "Nonaktif"),
      vendor_status(product.provider_status)
    ]
  end

  # A bill's price depends on the bill, so it is left empty.
  defp price(product) do
    case Services.price_for(product, nil) do
      {:ok, %{price: price}} -> price
      {:error, _} -> nil
    end
  end

  defp category_label(category) do
    Enum.find_value(Services.categories(), category, fn {value, label} ->
      if value == category, do: label
    end)
  end

  defp vendor_status(nil), do: nil
  defp vendor_status("normal"), do: "Normal"
  defp vendor_status("gangguan"), do: "Gangguan"
  defp vendor_status("kosong"), do: "Kosong"
  defp vendor_status(other), do: other
end
