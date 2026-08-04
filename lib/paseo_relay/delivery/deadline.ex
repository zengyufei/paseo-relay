defmodule PaseoRelay.Delivery.Deadline do
  @moduledoc false

  def after_ms(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  def remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
