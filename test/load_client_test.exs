defmodule PaseoRelay.LoadClientTest.DelayedRelay do
  @behaviour :cowboy_handler

  @impl true
  def init(request, options) do
    query = request |> :cowboy_req.parse_qs() |> Map.new()

    if query["role"] == "server" && query["connectionId"] do
      Process.sleep(Keyword.fetch!(options, :delay_ms))
      send(Keyword.fetch!(options, :owner), {:delayed_connection, self()})
    end

    PaseoRelay.Socket.init(request, %{
      config: PaseoRelay.Config.defaults(),
      connection_budget:
        {Keyword.fetch!(options, :budget_namespace), Keyword.fetch!(options, :max_websockets)},
      ownership_target: "local",
      reroute_header: "x-reroute-target"
    })
  end
end

defmodule PaseoRelay.LoadClientTest do
  use ExUnit.Case, async: false

  setup context do
    active_websockets = PaseoRelay.Metrics.value(:active_websockets)

    on_exit(fn ->
      assert_eventually(fn ->
        PaseoRelay.Metrics.value(:active_websockets) == active_websockets
      end)
    end)

    if context[:relay] do
      port = available_port()
      relay_pid = start_relay(port, context[:listener] || [])

      on_exit(fn ->
        stop_relay(relay_pid)
      end)

      %{port: port, relay_pid: relay_pid}
    else
      %{}
    end
  end

  test "the black-box client documents generic v2 websocket roles" do
    {output, status} = System.cmd("node", ["scripts/relay-load.mjs", "--help"])

    assert status == 0
    assert output =~ "serverId"
    assert output =~ "connectionId"
    assert output =~ "--endpoints"
    assert output =~ "--cleanup-grace"
  end

  test "the generic load client has no provider staging coordinator" do
    {help, 0} = System.cmd("node", ["scripts/relay-load.mjs", "--help"])

    refute help =~ "staging-epoch"
    refute help =~ "staging-manifest"

    {_output, status} =
      System.cmd(
        "node",
        ["scripts/relay-load.mjs", "--scenario", "staging-epoch"],
        stderr_to_stdout: true
      )

    assert status == 2
  end

  test "a failed setup closes a sibling socket that opens later" do
    relay_port = available_port()
    unavailable_port = available_port()

    relays = [
      start_endpoint(PaseoRelay.LoadClientTest.DelayedRelay, relay_port,
        delay_ms: 500,
        owner: self()
      ),
      start_endpoint(PaseoRelay.Operations, unavailable_port, [])
    ]

    on_exit(fn -> Enum.each(relays, &Process.exit(&1, :shutdown)) end)

    {output, status} =
      run_load(
        [
          "--endpoints",
          "ws://127.0.0.1:#{relay_port}/ws,ws://127.0.0.1:#{unavailable_port}/ws",
          "--server-id",
          "delayed-failed-setup",
          "--pairs",
          "1",
          "--duration",
          "0",
          "--cleanup-grace",
          "2"
        ],
        3_000
      )

    result = Jason.decode!(output)

    assert status == 1
    assert result["connection_failures"] > 0
    assert result["error"] =~ "non-101 status code"
    assert result["cleanup_timeouts"] == 0
    assert_receive {:delayed_connection, delayed_connection}, 2_000
    delayed_connection_ref = Process.monitor(delayed_connection)
    assert_receive {:DOWN, ^delayed_connection_ref, :process, ^delayed_connection, _reason}, 2_000
    assert metric_value(request(relay_port, "/metrics"), "active_websockets") == 0
  end

  @tag :relay
  test "a ramped sustained run relays frames and finishes without cleanup failures", %{
    port: port,
    relay_pid: relay_pid
  } do
    {output, status} =
      System.cmd("node", [
        "scripts/relay-load.mjs",
        "--endpoints",
        "ws://127.0.0.1:#{port}/ws",
        "--pairs",
        "4",
        "--batch-size",
        "2",
        "--ramp-ms",
        "5",
        "--scenario",
        "sustained",
        "--duration",
        "1",
        "--rate",
        "20"
      ])

    result = Jason.decode!(output)

    assert status == 0

    assert Map.take(result, [
             "scenario",
             "requested_pairs",
             "requested_websockets",
             "connection_failures",
             "cleanup_timeouts",
             "send_failures"
           ]) == %{
             "scenario" => "sustained",
             "requested_pairs" => 4,
             "requested_websockets" => 9,
             "connection_failures" => 0,
             "cleanup_timeouts" => 0,
             "send_failures" => 0
           }

    assert result["frames_received"] > 0
    assert result["steady_duration_ms"] >= 1_000
    assert result["frames_sent"] >= 18 * result["requested_websockets"]
    stop_relay(relay_pid)
  end

  @tag :relay
  test "a sharded run can omit the shared control socket", %{port: port} do
    {output, status} =
      System.cmd("node", [
        "scripts/relay-load.mjs",
        "--endpoints",
        "ws://127.0.0.1:#{port}/ws",
        "--server-id",
        "shared-load-server",
        "--connection-prefix",
        "shard-a",
        "--no-control",
        "--pairs",
        "2",
        "--scenario",
        "burst",
        "--burst",
        "1",
        "--keepalive",
        "0.05",
        "--duration",
        "0.2"
      ])

    result = Jason.decode!(output)

    assert status == 0
    assert result["requested_websockets"] == 4
    assert result["connection_successes"] == 4
    assert result["frames_received"] >= 4
    assert is_integer(result["keepalive_frames_sent"])
    assert result["keepalive_frames_sent"] > 0
    assert result["connection_failures"] == 0
  end

  @tag :relay
  test "sustained traffic exercises its control socket with valid protocol frames", %{port: port} do
    {output, status} =
      System.cmd("node", [
        "scripts/relay-load.mjs",
        "--endpoints",
        "ws://127.0.0.1:#{port}/ws",
        "--server-id",
        "control-traffic",
        "--pairs",
        "0",
        "--scenario",
        "sustained",
        "--duration",
        "0.2",
        "--rate",
        "10"
      ])

    result = Jason.decode!(output)

    assert status == 0
    assert result["requested_websockets"] == 1
    assert result["frames_sent"] > 0
    assert result["frames_received"] == result["frames_sent"]
    assert result["frames_lost"] == 0
    assert result["normal_closes"] == 1
    assert result["abnormal_closes"] == 0
  end

  @tag :relay
  test "a signaled sustained run holds established sockets before publishing", %{port: port} do
    command =
      start_load([
        "--endpoints",
        "ws://127.0.0.1:#{port}/ws",
        "--server-id",
        "signaled-sustained",
        "--pairs",
        "1",
        "--scenario",
        "sustained",
        "--duration",
        "0.3",
        "--rate",
        "10",
        "--start-on-sigusr1"
      ])

    {:os_pid, pid} = Port.info(command, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    assert_eventually(fn ->
      request(port, "/metrics") |> metric_value("active_websockets") == 3
    end)

    forwarded = request(port, "/metrics") |> metric_value("frames_forwarded_total")
    assert_metric_stays(port, "frames_forwarded_total", forwarded, 300)
    assert {_, 0} = System.cmd("kill", ["-USR1", Integer.to_string(pid)])

    {output, status} = await_command(command, "", System.monotonic_time(:millisecond) + 5_000)
    result = Jason.decode!(output)

    assert status == 0

    assert Map.take(result, [
             "requested_websockets",
             "publisher_started_by_signal",
             "send_failures",
             "ordering_failures",
             "frames_lost",
             "normal_closes",
             "abnormal_closes"
           ]) == %{
             "requested_websockets" => 3,
             "publisher_started_by_signal" => true,
             "send_failures" => 0,
             "ordering_failures" => 0,
             "frames_lost" => 0,
             "normal_closes" => 3,
             "abnormal_closes" => 0
           }

    assert result["publisher_wait_ms"] >= 300
    assert result["frames_sent"] >= 3
    assert result["frames_received"] == result["frames_sent"]
  end

  @tag :relay
  test "a replacement run reuses the same server id with clean data and control traffic", %{
    port: port
  } do
    results =
      for prefix <- ["old-epoch", "replacement-epoch"] do
        {output, status} =
          System.cmd("node", [
            "scripts/relay-load.mjs",
            "--endpoints",
            "ws://127.0.0.1:#{port}/ws",
            "--server-id",
            "replacement-session",
            "--connection-prefix",
            prefix,
            "--pairs",
            "2",
            "--scenario",
            "sustained",
            "--duration",
            "0.2",
            "--rate",
            "10"
          ])

        {status, Jason.decode!(output)}
      end

    assert Enum.map(results, fn {status, result} ->
             Map.take(Map.put(result, "status", status), [
               "status",
               "requested_websockets",
               "connection_successes",
               "connection_failures",
               "normal_closes",
               "abnormal_closes",
               "send_failures",
               "ordering_failures",
               "frames_lost"
             ])
           end) ==
             List.duplicate(
               %{
                 "status" => 0,
                 "requested_websockets" => 5,
                 "connection_successes" => 5,
                 "connection_failures" => 0,
                 "normal_closes" => 5,
                 "abnormal_closes" => 0,
                 "send_failures" => 0,
                 "ordering_failures" => 0,
                 "frames_lost" => 0
               },
               2
             )

    assert Enum.all?(results, fn {_status, result} -> result["frames_sent"] > 0 end)
  end

  @tag :relay
  @tag timeout: 30_000
  test "an ownership surge opens one real websocket for each distinct server", %{port: port} do
    {output, status} =
      System.cmd("node", [
        "scripts/relay-load.mjs",
        "--endpoints",
        "ws://127.0.0.1:#{port}/ws",
        "--scenario",
        "ownership",
        "--servers",
        "1000",
        "--batch-size",
        "200",
        "--duration",
        "0"
      ])

    result = Jason.decode!(output)

    assert status == 0

    assert Map.take(result, [
             "scenario",
             "requested_servers",
             "requested_pairs",
             "requested_websockets",
             "connection_successes",
             "connection_failures",
             "cleanup_timeouts"
           ]) == %{
             "scenario" => "ownership",
             "requested_servers" => 1000,
             "requested_pairs" => 0,
             "requested_websockets" => 1000,
             "connection_successes" => 1000,
             "connection_failures" => 0,
             "cleanup_timeouts" => 0
           }
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp start_endpoint(module, port, options) do
    reference = {:load_client_endpoint, System.unique_integer([:positive])}
    config = PaseoRelay.Config.defaults()

    options =
      Keyword.merge([budget_namespace: reference, max_websockets: 20_000], options)

    routes =
      if module == PaseoRelay.Operations do
        [{:_, module, config}]
      else
        [{"/ws", module, options}, {:_, PaseoRelay.Operations, config}]
      end

    dispatch = :cowboy_router.compile([{:_, routes}])

    {:ok, endpoint} =
      :cowboy.start_clear(
        reference,
        %{num_acceptors: 1, socket_opts: [ip: {127, 0, 0, 1}, port: port]},
        %{env: %{dispatch: dispatch}}
      )

    Process.unlink(endpoint)
    endpoint
  end

  defp run_load(arguments, timeout) do
    command = start_load(arguments)
    await_command(command, "", System.monotonic_time(:millisecond) + timeout)
  end

  defp start_load(arguments) do
    Port.open({:spawn_executable, System.find_executable("node")}, [
      :binary,
      :exit_status,
      args: ["scripts/relay-load.mjs" | arguments]
    ])
  end

  defp await_command(command, output, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^command, {:data, data}} -> await_command(command, output <> data, deadline)
      {^command, {:exit_status, status}} -> {output, status}
    after
      remaining ->
        {:os_pid, pid} = Port.info(command, :os_pid)
        System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        flunk("load client did not exit within #{remaining}ms after setup failed")
    end
  end

  defp request(port, path) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: relay.test\r\nConnection: close\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
    response
  end

  defp metric_value(metrics, name) do
    [_, value] = Regex.run(~r/paseo_relay_#{name} (\d+)/, metrics)
    String.to_integer(value)
  end

  defp start_relay(port, listener) do
    runtime =
      PaseoRelay.Config.defaults()
      |> Map.from_struct()
      |> Map.merge(Map.new([port: port] ++ listener))
      |> PaseoRelay.Config.normalize()

    start =
      """
      Application.put_env(:paseo_relay, :runtime, #{inspect(runtime)});
      Application.ensure_all_started(:paseo_relay)
      """

    relay =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        args: ["run", "--no-start", "--no-halt", "-e", start],
        env: [{~c"MIX_ENV", ~c"test"}]
      ])

    {:os_pid, relay_pid} = Port.info(relay, :os_pid)
    wait_for_listener(port, 50)
    relay_pid
  end

  defp stop_relay(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_, 0} -> wait_for_process_exit(pid, 20)
          {_, 1} -> :ok
        end

      {_, 1} ->
        :ok
    end
  end

  defp wait_for_listener(_port, 0), do: flunk("relay did not start")

  defp wait_for_listener(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, :econnrefused} ->
        Process.sleep(50)
        wait_for_listener(port, attempts - 1)
    end
  end

  defp wait_for_process_exit(_pid, 0), do: flunk("relay did not stop")

  defp wait_for_process_exit(pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 1} ->
        :ok

      {_, 0} ->
        Process.sleep(50)
        wait_for_process_exit(pid, attempts - 1)
    end
  end

  defp assert_eventually(check, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true")
      end

      Process.sleep(10)
      assert_eventually(check, deadline)
    end
  end

  defp assert_metric_stays(port, name, expected, duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    actual = request(port, "/metrics") |> metric_value(name)
    assert actual == expected

    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        10 ->
          assert_metric_stays(
            port,
            name,
            expected,
            max(0, deadline - System.monotonic_time(:millisecond))
          )
      end
    end
  end
end
