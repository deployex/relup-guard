defmodule RelupDemo.Worker2 do
  @moduledoc """
  Deliberately a new supervisor child with no corresponding `apply`
  instruction in its appup - see the `fail-on-relup-warnings` self-test
  job in `.github/workflows/ci.yml` for why this exists.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  end

  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end
end
