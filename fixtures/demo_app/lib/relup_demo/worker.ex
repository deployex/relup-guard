defmodule RelupDemo.Worker do
  use GenServer

  defstruct counter: 0, label: "v2"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def counter do
    GenServer.call(__MODULE__, :counter)
  end

  def label do
    GenServer.call(__MODULE__, :label)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:counter, _from, state) do
    {:reply, state.counter, state}
  end

  @impl true
  def handle_call(:label, _from, state) do
    {:reply, state.label, state}
  end

  @impl true
  def code_change(_old_vsn, old_state, _extra) do
    {:ok, struct(__MODULE__, Map.put(Map.from_struct(old_state), :label, "v2"))}
  end
end
