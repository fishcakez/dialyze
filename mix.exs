defmodule Dialyze.Mixfile do
  use Mix.Project

  def project do
    [app: :dialyze,
     version: "0.2.0",
     elixir: "~> 0.14.3 or ~> 0.15.0 or ~> 1.0",
     description: "Dialyzer mix task",
     deps: [],
     aliases: [install: ["compile", "archive.build", "archive.install --force"]],
     package: package()]
  end

  def application do
    [applications: [:mix, :dialyzer]]
  end

  defp package() do
    [files: ["lib", "mix.exs", "README.md", "LICENSE"],
      contributors: ["James Fish"],
      licenses: ["Apache 2.0"],
      links: %{"Github" => "https://github.com/fishcakez/dialyze"}]
  end
end
