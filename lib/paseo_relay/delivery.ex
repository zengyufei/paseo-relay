defmodule PaseoRelay.Delivery do
  @moduledoc false

  alias PaseoRelay.Delivery.Writer

  def deliver([], _opcode, _payload, _deadline), do: :ok

  def deliver(writers, opcode, payload, deadline) do
    bytes = byte_size(payload)
    deliver_to_writers(writers, bytes, deadline, opcode, payload)
  end

  defp deliver_to_writers(writers, bytes, deadline, opcode, payload) do
    tasks =
      Enum.map(writers, fn writer ->
        Task.async(fn ->
          with {:ok, token} <- Writer.reserve(writer, bytes, deadline) do
            Writer.write(writer, token, opcode, payload, deadline)
          end
        end)
      end)

    # Each writer owns the deadline and must be allowed to observe it. Killing the
    # caller at the same instant races the writer's timeout against its caller
    # monitor and can release the reservation without shedding the slow consumer.
    results = Enum.map(tasks, &Task.await(&1, :infinity))

    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      Enum.find(results, {:error, :destination_closed}, &match?({:error, _}, &1))
    end
  end
end
