defmodule SttGatewayWeb.SttWebSocketTest do
  use ExUnit.Case, async: false

  alias SttGateway.Inference
  alias SttGatewayWeb.SttWebSocket

  defmodule FakeInference do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(test_pid), do: test_pid

    @impl true
    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      [passes] = get_req_header(conn, "x-cpu-passes")
      send(test_pid, {:infer, body, passes})

      resp =
        JSON.encode!(%{
          rms: 1.0,
          zero_crossings: 0,
          checksum: :erlang.phash2(body),
          samples: div(byte_size(body), 2),
          transcript: "x",
          audio_bytes: byte_size(body)
        })

      send_resp(conn, 200, resp)
    end
  end

  defmodule NonObjectInference do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "[1, 2]")
  end

  # Never reads the request body, so Bandit never opens the HTTP/2 flow-
  # control window past its initial 64 KiB: a larger body cannot be fully sent.
  defmodule HangingInference do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(_conn, _opts), do: Process.sleep(:infinity)
  end

  setup do
    server = start_supervised!({Bandit, plug: {FakeInference, self()}, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, state} = SttWebSocket.init([])
    %{state: %{state | inference_url: "http://127.0.0.1:#{port}"}}
  end

  defp frame(seq), do: :binary.copy(<<seq::16>>, 320)

  defp start!(state) do
    {:ok, state} = SttWebSocket.handle_in({~s({"type":"start"}), [opcode: :text]}, state)
    state
  end

  defp send_frames(state, seqs) do
    Enum.reduce(seqs, state, fn seq, acc ->
      {:ok, acc} = SttWebSocket.handle_in({frame(seq), [opcode: :binary]}, acc)
      acc
    end)
  end

  defp flush(state) do
    {:ok, state} = SttWebSocket.handle_info(:flush, state)
    state
  end

  defp finish(state) do
    assert_receive {:compute_finished, _, _} = msg, 2_000
    {:push, {:text, json}, state} = SttWebSocket.handle_info(msg, state)
    {JSON.decode!(json), state}
  end

  test "invalid first message closes 1002", %{state: state} do
    for msg <- [{"not-json", [opcode: :text]}, {~s({"type":"stop"}), [opcode: :text]}] do
      assert {:stop, :normal, {1002, _}, _} = SttWebSocket.handle_in(msg, state)
    end

    assert {:stop, :normal, {1002, _}, _} =
             SttWebSocket.handle_in({frame(1), [opcode: :binary]}, state)
  end

  test "invalid binary frame size closes 1003", %{state: state} do
    state = start!(state)

    for size <- [0, 10, 639, 641] do
      assert {:stop, :normal, {1003, _}, _} =
               SttWebSocket.handle_in({:binary.copy(<<0>>, size), [opcode: :binary]}, state)
    end
  end

  test "flush posts frames in seq order and echoes the range", %{state: state} do
    state = state |> start!() |> send_frames(1..3) |> flush()

    assert_receive {:infer, body, "4"}, 2_000
    assert body == frame(1) <> frame(2) <> frame(3)

    {partial, state} = finish(state)

    assert %{
             "type" => "partial",
             "oldest_frame_seq" => 1,
             "newest_frame_seq" => 3,
             "frames" => 3,
             "audio_bytes" => 1_920,
             "cpu_passes" => 4,
             "model_delay_ms" => 75
           } = partial

    refute state.busy?
  end

  test "busy guard keeps one request in flight and ranges tile", %{state: state} do
    state = state |> start!() |> send_frames(1..2) |> flush()
    assert_receive {:infer, _, _}, 2_000

    # Flush while the first request is still unacknowledged: no new request.
    state = state |> send_frames([3]) |> flush()
    assert state.busy?
    refute_receive {:infer, _, _}, 100

    {first, state} = finish(state)
    assert {first["oldest_frame_seq"], first["newest_frame_seq"]} == {1, 2}

    state = state |> send_frames([4]) |> flush()
    assert_receive {:infer, body, _}, 2_000
    assert body == frame(3) <> frame(4)

    {second, _state} = finish(state)
    assert {second["oldest_frame_seq"], second["newest_frame_seq"], second["frames"]} == {3, 4, 2}
  end

  test "a crashing inference task still reports and clears busy?", %{state: state} do
    state = state |> start!() |> send_frames(1..2)
    # An unknown Finch pool makes Finch.request raise inside the task.
    state = flush(%{state | finch_name: :no_such_finch})

    {error, state} = finish(state)

    assert %{
             "type" => "error",
             "stage" => "inference_request",
             "kind" => "connection_reset",
             "retryable" => true,
             "oldest_frame_seq" => 1,
             "newest_frame_seq" => 2,
             "frames" => 2
           } = error

    assert error["message"] =~ "inference request crashed"
    refute state.busy?
  end

  test "a non-object JSON body is a parse_error for the batch's range", %{state: state} do
    server =
      start_supervised!({Bandit, plug: NonObjectInference, port: 0, ip: :loopback},
        id: :non_object_inference
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    state = %{state | inference_url: "http://127.0.0.1:#{port}"}
    state = state |> start!() |> send_frames(1..3) |> flush()

    {error, state} = finish(state)

    assert %{
             "type" => "error",
             "stage" => "inference_response_parse",
             "kind" => "parse_error",
             "inference_status" => 200,
             "retryable" => false,
             "oldest_frame_seq" => 1,
             "newest_frame_seq" => 3,
             "frames" => 3
           } = error

    refute state.busy?
  end

  test "the backlog cap is twice the longest wait a healthy flush can see" do
    # (2 s receive_timeout + 1 s until the next tick) = 150 frames, doubled.
    assert SttWebSocket.max_buffered_frames(1_000, 0, 2_000) == 300
    # The phase jitter only delays the first flush, when nothing is in flight.
    assert SttWebSocket.max_buffered_frames(1_000, 1_000, 2_000) == 300
    assert SttWebSocket.max_buffered_frames(1_000, 5_000, 2_000) == 600
    assert SttWebSocket.max_buffered_frames(1_000, 0, 5_000) == 600
  end

  test "a backlog past the cap closes 1013 instead of growing", %{state: state} do
    assert state.max_buffered_frames == 300
    state = state |> start!() |> send_frames(1..300)
    assert state.buffered == 300

    assert {:stop, :normal, {1013, reason}, _} =
             SttWebSocket.handle_in({frame(301), [opcode: :binary]}, state)

    assert reason =~ "backlog"
  end

  test "flushing resets the backlog count, so a flushing session never hits the cap",
       %{state: state} do
    state =
      Enum.reduce(1..20, start!(state), fn batch, acc ->
        acc = acc |> send_frames((batch * 200)..(batch * 200 + 199)) |> flush()
        assert acc.buffered == 0
        {partial, acc} = finish(acc)
        assert partial["type"] == "partial"
        acc
      end)

    refute state.busy?
  end

  # Regression: with Finch.request/3 the task blocked forever in
  # :gen_statem.call once receive_timeout fired mid-body, so the socket stayed
  # busy? and its buffer grew until OOM.
  test "a body larger than the HTTP/2 window still times out and clears busy?",
       %{state: state} do
    server =
      start_supervised!({Bandit, plug: HangingInference, port: 0, ip: :loopback},
        id: :hanging_inference
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    state = %{state | inference_url: "http://127.0.0.1:#{port}"}
    # 200 frames = 125 KiB, about twice the 64 KiB initial stream window.
    state = state |> start!() |> send_frames(1..200) |> flush()

    assert_receive {:compute_finished, _, _} = msg, 3_000
    {:push, {:text, json}, state} = SttWebSocket.handle_info(msg, state)

    assert %{
             "type" => "error",
             "stage" => "inference_request",
             "kind" => "timeout",
             "retryable" => true,
             "oldest_frame_seq" => 1,
             "newest_frame_seq" => 200,
             "frames" => 200
           } = JSON.decode!(json)

    refute state.busy?
  end

  test "request_async always sends :compute_finished" do
    ctx = %{oldest_seq: 1, newest_seq: 1, frames: 1}
    :ok = Inference.request_async([frame(1)], 4, ctx, self(), "http://127.0.0.1:1", :no_such)
    assert_receive {:compute_finished, {:error, %{stage: :inference_request}}, ^ctx}, 2_000
  end
end
