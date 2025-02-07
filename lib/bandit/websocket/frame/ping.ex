defmodule Bandit.WebSocket.Frame.Ping do
  @moduledoc false

  defstruct data: <<>>

  @typedoc "A WebSocket ping frame"
  @type t :: %__MODULE__{data: binary()}

  @spec deserialize(boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(true, <<data::binary>>) when byte_size(data) <= 125 do
    {:ok, %__MODULE__{data: data}}
  end

  def deserialize(true, _payload) do
    {:error, "Invalid ping payload (RFC6455§5.5.2)"}
  end

  def deserialize(false, _payload) do
    {:error, "Cannot have a fragmented ping frame (RFC6455§5.5.2)"}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.Ping

    def serialize(%Ping{} = frame), do: [{0x9, true, frame.data}]
  end
end
