defmodule PaseoRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :paseo_relay,
      version: "0.1.2",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      # Cowlib's cookie advisory concerns its unused client encoder. Cowboy 2.17
      # rejects the response-splitting advisory's invalid headers server-side.
      hex: [ignore_advisories: ["CVE-2026-43966", "CVE-2026-43969"]],
      deps: deps()
    ]
  end

  def releases do
    standalone? = System.get_env("PASEO_RELAY_STANDALONE_BUILD") == "true"

    [
      paseo_relay: [
        steps: if(standalone?, do: [:assemble, &Burrito.wrap/1], else: [:assemble]),
        include_executables_for: [:unix],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :syn, :cowboy], mod: {PaseoRelay.Application, []}]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:cowboy, "~> 2.17"},
      {:burrito, "== 1.6.0", runtime: false},
      {:dns_cluster, "~> 0.2.0"},
      {:jason, "~> 1.4"},
      {:syn, "~> 3.4"},
      {:websockex, "~> 0.4", only: :test}
    ]
  end
end
