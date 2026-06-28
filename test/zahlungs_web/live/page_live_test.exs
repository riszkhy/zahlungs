defmodule ZahlungsWeb.PageLiveTest do
  use ZahlungsWeb.ConnCase

  import Phoenix.LiveViewTest

  # Skipped: phoenix_live_view 1.2's test helpers (`live/2`, `render/1`) require the
  # `lazy_html` dependency, which cannot be fetched in this offline environment.
  # Re-enable by adding `{:lazy_html, ">= 0.1.0", only: :test}` to mix.exs once
  # network access to hex.pm is available.
  @tag :skip
  test "disconnected and connected render", %{conn: conn} do
    {:ok, page_live, disconnected_html} = live(conn, "/")
    assert disconnected_html =~ "Welcome to Phoenix!"
    assert render(page_live) =~ "Welcome to Phoenix!"
  end
end
