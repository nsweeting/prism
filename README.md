# Prism

Prism is a simple local message broker.

## Installation

The package can be installed by adding `prism` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:prism, "~> 0.1"}
  ]
end
```

## Documentation

Please see [HexDocs](https://hexdocs.pm/prism) for additional documentation.

## Getting Started

With Prism, you can subscribe handlers to topics. When an event is published
to the broker - any subscriber of that topic will have its handler function called.
This permits simple event-driven mechanisms to be implemented within applications.

Prism avoids the use of processes when publishing events to subscribers. In that
sense - handlers are all invoked in the publishing process. If you wish something
to be done "out of band" from the publisher - you will be resposibsle for the
implementation.

```elixir
defmodule MyBroker do
  # Adds the child_spec/1 callback required to use under a Supervisor
  use Prism

  def start_link(subscribers \\\\ []) do
    Prism.start_link(__MODULE__, subscribers)
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
```