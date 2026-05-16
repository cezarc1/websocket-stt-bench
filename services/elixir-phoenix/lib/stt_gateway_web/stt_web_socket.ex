defmodule SttGatewayWeb.SttWebSocket do
  @moduledoc false

  @behaviour WebSock

  alias SttGateway.Protocol.ErrorMessage
  alias SttGateway.Protocol.PartialMessage
  alias SttGateway.Protocol.StartMessage
  alias SttGatewayWeb.SttWebSocket.State

  @frame_bytes 640
  @default_flush_interval_ms 1_000
  @default_cpu_passes 4
  @default_model_delay_ms 75
  @default_flush_phase_jitter_ms 0
  @close_protocol_error 1002
  @close_unsupported_data 1003

  @type ws_in :: {binary(), [opcode: :text | :binary]}
  @type close_payload :: {non_neg_integer(), binary()}

  @spec init(list()) :: {:ok, State.t()}
  @impl true
  def init(_opts) do
    {:ok,
     %State{
       cpu_passes: env_int("CPU_PASSES", @default_cpu_passes),
       model_delay_ms: env_int("MODEL_DELAY_MS", @default_model_delay_ms),
       flush_interval_ms: max(env_int("FLUSH_INTERVAL_MS", @default_flush_interval_ms), 1),
       flush_phase_jitter_ms: env_int("FLUSH_PHASE_JITTER_MS", @default_flush_phase_jitter_ms),
       inference_url: Application.fetch_env!(:stt_gateway, :inference_url),
       finch_name: SttGateway.Application.finch_name()
     }}
  end

  @spec handle_in(ws_in(), State.t()) ::
          {:ok, State.t()} | {:stop, :normal, close_payload(), State.t()}
  @impl true
  def handle_in({payload, [opcode: :text]}, %State{next_due_us: nil} = state) do
    case StartMessage.from_json(payload) do
      {:ok, %StartMessage{}} ->
        # One-time phase jitter de-syncs sessions that connect in a burst.
        initial_delay_ms = state.flush_interval_ms + jitter_offset_ms(state.flush_phase_jitter_ms)
        next_due_us = System.monotonic_time(:microsecond) + initial_delay_ms * 1000
        Process.send_after(self(), :flush, initial_delay_ms)
        {:ok, %{state | next_due_us: next_due_us}}

      :error ->
        close(state, @close_protocol_error, "first message must be start")
    end
  end

  @impl true
  def handle_in({_payload, [opcode: :text]}, state),
    do: close(state, @close_protocol_error, "expected binary PCM frames after start")

  @impl true
  def handle_in({_payload, [opcode: :binary]}, %State{next_due_us: nil} = state),
    do: close(state, @close_protocol_error, "first message must be start")

  @impl true
  def handle_in({payload, [opcode: :binary]}, state)
      when byte_size(payload) == @frame_bytes do
    seq = state.seq + 1
    received_at_us = System.monotonic_time(:microsecond)
    {:ok, %{state | seq: seq, buffer: [{seq, payload, received_at_us} | state.buffer]}}
  end

  @impl true
  def handle_in({_payload, [opcode: :binary]}, state),
    do: close(state, @close_unsupported_data, "expected 640 byte PCM frame")

  @spec handle_info(:flush, State.t()) :: {:ok, State.t()}
  @impl true
  def handle_info(:flush, state) do
    now_us = System.monotonic_time(:microsecond)
    next_due_us = state.next_due_us + state.flush_interval_ms * 1000
    Process.send_after(self(), :flush, max(div(next_due_us - now_us, 1000), 0))
    flush_lateness_ms = max(now_us - state.next_due_us, 0) / 1000.0
    do_flush(state, next_due_us, flush_lateness_ms)
  end

  @spec handle_info({:compute_finished, SttGateway.Inference.result(), map()}, State.t()) ::
          {:ok, State.t()} | {:push, {:text, binary()}, State.t()}
  @impl true
  def handle_info({:compute_finished, {:ok, result}, context}, state) do
    full_context =
      Map.merge(context, %{
        cpu_passes: state.cpu_passes,
        model_delay_ms: state.model_delay_ms,
        inflight_model_jobs: 0
      })

    payload =
      result
      |> PartialMessage.new!(full_context)
      |> PartialMessage.to_json!()

    {:push, {:text, payload}, %{state | busy?: false}}
  end

  @impl true
  def handle_info({:compute_finished, {:error, error_payload}, context}, state) do
    now_us = System.monotonic_time(:microsecond)
    audio_bytes = context.frames * @frame_bytes

    payload =
      ErrorMessage.new!(%{
        stage: error_payload.stage,
        kind: error_payload.kind,
        message: error_payload.message,
        oldest_frame_seq: context.oldest_seq,
        newest_frame_seq: context.newest_seq,
        frames: context.frames,
        audio_bytes: audio_bytes,
        oldest_age_ms: (now_us - context.oldest_received_at_us) / 1000.0,
        newest_age_ms: (now_us - context.newest_received_at_us) / 1000.0,
        flush_lateness_ms: context.flush_lateness_ms,
        inference_elapsed_ms: error_payload.inference_elapsed_ms,
        # Always 1: one-inflight-per-connection invariant from CLAUDE.md.
        inflight_gateway_batches: 1,
        gateway_buffer_frames: length(state.buffer),
        inference_status: error_payload.inference_status,
        retryable: error_payload.retryable
      })
      |> ErrorMessage.to_json!()

    {:push, {:text, payload}, %{state | busy?: false}}
  end

  @spec do_flush(State.t(), integer(), float()) :: {:ok, State.t()}
  defp do_flush(%State{buffer: []} = state, next_due_us, _lateness),
    do: {:ok, %{state | next_due_us: next_due_us}}

  defp do_flush(%State{busy?: true} = state, next_due_us, _lateness),
    do: {:ok, %{state | next_due_us: next_due_us}}

  defp do_flush(state, next_due_us, flush_lateness_ms) do
    # state.buffer is in reverse-receive order, so its head is the newest
    # frame. Read it before reversing to avoid an O(n) List.last walk per
    # flush on the success path.
    {_, _, newest_received_at_us} = hd(state.buffer)
    batch = Enum.reverse(state.buffer)
    {oldest_seq, _, oldest_received_at_us} = hd(batch)

    SttGateway.Inference.request_async(
      Enum.map(batch, fn {_seq, payload, _ts} -> payload end),
      state.cpu_passes,
      %{
        oldest_seq: oldest_seq,
        newest_seq: state.seq,
        frames: state.seq - oldest_seq + 1,
        flush_lateness_ms: flush_lateness_ms,
        oldest_received_at_us: oldest_received_at_us,
        newest_received_at_us: newest_received_at_us
      },
      self(),
      state.inference_url,
      state.finch_name
    )

    {:ok, %{state | buffer: [], next_due_us: next_due_us, busy?: true}}
  end

  @spec terminate(term(), State.t()) :: :ok
  @impl true
  def terminate(_reason, _state), do: :ok

  @spec env_int(String.t(), integer()) :: integer()
  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  @spec jitter_offset_ms(non_neg_integer()) :: non_neg_integer()
  defp jitter_offset_ms(0), do: 0
  defp jitter_offset_ms(max_ms), do: :rand.uniform(max_ms + 1) - 1

  @spec close(State.t(), non_neg_integer(), binary()) ::
          {:stop, :normal, close_payload(), State.t()}
  defp close(state, code, reason), do: {:stop, :normal, {code, reason}, state}
end
