defmodule PaseoRelay.FlyDiagnostics do
  @moduledoc false

  @scope :paseo_relay_owners

  def snapshot(server_ids) when is_list(server_ids) do
    config =
      :paseo_relay
      |> Application.get_env(:runtime, PaseoRelay.Config.defaults())
      |> PaseoRelay.Config.normalize()

    Map.merge(identity(), %{
      capacity_pid: inspect(Process.whereis(PaseoRelay.Capacity)),
      connection_ceiling: config.acceptors * config.connections_per_acceptor,
      capacity_mutation_timeout_ms: config.capacity_mutation_timeout_ms,
      monotonic_ms: System.monotonic_time(:millisecond),
      owners: Map.new(server_ids, &{&1, owner(&1)})
    })
  end

  def print_snapshot(encoded_server_ids) do
    server_ids = encoded_server_ids |> Base.url_decode64!(padding: false) |> Jason.decode!()
    server_ids |> snapshot() |> Jason.encode!() |> IO.puts()
  end

  def suspend_capacity(expected_pid) do
    capacity = exact_capacity!(expected_pid)
    :ok = :sys.suspend(capacity)

    identity()
    |> Map.merge(%{
      event: "capacity_suspended",
      capacity_pid: expected_pid,
      acknowledged_monotonic_ms: System.monotonic_time(:millisecond)
    })
    |> Jason.encode!()
    |> IO.puts()
  end

  def kill_capacity(expected_pid) do
    status =
      case Process.whereis(PaseoRelay.Capacity) do
        capacity when is_pid(capacity) ->
          if inspect(capacity) == expected_pid do
            Process.exit(capacity, :kill)
            :killed
          else
            :already_replaced
          end

        nil ->
          :already_replaced
      end

    identity()
    |> Map.merge(%{
      event: "capacity_recovery",
      capacity_pid: expected_pid,
      status: status
    })
    |> Jason.encode!()
    |> IO.puts()
  end

  defp exact_capacity!(expected_pid) do
    case Process.whereis(PaseoRelay.Capacity) do
      pid when is_pid(pid) ->
        if inspect(pid) == expected_pid, do: pid, else: raise("Capacity epoch changed")

      nil ->
        raise "Capacity epoch was unavailable"
    end
  end

  defp identity do
    %{
      schema: 1,
      machine_id: System.fetch_env!("FLY_MACHINE_ID"),
      private_ip: System.fetch_env!("FLY_PRIVATE_IP"),
      release_node: Atom.to_string(node()),
      release_os_pid: System.pid()
    }
  end

  defp owner(server_id) do
    case :syn.lookup(@scope, server_id) do
      :undefined ->
        :unowned

      {pid, "instance=" <> machine_id} ->
        %{machine_id: machine_id, node: Atom.to_string(node(pid)), pid: inspect(pid)}

      {_pid, _unexpected_target} ->
        :invalid_target
    end
  end
end
