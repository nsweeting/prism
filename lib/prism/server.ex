defmodule Prism.Server do
  @moduledoc false

  use GenServer

  ################################
  # Public API
  ################################

  @doc false
  @spec start_link(atom(), Prism.subscribers()) :: GenServer.on_start()
  def start_link(name, subscribers) do
    GenServer.start_link(__MODULE__, {name, subscribers}, name: name)
  end

  ################################
  # GenServer Callbacks
  ################################

  @doc false
  @impl GenServer
  def init({name, subscribers}) do
    init_table(name)

    state =
      name
      |> init_state()
      |> init_subscribers(subscribers)

    {:ok, state}
  end

  @doc false
  @impl GenServer
  def handle_call({:subscribe, handler_id, topics, handler}, _from, state) do
    {state, result} = subscribe(state, handler_id, topics, handler)
    {:reply, result, state}
  end

  def handle_call({:delete, handler_id}, _from, state) do
    {state, results} = delete(state, handler_id)
    {:reply, results, state}
  end

  ################################
  # Private API
  ################################

  defp init_table(table_name) do
    :ets.new(table_name, [
      :named_table,
      :duplicate_bag,
      :protected,
      read_concurrency: true
    ])
  end

  defp init_state(name) do
    %{
      subscribers: MapSet.new(),
      name: name
    }
  end

  defp init_subscribers(state, subscribers) do
    Enum.reduce(subscribers, state, fn {handler_id, topics, handler}, state ->
      subscribe(state, handler_id, topics, handler)
    end)
  end

  defp subscribe(state, handler_id, topics, handler) do
    if MapSet.member?(state.subscribers, handler_id) do
      {state, {:error, :already_exists}}
    else
      update_table(state, topics, handler_id, handler)
      subscribers = MapSet.put(state.subscribers, handler_id)
      state = %{state | subscribers: subscribers}
      {state, :ok}
    end
  end

  defp update_table(_state, [], _handler_id, _handler), do: :ok

  defp update_table(state, [topic | topics], handler_id, handler) do
    case :ets.match(state.name, {topic, {handler_id, :_}}) do
      [] -> :ets.insert(state.name, {topic, {handler_id, handler}})
      _ -> :ok
    end

    update_table(state, topics, handler_id, handler)
  end

  defp delete(state, handler_id) do
    if MapSet.member?(state.subscribers, handler_id) do
      :ets.match_delete(state.name, {:_, {handler_id, :_}})
      subscribers = MapSet.delete(state.subscribers, handler_id)
      state = %{state | subscribers: subscribers}
      {state, :ok}
    else
      {state, {:error, :not_found}}
    end
  end
end
