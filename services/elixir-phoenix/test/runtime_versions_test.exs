defmodule SttGateway.RuntimeVersionsTest do
  use ExUnit.Case, async: true

  test "runtime helper can read OTP version" do
    assert SttGateway.RuntimeVersions.otp_version() == "28.5"
  end
end
