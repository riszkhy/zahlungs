defmodule Zahlungs.Geo do
  @moduledoc "Small geographic helpers."

  @earth_radius_m 6_371_000

  @doc """
  Great-circle distance in metres between two `{latitude, longitude}` points in
  degrees (haversine).
  """
  def distance_m({lat1, lng1}, {lat2, lng2}) do
    dlat = radians(lat2 - lat1)
    dlng = radians(lng2 - lng1)

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(radians(lat1)) * :math.cos(radians(lat2)) * :math.pow(:math.sin(dlng / 2), 2)

    2 * @earth_radius_m * :math.asin(:math.sqrt(a))
  end

  defp radians(degrees), do: degrees * :math.pi() / 180
end
