defmodule RelupDemo.Worker do
  use GenServer

  defstruct counter: 0

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def counter do
    GenServer.call(__MODULE__, :counter)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:counter, _from, state) do
    {:reply, state.counter, state}
  end
end
