defmodule PaseoRelay.FlyReplayE2E do
  import Bitwise

  @timeout 10_000

  def run(args) do
    {options, [], []} =
      OptionParser.parse(args,
        strict: [
          endpoint: :string,
          owner: :string,
          landing: :string
        ]
      )

    round_trip(options)
  end

  defp round_trip(options) do
    endpoint = Keyword.fetch!(options, :endpoint)
    owner = Keyword.fetch!(options, :owner)
    landing = Keyword.fetch!(options, :landing)
    server_id = "fly-replay-#{System.unique_integer([:positive])}"
    connection_id = "connection-#{System.unique_integer([:positive])}"

    control = connect(endpoint, server_id, "server", nil, owner)
    control = assert_control(control, "sync", nil)
    client = connect(endpoint, server_id, "client", connection_id, landing)
    control = assert_control(control, "connected", connection_id)
    data = connect(endpoint, server_id, "server", connection_id, landing)

    :ok = send_frame(client, :text, "client-to-daemon")
    data = assert_frame(data, :text, "client-to-daemon")
    :ok = send_frame(data, :binary, <<0, 1, 2, 255>>)
    client = assert_frame(client, :binary, <<0, 1, 2, 255>>)
    Enum.each([control, client, data], &close/1)

    print(%{
      status: "ok",
      server_id: server_id,
      owner_machine: owner,
      forced_landing_machine: landing,
      frames: 2
    })
  end

  defp connect(endpoint, server_id, role, connection_id, machine_id) do
    uri = URI.parse(endpoint)
    transport = if uri.scheme == "wss", do: :ssl, else: :gen_tcp
    port = uri.port || if(transport == :ssl, do: 443, else: 80)
    socket = transport_connect(transport, uri.host, port)

    query =
      [serverId: server_id, role: role, connectionId: connection_id, v: 2]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    path = String.trim_trailing(uri.path || "", "/") <> "/ws?#{query}"
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\nHost: ",
      uri.host,
      "\r\n",
      "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n",
      "Sec-WebSocket-Key: ",
      key,
      "\r\nFly-Force-Instance-Id: ",
      machine_id,
      "\r\n\r\n"
    ]

    :ok = transport.send(socket, request)
    {headers, rest} = recv_headers(transport, socket, "")
    unless headers =~ "HTTP/1.1 101", do: raise("WebSocket upgrade failed")
    %{transport: transport, socket: socket, buffer: rest}
  end

  defp transport_connect(:gen_tcp, host, port) do
    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @timeout)

    socket
  end

  defp transport_connect(:ssl, host, port) do
    :ok = Application.ensure_started(:ssl)

    options = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host)
    ]

    {:ok, socket} = :ssl.connect(String.to_charlist(host), port, options, @timeout)
    socket
  end

  defp recv_headers(transport, socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, rest] ->
        {headers, rest}

      [_incomplete] ->
        {:ok, chunk} = transport.recv(socket, 0, @timeout)
        recv_headers(transport, socket, bytes <> chunk)
    end
  end

  defp send_frame(%{transport: transport, socket: socket}, kind, payload) do
    opcode = if kind == :text, do: 1, else: 2
    payload = IO.iodata_to_binary(payload)
    mask = :crypto.strong_rand_bytes(4)
    masked = mask(payload, mask)

    transport.send(socket, [<<0x80 ||| opcode>>, encoded_length(byte_size(payload)), mask, masked])
  end

  defp encoded_length(length) when length < 126, do: <<0x80 ||| length>>
  defp encoded_length(length) when length < 65_536, do: <<0xFE, length::16>>
  defp encoded_length(length), do: <<0xFF, length::64>>

  defp mask(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp assert_control(socket, type, connection_id) do
    case recv_frame(socket) do
      {:text, payload, socket} ->
        message = Jason.decode!(payload)

        if message["type"] == type and
             (is_nil(connection_id) or message["connectionId"] == connection_id) do
          socket
        else
          assert_control(socket, type, connection_id)
        end

      {_kind, _payload, socket} ->
        assert_control(socket, type, connection_id)
    end
  end

  defp assert_frame(socket, kind, payload) do
    case recv_frame(socket) do
      {^kind, ^payload, socket} -> socket
      {_other_kind, _other_payload, socket} -> assert_frame(socket, kind, payload)
    end
  end

  defp recv_frame(socket) do
    {<<first, second>>, socket} = take(socket, 2)
    opcode = first &&& 0x0F
    masked? = (second &&& 0x80) != 0
    {length, socket} = frame_length(socket, second &&& 0x7F)
    {mask_key, socket} = if masked?, do: take(socket, 4), else: {nil, socket}
    {payload, socket} = take(socket, length)
    payload = if mask_key, do: mask(payload, mask_key), else: payload
    kind = if opcode == 1, do: :text, else: :binary
    {kind, payload, socket}
  end

  defp frame_length(socket, 126) do
    {<<length::16>>, socket} = take(socket, 2)
    {length, socket}
  end

  defp frame_length(socket, 127) do
    {<<length::64>>, socket} = take(socket, 8)
    {length, socket}
  end

  defp frame_length(socket, length), do: {length, socket}

  defp take(%{buffer: buffer} = socket, count) when byte_size(buffer) >= count do
    <<wanted::binary-size(^count), rest::binary>> = buffer
    {wanted, %{socket | buffer: rest}}
  end

  defp take(%{transport: transport, socket: raw, buffer: buffer} = socket, count) do
    {:ok, chunk} = transport.recv(raw, 0, @timeout)
    take(%{socket | buffer: buffer <> chunk}, count)
  end

  defp close(%{transport: transport, socket: socket}), do: transport.close(socket)
  defp print(value), do: IO.puts(Jason.encode!(value))
end
