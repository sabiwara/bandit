defmodule Bandit.HTTP2.Frame.Ping do
  @moduledoc false

  import Bandit.HTTP2.Frame.Flags

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  defstruct ack: false, payload: nil

  @typedoc "An HTTP/2 PING frame"
  @type t :: %__MODULE__{
          ack: boolean(),
          payload: iodata()
        }

  @ack_bit 0

  @spec deserialize(Frame.flags(), Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Connection.error()}
  def deserialize(flags, 0, <<payload::binary-size(8)>>) when set?(flags, @ack_bit) do
    {:ok, %__MODULE__{ack: true, payload: payload}}
  end

  def deserialize(flags, 0, <<payload::binary-size(8)>>) when clear?(flags, @ack_bit) do
    {:ok, %__MODULE__{ack: false, payload: payload}}
  end

  def deserialize(_flags, stream_id, _payload) when stream_id != 0 do
    {:error,
     {:connection, Errors.protocol_error(), "Invalid stream ID in PING frame (RFC7540§6.7)"}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Errors.frame_size_error(),
      "PING frame with invalid payload size (RFC7540§6.7)"}}
  end

  defimpl Frame.Serializable do
    alias Bandit.HTTP2.Frame.Ping

    @ack_bit 0

    def serialize(%Ping{ack: true} = frame, _max_frame_size),
      do: [{0x6, set([@ack_bit]), 0, frame.payload}]

    def serialize(%Ping{ack: false} = frame, _max_frame_size),
      do: [{0x6, 0x0, 0, frame.payload}]
  end
end
