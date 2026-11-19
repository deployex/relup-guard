defmodule RelupDemoTest do
  use ExUnit.Case
  doctest RelupDemo

  test "greets the world" do
    assert RelupDemo.hello() == :world
  end
end
