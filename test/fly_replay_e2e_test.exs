defmodule PaseoRelay.FlyReplayE2ETest do
  use ExUnit.Case, async: false

  @runner "Code.require_file(\"deployment/fly/replay-e2e.exs\"); PaseoRelay.FlyReplayE2E.run(System.argv())"

  @tag timeout: 60_000
  test "independent replay probes use distinct ids and leave no active sockets" do
    port = start_listener()

    results =
      Enum.map(1..3, fn _ ->
        result = run_probe(port)
        assert PaseoRelay.Metrics.value(:active_websockets) == 0
        result
      end)

    server_ids = Enum.map(results, &Map.fetch!(&1, "server_id"))

    assert Enum.all?(server_ids, fn server_id ->
             Regex.match?(~r/^fly-replay-[0-9a-f]{32}$/, server_id)
           end)

    assert length(Enum.uniq(server_ids)) == length(server_ids)
  end

  test "a failed websocket start reports the role instead of a match error" do
    {output, status} = run_script(available_port())

    assert status != 0
    assert output =~ "failed to start server websocket"
    refute output =~ "MatchError"
  end

  defp run_probe(port) do
    {output, status} = run_script(port)

    assert status == 0, output

    output
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "{"))
    |> Jason.decode!()
  end

  defp run_script(port) do
    System.cmd(
      System.find_executable("mix"),
      [
        "run",
        "--no-start",
        "-e",
        @runner,
        "--",
        "--endpoint",
        "ws://127.0.0.1:#{port}",
        "--owner",
        "local",
        "--landing",
        "local"
      ],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp start_listener do
    reference = {:fly_replay_e2e, System.unique_integer([:positive])}

    start_supervised!(
      {PaseoRelay.Listener,
       ref: reference,
       config: PaseoRelay.Config.defaults(),
       ip: {127, 0, 0, 1},
       port: 0,
       acceptors: 4,
       max_connections: 1_000}
    )

    PaseoRelay.Listener.port(reference)
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
