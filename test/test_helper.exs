ExUnit.start()

unless Node.alive?() do
  {_output, 0} = System.cmd("epmd", ["-daemon"])

  {:ok, _node} =
    Node.start(:"paseo_relay_test_#{System.unique_integer([:positive])}", :shortnames)
end
