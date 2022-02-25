defmodule ExAntiGate.Tasks.HCaptchaTask do
  @moduledoc false

  def defaults,
    do: [
      type: "HCaptchaTask",
      websiteURL: nil,
      websiteKey: nil,
      proxyType: nil,
      proxyAddress: nil,
      proxyPort: nil,
      proxyLogin: nil,
      proxyPassword: nil,
      userAgent: nil
    ]
end
