Code.require_file("../deployment/fly/diagnostics.ex", __DIR__)

defmodule PaseoRelay.FlyDiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @snapshot_validator Path.expand("../deployment/fly/validate-snapshot.mjs", __DIR__)

  @tag :tmp_dir
  test "exact-image snapshot validation ignores launcher noise and checks the real PID shape", %{
    tmp_dir: dir
  } do
    snapshot = %{
      "schema" => 1,
      "machine_id" => "ci-machine",
      "private_ip" => "::1",
      "release_node" => "paseo_relay@::1",
      "release_os_pid" => "4130",
      "owners" => %{"ci-unowned" => "unowned"},
      "connection_ceiling" => 20_000,
      "capacity_mutation_timeout_ms" => 5_000,
      "capacity_pid" => "#PID<0.986.0>"
    }

    valid = Path.join(dir, "valid-output")
    File.write!(valid, "warning: native name encoding is latin1\n" <> Jason.encode!(snapshot))
    assert {"", 0} = run_snapshot_validator(valid)

    invalid = Path.join(dir, "invalid-output")
    File.write!(invalid, Jason.encode!(%{snapshot | "capacity_pid" => "<0.986.0>"}))

    assert {output, 1} = run_snapshot_validator(invalid)

    assert output ==
             "Fly diagnostic snapshot invalid: capacity_pid expected \"#PID<n.n.n>\", actual \"<0.986.0>\"\n"
  end

  @tag timeout: 8_000
  test "interruption cleanup kills the acknowledged Capacity epoch and readiness recovers" do
    old_machine = System.get_env("FLY_MACHINE_ID")
    old_private_ip = System.get_env("FLY_PRIVATE_IP")
    System.put_env("FLY_MACHINE_ID", "local-test-machine")
    System.put_env("FLY_PRIVATE_IP", "127.0.0.1")

    on_exit(fn ->
      restore_env("FLY_MACHINE_ID", old_machine)
      restore_env("FLY_PRIVATE_IP", old_private_ip)
    end)

    capacity = Process.whereis(PaseoRelay.Capacity)
    capacity_ref = Process.monitor(capacity)

    on_exit(fn ->
      if Process.whereis(PaseoRelay.Capacity) == capacity do
        Process.exit(capacity, :kill)
      end
    end)

    suspended =
      capture_io(fn ->
        PaseoRelay.FlyDiagnostics.suspend_capacity(inspect(capacity))
      end)
      |> Jason.decode!()

    assert Map.take(suspended, [
             "acknowledged_monotonic_ms",
             "capacity_pid",
             "event",
             "machine_id",
             "schema"
           ]) == %{
             "acknowledged_monotonic_ms" => suspended["acknowledged_monotonic_ms"],
             "capacity_pid" => inspect(capacity),
             "event" => "capacity_suspended",
             "machine_id" => "local-test-machine",
             "schema" => 1
           }

    assert is_integer(suspended["acknowledged_monotonic_ms"])

    recovered =
      capture_io(fn ->
        PaseoRelay.FlyDiagnostics.kill_capacity(inspect(capacity))
      end)
      |> Jason.decode!()

    assert Map.take(recovered, [
             "capacity_pid",
             "event",
             "machine_id",
             "schema",
             "status"
           ]) == %{
             "capacity_pid" => inspect(capacity),
             "event" => "capacity_recovery",
             "machine_id" => "local-test-machine",
             "schema" => 1,
             "status" => "killed"
           }

    assert_receive {:DOWN, ^capacity_ref, :process, ^capacity, :killed}, 2_000

    assert_eventually(fn ->
      replacement = Process.whereis(PaseoRelay.Capacity)
      is_pid(replacement) and replacement != capacity and ready?()
    end)

    replacement = Process.whereis(PaseoRelay.Capacity)

    repeated =
      capture_io(fn ->
        PaseoRelay.FlyDiagnostics.kill_capacity(inspect(capacity))
      end)
      |> Jason.decode!()

    assert repeated["status"] == "already_replaced"
    assert Process.alive?(replacement)
  end

  defp ready? do
    port = PaseoRelay.Listener.port(PaseoRelay.Listener)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100)
    :ok = :gen_tcp.send(socket, "GET /ready HTTP/1.1\r\nHost: relay.test\r\n\r\n")
    response = :gen_tcp.recv(socket, 0, 1_500)
    :gen_tcp.close(socket)

    case response do
      {:ok, bytes} -> bytes =~ "HTTP/1.1 200 OK"
      _other -> false
    end
  rescue
    _error -> false
  end

  defp assert_eventually(check, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(check, deadline)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp run_snapshot_validator(path) do
    System.cmd(
      "sh",
      ["-c", ~s(exec node "$1" < "$2"), "snapshot-validator", @snapshot_validator, path],
      stderr_to_stdout: true
    )
  end
end
