defmodule ExAntiGate.Tasks.AntiGateTask do
  @moduledoc false

  def defaults,
    do: [
      type: "AntiGateTask",
      websiteURL: nil,
      templateName: nil,
      variables: nil,
      proxyAddress: nil,
      proxyPort: nil,
      proxyLogin: nil,
      proxyPassword: nil
    ]
end
