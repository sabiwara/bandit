defmodule HTTP2ProtocolTest do
  use ConnectionHelpers, async: true

  import Plug.Conn

  setup :https_server

  describe "frame splitting / merging" do
    test "it should handle cases where the request arrives in small chunks", context do
      socket = tls_client(context)

      # Send connection preface, client settings & ping frame one byte at a time
      ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
         <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      |> Stream.unfold(fn
        <<>> -> nil
        <<byte::binary-size(2), rest::binary>> -> {byte, rest}
      end)
      |> Enum.each(fn byte -> :ssl.send(socket, byte) end)

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      socket = tls_client(context)

      # Send connection preface, client settings & ping frame all in one
      :ssl.send(
        socket,
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
          <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>
      )

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "errors and unexpected frames" do
    @tag capture_log: true
    test "it should ignore unknown frame types", context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 0, 254, 0, 0, 0, 0, 0>>)
      assert connection_alive?(socket)
    end

    @tag capture_log: true
    test "it should shut down the connection gracefully when encountering a connection error",
         context do
      socket = tls_client(context)
      exchange_prefaces(socket)
      # Send a bogus SETTINGS frame
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 1>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>}
    end
  end

  describe "connection preface handling" do
    @tag capture_log: true
    test "closes with an error if the HTTP/2 connection preface is not present", context do
      socket = tls_client(context)
      :ssl.send(socket, "PRI * NOPE/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    test "the server should send a SETTINGS frame at start of the connection", context do
      socket = tls_client(context)
      :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
    end
  end

  describe "DATA frames" do
    test "sends end of stream when there is a single data frame", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, true, [
        {":method", "GET"},
        {":path", "/body_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      assert successful_response?(socket, 1, false)
      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    def body_response(conn) do
      conn |> send_resp(200, "OK")
    end

    test "sends multiple DATA frames with last one end of stream when chunking", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, true, [
        {":method", "GET"},
        {":path", "/chunk_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      assert successful_response?(socket, 1, false)
      assert simple_read_body(socket) == {:ok, 1, false, "OK"}
      assert simple_read_body(socket) == {:ok, 1, false, "DOKEE"}
      assert simple_read_body(socket) == {:ok, 1, true, ""}
    end

    def chunk_response(conn) do
      conn
      |> send_chunked(200)
      |> chunk("OK")
      |> elem(1)
      |> chunk("DOKEE")
      |> elem(1)
    end

    test "reads a zero byte body if none is sent", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, true, [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      # A zero byte body being written will cause end_stream to be set on the header frame
      assert successful_response?(socket, 1, true)
    end

    def echo(conn) do
      {:ok, body, conn} = read_body(conn)
      conn |> send_resp(200, body)
    end

    test "reads a one frame body if one frame is sent", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, false, [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      simple_send_body(socket, 1, true, "OK")

      assert successful_response?(socket, 1, false)
      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    test "reads a multi frame body if many frames are sent", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, false, [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      simple_send_body(socket, 1, false, "OK")
      simple_send_body(socket, 1, true, "OK")

      assert successful_response?(socket, 1, false)
      assert simple_read_body(socket) == {:ok, 1, true, "OKOK"}
    end

    @tag :skip
    test "rejects DATA frames received on a closed stream", _context do
      # TODO - wait for RST support in 0.3.2
    end

    @tag capture_log: true
    test "rejects DATA frames received on a zero stream id", context do
      socket = setup_connection(context)

      simple_send_body(socket, 0, true, "OK")
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>}
    end

    @tag capture_log: true
    test "rejects DATA frames received on an invalid stream id", context do
      socket = setup_connection(context)

      simple_send_body(socket, 2, true, "OK")
      assert connection_alive?(socket) == true
    end
  end

  describe "HEADERS frames" do
    test "sends end of stream headers when there is no body", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, true, [
        {":method", "GET"},
        {":path", "/no_body_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      assert simple_read_headers(socket) ==
               {:ok, 1, true,
                [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}]}
    end

    def no_body_response(conn) do
      conn |> send_resp(200, <<>>)
    end

    test "sends non-end of stream headers when there is a body", context do
      socket = setup_connection(context)

      simple_send_headers(socket, 1, true, [
        {":method", "GET"},
        {":path", "/body_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ])

      assert simple_read_headers(socket) ==
               {:ok, 1, false,
                [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}]}

      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers without padding or priority", context do
      socket = setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send unadorned headers
      :ssl.send(socket, [<<0, 0, byte_size(headers), 1, 0x04, 0, 0, 0, 1>>, headers])

      assert simple_read_headers(socket) ==
               {:ok, 1, false,
                [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}]}

      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with priority", context do
      socket = setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with priority
      :ssl.send(socket, [
        <<0, 0, byte_size(headers) + 5, 1, 0x24, 0, 0, 0, 1>>,
        <<0, 0, 0, 1, 5>>,
        headers
      ])

      assert simple_read_headers(socket) ==
               {:ok, 1, false,
                [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}]}

      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding", context do
      socket = setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding
      :ssl.send(socket, [
        <<0, 0, byte_size(headers) + 5, 1, 0x0C, 0, 0, 0, 1>>,
        <<4>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert simple_read_headers(socket) ==
               {:ok, 1, false,
                [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}]}

      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding and priority", context do
      socket = setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding and priority
      :ssl.send(socket, [
        <<0, 0, byte_size(headers) + 10, 1, 0x2C, 0, 0, 0, 1>>,
        <<4, 0, 0, 0, 0, 1>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert simple_read_headers(socket) ==
               {:ok, 1, false,
                [{":status", "200"}, {"cache-control", "max-age=0, private, must-revalidate"}]}

      assert simple_read_body(socket) == {:ok, 1, true, "OK"}
    end

    def headers_for_header_read_test(context) do
      headers = [
        {":method", "HEAD"},
        {":path", "/header_read_test"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"x-request-header", "Request"}
      ]

      ctx = HPack.Table.new(4096)
      {:ok, _, headers} = HPack.encode(headers, ctx)
      headers
    end

    def header_read_test(conn) do
      assert get_req_header(conn, "x-request-header") == ["Request"]

      conn |> send_resp(200, "OK")
    end

    @tag capture_log: true
    test "closes with an error when receiving a zero stream ID",
         context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 5, 1, 0x04, 0, 0, 0, 0, 64, 129, 31, 129, 31>>)

      assert :ssl.recv(socket, 17) ==
               {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>}

      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    test "closes with an error when receiving an even stream ID",
         context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 5, 1, 0x04, 0, 0, 0, 98, 64, 129, 31, 129, 31>>)

      assert :ssl.recv(socket, 17) ==
               {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>}

      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    test "closes with an error when receiving a stream ID we've already seen",
         context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 5, 1, 0x04, 0, 0, 0, 99, 64, 129, 31, 129, 31>>)
      :ssl.send(socket, <<0, 0, 5, 1, 0x04, 0, 0, 0, 99, 64, 129, 31, 129, 31>>)

      assert :ssl.recv(socket, 17) ==
               {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 1>>}

      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    test "closes with an error on a header frame with undecompressable header block", context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 11, 1, 0x2C, 0, 0, 0, 1, 2, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9>>}
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end
  end

  describe "SETTINGS frames" do
    test "the server should acknowledge a client's SETTINGS frames", context do
      socket = tls_client(context)
      exchange_prefaces(socket)
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
    end
  end

  describe "PING frames" do
    test "the server should acknowledge a client's PING frames", context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "GOAWAY frames" do
    test "the server should close the connection upon receipt of a GOAWAY frame", context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    test "the server should return the last received stream id in the GOAWAY frame", context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 5, 1, 0x04, 0, 0, 0, 99, 64, 129, 31, 129, 31>>)
      :ssl.send(socket, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)

      assert :ssl.recv(socket, 17) ==
               {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 0>>}

      assert :ssl.recv(socket, 0) == {:error, :closed}
    end
  end
end
