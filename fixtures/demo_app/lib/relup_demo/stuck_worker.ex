defmodule RelupDemo.StuckWorker do
  @moduledoc """
  Deliberately gets stuck forever inside handle_cast, right after boot -
  see the `upgrade-timeout-seconds` self-test job in
  `.github/workflows/ci.yml` for why this exists, and why it lives on
  the `fixtures/stuck-worker` branch rather than `main`.

  gen_server only answers `:sys` system messages (like the suspend
  request `release_handler` sends before a code_change) between
  callback invocations, not while one is still running. A plain
  `receive` with no matching clause, inside a callback that never
  returns, blocks that forever: the suspend request just sits in this
  process's mailbox, unanswered, since control never goes back to
  gen_server's own loop to notice it.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(state) do
    GenServer.cast(self(), :get_stuck)
    {:ok, state}
  end

  @impl true
  def handle_cast(:get_stuck, state) do
    receive do
    after
      :infinity -> :ok
    end

    {:noreply, state}
  end
end
