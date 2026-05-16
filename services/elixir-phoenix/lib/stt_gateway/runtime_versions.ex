defmodule SttGateway.RuntimeVersions do
  @moduledoc false

  require Logger

  @expected_elixir "1.19.5"
  @expected_otp "28.5"

  def assert!(inference_url \\ "unset", finch_pool_count \\ nil) do
    elixir = System.version()
    otp = otp_version()
    phoenix = app_version(:phoenix)
    bandit = app_version(:bandit)
    finch = app_version(:finch)

    Logger.info(
      "runtime_versions runtime=elixir-phoenix elixir=#{elixir} otp=#{otp} " <>
        "phoenix=#{phoenix} adapter=bandit bandit=#{bandit} finch=#{finch} " <>
        "inference_url=#{inference_url} finch_pool_count=#{finch_pool_count} " <>
        "schedulers=#{System.schedulers_online()}"
    )

    unless elixir == @expected_elixir do
      raise "expected Elixir #{@expected_elixir}, got #{elixir}"
    end

    unless otp == @expected_otp do
      raise "expected Erlang/OTP #{@expected_otp}, got #{otp}"
    end

    :ok
  end

  defp app_version(app) do
    app |> Application.spec(:vsn) |> List.to_string()
  end

  def otp_version do
    otp_major = :erlang.system_info(:otp_release) |> List.to_string()

    [:code.root_dir() |> List.to_string(), "releases", otp_major, "OTP_VERSION"]
    |> Path.join()
    |> File.read()
    |> case do
      {:ok, version} -> String.trim(version)
      _ -> otp_major
    end
  end
end
