defmodule ZahlungsWeb.ServiceProductExportControllerTest do
  use ZahlungsWeb.ConnCase, async: false

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.StoresFixtures

  defp admin do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp sheet(conn) do
    {:ok, files} = :zip.unzip(response(conn, 200), [:memory])

    files
    |> Map.new(fn {name, content} -> {to_string(name), content} end)
    |> Map.fetch!("xl/worksheets/sheet1.xml")
  end

  test "cashiers can't export", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get("/admin/services/export.xlsx")
    assert redirected_to(conn) == "/"
  end

  test "an admin downloads the list as an Excel file", %{conn: conn} do
    product =
      service_product_fixture(%{name: "Pulsa Ekspor #{System.unique_integer([:positive])}"})

    conn = conn |> log_in_user(admin()) |> get("/admin/services/export.xlsx")

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/attachment; filename="produk-layanan-semua-\d{4}-\d{2}-\d{2}\.xlsx"/

    xml = sheet(conn)
    assert xml =~ "Harga jual"
    assert xml =~ product.name
    # Cost 10.150 + margin 1.850 = 12.000, written as numbers.
    assert xml =~ "<v>10150.00</v>"
    assert xml =~ "<v>12000.00</v>"
  end

  test "the file follows the page's filters", %{conn: conn} do
    n = System.unique_integer([:positive])
    tsel = service_product_fixture(%{name: "Tsel #{n}", operator: "telkomsel"})
    tri = service_product_fixture(%{name: "Tri #{n}", operator: "tri"})
    token = service_product_fixture(%{name: "Token #{n}", category: "token_pln"})

    conn =
      conn
      |> log_in_user(admin())
      |> get("/admin/services/export.xlsx?category=pulsa&operator=telkomsel")

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "produk-layanan-pulsa-"

    xml = sheet(conn)
    assert xml =~ tsel.name
    refute xml =~ tri.name
    refute xml =~ token.name
  end

  test "another organization's products are not in it", %{conn: conn} do
    theirs =
      in_org(organization_fixture(), fn ->
        {:ok, product} =
          Zahlungs.Services.create_product(%{
            name: "Asing #{System.unique_integer([:positive])}",
            category: "pulsa",
            cost: "1000",
            margin_type: "amount",
            margin_value: "100"
          })

        product
      end)

    xml = conn |> log_in_user(admin()) |> get("/admin/services/export.xlsx") |> sheet()
    refute xml =~ theirs.name
  end
end
