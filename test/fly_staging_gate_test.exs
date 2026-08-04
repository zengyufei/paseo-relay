defmodule PaseoRelay.FlyStagingGateTest do
  use ExUnit.Case, async: true

  @script "deployment/fly/staging-gate.sh"

  @tag :tmp_dir
  test "validated config writes its summary to the operator artifact directory", %{tmp_dir: dir} do
    {output, status} = run_gate(dir, ["--validate-config"])

    assert status == 0
    assert Jason.decode!(output) == Jason.decode!(File.read!(Path.join(dir, "summary.json")))
    assert Jason.decode!(output)["status"] == "passed"
  end

  @tag :tmp_dir
  test "malformed and privileged port bases retain parseable failure summaries", %{tmp_dir: dir} do
    Enum.each([{"bad", "config.numeric_inputs", "invalid"}, {"0", "config.port_base", 0}], fn
      {port, check, actual} ->
        artifact_dir = Path.join(dir, port)
        {output, status} = run_gate(artifact_dir, ["--validate-config"], port)
        summary = Jason.decode!(File.read!(Path.join(artifact_dir, "summary.json")))

        assert status == 2
        assert Jason.decode!(output) == summary
        assert summary["status"] == "failed"
        assert [%{"check" => ^check, "actual" => ^actual}] = summary["failed_checks"]
    end)
  end

  @tag :tmp_dir
  test "replacement observations are bounded on both sides and retained", %{tmp_dir: dir} do
    Enum.each([{4_999, 1}, {5_000, 0}, {5_750, 0}, {5_751, 1}], fn {elapsed, expected_status} ->
      artifact_dir = Path.join(dir, Integer.to_string(elapsed))

      {output, status} =
        run_gate(artifact_dir, ["--check-replacement-window", Integer.to_string(elapsed)])

      summary = Jason.decode!(output)

      assert status == expected_status
      assert summary == Jason.decode!(File.read!(Path.join(artifact_dir, "summary.json")))

      assert [%{"actual" => ^elapsed, "expected" => %{"lower_ms" => 5_000, "upper_ms" => 5_750}}] =
               summary["key_checks"]
    end)
  end

  @tag :tmp_dir
  test "deployed snapshot validation accepts the diagnostic's inspected Capacity PID", %{
    tmp_dir: dir
  } do
    snapshot = %{
      schema: 1,
      machine_id: "machineA",
      private_ip: "127.0.0.1",
      release_node: "paseo_relay@127.0.0.1",
      capacity_mutation_timeout_ms: 5_000,
      connection_ceiling: 20_000,
      capacity_pid: "#PID<0.986.0>"
    }

    {output, status} = run_snapshot_check(dir, snapshot)

    assert status == 0
    assert Jason.decode!(output)["status"] == "passed"

    {output, status} = run_snapshot_check(dir, %{snapshot | capacity_pid: "<0.986.0>"})

    assert status == 1

    assert [%{"check" => "machine.deployed_config", "node" => "machineA"}] =
             Jason.decode!(output)["failed_checks"]
  end

  @tag :tmp_dir
  test "jq failure still leaves a parseable bounded summary", %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir!(bin)
    File.ln_s!(System.find_executable("false"), Path.join(bin, "jq"))
    artifact_dir = Path.join(dir, "artifacts")

    {_output, status} =
      run_gate(artifact_dir, ["--validate-config"], "bad", [
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")}
      ])

    assert status == 2

    assert Jason.decode!(File.read!(Path.join(artifact_dir, "summary.json")))["failed_checks"] ==
             [
               %{
                 "actual" => "unavailable",
                 "check" => "reporting.jq",
                 "expected" => "working jq",
                 "reason" => "summary construction failed"
               }
             ]
  end

  defp run_gate(dir, arguments, port \\ "41000", extra_env \\ []) do
    System.cmd("sh", [@script | arguments], env: gate_env(dir, port, extra_env))
  end

  defp run_snapshot_check(dir, snapshot) do
    input = Path.join(dir, "snapshot.json")
    File.write!(input, Jason.encode!(snapshot))

    System.cmd(
      "sh",
      [
        "-c",
        ~s(exec sh "$1" --check-snapshot machineA 127.0.0.1 < "$2"),
        "snapshot-check",
        @script,
        input
      ],
      env: gate_env(dir, "41000", [])
    )
  end

  defp gate_env(dir, port, extra_env) do
    [
      {"FLY_API_TOKEN", "test-only"},
      {"PASEO_FLY_ARTIFACT_DIR", dir},
      {"PASEO_FLY_CONFIRM_STAGING_ONLY", "yes"},
      {"PASEO_FLY_APP", "paseo-relay-staging"},
      {"PASEO_FLY_MACHINES", "machineA,machineB,machineC"},
      {"PASEO_FLY_TARGET_MACHINE", "machineA"},
      {"PASEO_FLY_EXPECTED_TIMEOUT_MS", "5000"},
      {"PASEO_FLY_EXPECTED_CONNECTION_CEILING", "20000"},
      {"PASEO_FLY_REPLACEMENT_TOLERANCE_MS", "750"},
      {"PASEO_FLY_MAX_PEAK_BYTES", "1800000000"},
      {"PASEO_FLY_PORT_BASE", port}
    ] ++ extra_env
  end
end
