defmodule Veridian.MixProject do
  use Mix.Project

  def project do
    [
      app: :veridian,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      dialyzer: dialyzer()
    ]
  end

  # The PLTs (Ash and its dependencies) are large and slow to build: kept per
  # user outside the synced tree, shared by all checkouts.
  defp dialyzer do
    plts = Path.join(System.user_home!(), ".local/state/veridian-dialyzer")

    [
      plt_local_path: plts,
      plt_core_path: plts,
      plt_add_apps: [:mix, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :unknown, :extra_return, :missing_return]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Veridian.Application, []}]
  end

  # Test support (ITF reader, model adapters) is compiled only in :test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.31"},
      {:ash_postgres, "~> 2.0"},
      {:jason, "~> 1.4"},
      # Ash requires it in every environment; our tests also use it.
      {:stream_data, "~> 1.4"},
      # Static analysis of the @specs (D-072: typing). Not a runtime dependency.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
