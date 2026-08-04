defmodule PaseoRelay.Protocol do
  @moduledoc false

  @maximum_frame_wire_bytes 32 * 1024 * 1024
  @maximum_client_frame_header_bytes 14
  @maximum_client_frame_payload_bytes @maximum_frame_wire_bytes -
                                        @maximum_client_frame_header_bytes

  # Cowboy exposes one payload limit for both individual frames and assembled
  # fragmented messages. Set it from the stricter masked client-frame contract
  # so the existing 32 MiB wire ceiling is never exceeded.
  @maximum_message_payload_bytes @maximum_client_frame_payload_bytes
  @maximum_control_payload_bytes 64 * 1024

  def maximum_frame_wire_bytes, do: @maximum_frame_wire_bytes
  def maximum_client_frame_payload_bytes, do: @maximum_client_frame_payload_bytes
  def maximum_message_payload_bytes, do: @maximum_message_payload_bytes
  def maximum_control_payload_bytes, do: @maximum_control_payload_bytes
end
