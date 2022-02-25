defmodule ExAntiGate.Tasks.HCaptchaTaskProxyless do
  @moduledoc false

  def defaults,
    do: [
      type: "HCaptchaTaskProxyless",
      websiteURL: nil,
      websiteKey: nil
    ]
end
