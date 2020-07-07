defmodule Prism do
  @moduledoc """
  Prism is a simple local message broker.

  With this module, you can subscribe handlers to topics. When an event is published
  to the broker - any subscriber of that topic will have its handler function called.
  This permits simple event-driven mechanisms to be implemented within applications.

  Prism avoids the use of processes when publishing events to subscribers. In that
  sense - handlers are all invoked in the publishing process. If you wish something
  to be done "out of band" from the publisher - you will be resposibsle for the
  implementation.

  ## Example

      defmodule MyBroker do
        use Prism

        def start_link(subscribers \\\\ []) do
          Prism.start_link(name: __MODULE__, subscribers: subscribers)
        end

        def subscribe(handler_id, topic_or_topics, handler) do
          Prism.subscribe(__MODULE__, handler_id, topic_or_topics, handler)
        end

        def publish(topic, event) do
          Prism.publish(__MODULE__, topic, event)
        end
      end

      defmodule Callback do
        def call(topic, event) do
          IO.inspect(topic)
          IO.inspect(event)
          :ok
        end
      end

      # Start the broker
      MyBroker.start_link()

      # Subscribe a handler
      MyBroker.subscribe("my_handler", [:my, :topic], &Callback.call/2)

      # Publish to a topic
      MyBroker.publish([:my, :topic], "hello")

  """

  @typedoc "The unique broker identifier"
  @type broker_id :: atom()

  @typedoc "The name of a topic"
  @type topic :: [atom(), ...]

  @typedoc "A list of topics"
  @type topics :: [topic()]

  @typedoc "The unique event handler identifier"
  @type handler_id :: term()

  @typedoc "The custom payload sent to event handlers"
  @type event :: term()

  @typedoc "A function invoked when publishing events"
  @type handler :: (topic(), event() -> any())

  @typedoc "A tuple used to describe a subscriber"
  @type subscriber :: {handler_id(), topics(), handler()}

  @typedoc "A list of subscribers"
  @type subscribers :: [subscriber()]

  @typedoc "The result of a publish for a single event handler"
  @type result :: {handler_id(), term()}

  @typedoc "The result of a publish"
  @type results :: [result()]

  @typedoc "Option values used by `start_link/1`"
  @type option :: {:name, broker_id()} | {:subscribers, subscribers()}

  @typedoc "Options used by `start_link/1`"
  @type options :: [option()]

  alias Prism.Server

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end
    end
  end

  ################################
  # Public API
  ################################

  @doc """
  Starts a message broker process.

  ## Options

    * `:name` - The name of the broker process.
    * `:subscribers` - A list of subscribers to start the broker with.

  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {broker_id, subscribers} = build_options(opts)
    Server.start_link(broker_id, subscribers)
  end

  @doc """
  Subscribes a handler to a topic or topics within the broker.

  `handler_id` must be unique. If another handler with the same ID already exists
  then `{:error, :already_exists}` is returned. `topic_or_topics` is a list or
  list of lists containing atoms that describe an event occurance. `handler` is
  a 2-arity function that is called when an event is published to a subscribed
  topic.

  Due to how anonymous functions are implemented in the Erlang VM, it is best to
  use function captures (i.e. `&Mod.fun/2`) as handlers to achieve maximum performance.
  In other words, avoid using literal anonymous functions (`fn ... -> ... end`) or
  local function captures (`&handle_event/2`) as handlers.

  Please see `publish/3` for information on publishing to subscribers.

  ## Examples

      iex> Prism.subscribe(:my_broker, "my_handler", [:foo, :bar], &Callback.call/2)
      :ok

      iex> Prism.subscribe(:my_broker, "my_handler", [:foo, :bar], &Callback.call/2)
      {:error, :already_exists}

      iex> Prism.subscribe(:my_broker, "my_other_handler", [[:foo, :bar], [:bar, :baz]], &Callback.call/2)
      :ok

  """
  @spec subscribe(broker_id(), handler_id(), topic() | topics(), handler(), timeout()) ::
          :ok | {:error, reason :: atom()}
  def subscribe(broker_id, handler_id, topic_or_topics, handler, timeout \\ 5_000)

  def subscribe(broker_id, handler_id, [topic_part | _] = topic, handler, timeout)
      when is_atom(topic_part) do
    subscribe(broker_id, handler_id, [topic], handler, timeout)
  end

  def subscribe(broker_id, handler_id, topics, handler, timeout)
      when is_atom(broker_id) and is_list(topics) and is_function(handler, 2) do
    assert_topics(topics)
    GenServer.call(broker_id, {:subscribe, handler_id, topics, handler}, timeout)
  end

  @doc """
  Deletes a handler from the broker.

  Handlers that are deleted will no longer recieve events that are published to
  the broker.

  ## Examples

      iex> Prism.subscribe(:my_broker, "my_handler", [:foo, :bar], &Callback.call/2)
      :ok

      iex> Prism.delete(:my_broker, "my_handler")
      :ok

  """
  @spec delete(broker_id(), handler_id(), timeout()) :: :ok | {:error, term()}
  def delete(broker_id, handler_id, timeout \\ 5_000)
      when is_atom(broker_id) do
    GenServer.call(broker_id, {:delete, handler_id}, timeout)
  end

  @doc """
  Publishes an event to subscribers of the given topic.

  Publishing is done in a syncronous manner within the calling process. If you
  need work to be done "out of bound" of the publisher - its your responsibility
  to implement it in that way. Any exceptions raised by a handler will also propagate
  to the publisher.

  This will return a list of results in the format `{handler_id, result}`, where
  `result` is what is returned by the handler.

  ## Examples

      iex> Prism.subscribe(:my_broker, "my_handler", [:foo, :bar], fn topic, event -> {topic, event} end)
      :ok

      iex> Prism.publish(:my_broker, [:foo, :bar], "hello")
      [{"my_handler", {[:foo, :bar], "hello"}}]

  """
  @spec publish(broker_id(), topic(), event()) :: results()
  def publish(broker_id, topic, event) do
    subscribers = :ets.lookup(broker_id, topic)
    do_publish(subscribers, event, [])
  end

  ################################
  # Private API
  ################################

  defp do_publish([], _payload, results), do: results

  defp do_publish([subscriber | subscribers], event, results) do
    results = do_publish(subscriber, event, results)
    do_publish(subscribers, event, results)
  end

  defp do_publish({topic, {handler_id, handler}}, event, results) do
    result = handler.(topic, event)
    [{handler_id, result} | results]
  end

  defp build_options(opts) do
    broker_id = Keyword.get(opts, :name)
    assert_name(broker_id)
    subscribers = Keyword.get(opts, :subscribers, [])
    assert_subscribers(subscribers)
    {broker_id, subscribers}
  end

  defp assert_name(broker_id) when is_atom(broker_id), do: :ok

  defp assert_name(broker_id) do
    raise ArgumentError, "expected name to be an atom, got: #{inspect(broker_id)}"
  end

  defp assert_subscribers([]), do: :ok

  defp assert_subscribers([{_handler_id, topics, handler} | subscribers])
       when is_list(topics) and is_function(handler, 2) do
    assert_topics(topics)
    assert_subscribers(subscribers)
  end

  defp assert_subscribers([subscriber | _]) do
    raise ArgumentError,
          "expected subscriber to be a tuple in the format {handler_id, topics, handler}, got: #{
            inspect(subscriber)
          }"
  end

  defp assert_topics([]), do: :ok

  defp assert_topics([topic | topics]) do
    assert_topic(topic)
    assert_topics(topics)
  end

  defp assert_topic(topic) do
    unless is_list(topic) and length(topic) > 0 and Enum.all?(topic, &is_atom/1) do
      raise ArgumentError,
            "expected subscriber topic to be a list of atoms, got: #{inspect(topic)}"
    end
  end
end
