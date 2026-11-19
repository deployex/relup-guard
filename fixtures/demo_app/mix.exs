defmodule RelupDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :relup_demo,
      version: "0.2.1",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        relup_demo: [
          include_executable_for: [:unix],
          steps: [:assemble, &Jellyfish.generate/1, :tar]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :sasl],
      mod: {RelupDemo.Application, []}
    ]
  end

  defp deps do
    [
      {:jellyfish, "~> 0.2"}
    ]
  end
end
