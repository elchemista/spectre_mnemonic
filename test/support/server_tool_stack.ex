defmodule Spectre.Mnemonic.ServerToolTest.Stack do
  @moduledoc false
  use Spectre.Stack

  install Spectre.Mnemonic,
    namespace: :server_tool_test,
    automatic: false,
    bind: [remember: :save_report] do
    isolate_by([:subject])
  end
end
