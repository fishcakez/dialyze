defmodule Dialyze.Mixfile do
  use Mix.Project

  def project do
    [app: :dialyze,
     version: "0.0.1",
     elixir: "~> 0.14.2",
     deps: deps]
  end

  def application do
    [applications: [:mix, :dialyzer]]
  end

  defp deps do
    []
  end
end
