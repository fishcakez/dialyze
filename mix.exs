defmodule Dialyze.Mixfile do
  use Mix.Project

  def project do
    [app: :dialyze,
     version: "0.1.0",
     elixir: ">= 0.14.0",
     deps: [],
     package: package()]
  end

  def application do
    [applications: [:mix, :dialyzer]]
  end

  defp package() do
    [contributors: ["James Fish"],
      licenses: ["Apache 2.0"],
      links: [{"Github", "https://github.com/fishcakez/dialyze"}]]
  end
end
