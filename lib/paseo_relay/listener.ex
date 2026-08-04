defmodule PaseoRelay.Listener do
  @moduledoc false

  def child_spec(options) do
    reference = Keyword.fetch!(options, :ref)
    config = options |> Keyword.fetch!(:config) |> PaseoRelay.Config.normalize()

    reference
    |> :ranch.child_spec(
      :ranch_tcp,
      transport_options(options, config),
      :cowboy_clear,
      protocol_options(config, options, reference)
    )
    |> Map.put(:id, reference)
  end

  def port(reference), do: :ranch.get_port(reference)

  defp transport_options(options, config) do
    acceptors = Keyword.get(options, :acceptors, config.acceptors)

    %{
      num_acceptors: acceptors,
      num_conns_sups: Keyword.get(options, :connection_supervisors, acceptors),
      max_connections:
        Keyword.get(
          options,
          :connections_per_supervisor,
          Keyword.get(options, :max_connections, config.connections_per_acceptor)
        ),
      socket_opts: socket_options(options, config)
    }
  end

  defp socket_options(options, config) do
    socket_options = [
      ip: Keyword.get(options, :ip, config.ip),
      port: Keyword.get(options, :port, config.port),
      nodelay: true,
      recbuf: Keyword.get(options, :receive_buffer_bytes, config.tcp_receive_buffer_bytes),
      send_timeout: Keyword.get(options, :send_timeout_ms, config.transport_send_timeout_ms),
      send_timeout_close: true
    ]

    case Keyword.fetch(options, :send_buffer_bytes) do
      {:ok, bytes} -> Keyword.put(socket_options, :sndbuf, bytes)
      :error -> socket_options
    end
  end

  defp protocol_options(config, options, reference) do
    socket_options = %{
      config: config,
      connection_budget: {
        Keyword.get(options, :budget_namespace, reference),
        Keyword.get(
          options,
          :max_websockets,
          config.acceptors * config.connections_per_acceptor
        )
      },
      ownership_target: config.ownership_target,
      reroute_header: config.reroute_header
    }

    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/ws", PaseoRelay.Socket, socket_options},
           {:_, PaseoRelay.Operations,
            %{config: config, connection_budget: socket_options.connection_budget}}
         ]}
      ])

    %{
      env: %{dispatch: dispatch},
      idle_timeout: Keyword.get(options, :http_idle_timeout_ms, config.http_idle_timeout_ms),
      protocols: [:http]
    }
  end
end
