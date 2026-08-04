defmodule PaseoRelay.Reroute do
  @moduledoc false

  def headers({:reroute, target}, header) when is_binary(target) and is_binary(header),
    do: %{header => target}

  def headers(_, _header), do: %{}
end
