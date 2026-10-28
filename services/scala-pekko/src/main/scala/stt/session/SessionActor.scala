package stt.session

import scala.collection.mutable.ArrayBuffer
import scala.concurrent.duration.{DurationInt, DurationLong, FiniteDuration}
import scala.concurrent.{ExecutionContext, Future}
import scala.util.{Failure, Random, Success}

import io.circe.parser.decode
import io.circe.syntax.*
import org.apache.pekko.actor.typed.scaladsl.{ActorContext, Behaviors, StashBuffer, TimerScheduler}
import org.apache.pekko.actor.typed.{Behavior, PostStop}
import org.apache.pekko.http.scaladsl.model.ws.{BinaryMessage, Message, TextMessage}
import org.apache.pekko.stream.{BoundedSourceQueue, Materializer, QueueOfferResult, SystemMaterializer}
import org.apache.pekko.util.ByteString
import stt.Config
import stt.inference.{InferenceClient, InferenceFailure}
import stt.protocol.*

/** Per-connection actor. Owns the per-session state machine; the actor mailbox enforces the "one inflight inference per
  * connection" invariant by construction — no semaphore, no CAS, no `synchronized` block. Messages are processed
  * serially in mailbox order.
  *
  * The closest semantic sibling is `services/elixir-phoenix/lib/.../stt_web_socket.ex`, which is the GenServer the
  * Akka/Pekko model was designed to imitate. Comparing them per-vCPU is the load-bearing reason this gateway exists.
  */
object SessionActor:

  sealed trait Command

  /** Inbound WS message (text or binary). Dispatched by the actor based on message shape. */
  final case class WsMessage(message: Message) extends Command

  /** WS Sink completed or failed — the actor stops itself. */
  case object WsClosed extends Command

  /** Pipe-to-self: collecting a fragmented WS message failed; close with the given code. */
  final private[session] case class CloseRequested(code: Int, reason: String) extends Command

  /** Periodic flush trigger (started by the start-message handler). Package-private so unit tests can drive a flush
    * without waiting on real timers.
    */
  private[session] case object FlushTick extends Command

  /** Pipe-to-self: inference Future succeeded. Package-private for direct test injection. */
  final private[session] case class InferenceSucceeded(infer: InferResponse, ctx: BatchContext) extends Command

  /** Pipe-to-self: inference Future failed (classified). Package-private for direct test injection. */
  final private[session] case class InferenceFailed(err: InferenceFailure, ctx: BatchContext) extends Command

  /** Pipe-to-self: a fragmented (`Streamed`) WS message has been collected into its `Strict` form. */
  final private[session] case class StrictReady(message: Message) extends Command

  private case object FlushTimerKey

  /** Upper bound on WS messages stashed while a fragmented message is being collected. The outer WS stream cannot emit
    * the next message until the fragmented one is fully consumed, so in practice this holds at most one or two.
    */
  private val StashCapacity: Int = 1024

  /** Deadline for collecting a fragmented WS message into its `Strict` form. */
  private val StreamedMessageTimeout: FiniteDuration = 5.seconds

  /** Per-flush context captured at flush time; shared by success and error paths via pipeToSelf. */
  final private[session] case class BatchContext(
      oldestSeq: Long,
      newestSeq: Long,
      frames: Int,
      bodyBytes: Int,
      flushLatenessMs: Double,
      startedAtNanos: Long,
      oldestReceivedAtNanos: Long,
      newestReceivedAtNanos: Long
  )

  def apply(
      config: Config,
      inference: InferenceClient,
      outbox: SessionOutbox
  ): Behavior[Command] = Behaviors.setup { context =>
    Behaviors.withTimers { timers =>
      Behaviors.withStash(StashCapacity) { stash =>
        new SessionActor(context, timers, stash, config, inference, outbox).behavior
      }
    }
  }

trait SessionOutbox:

  /** Offers `payload` to the socket. Returns `false` only when the outbound buffer is full (client back-pressure); the
    * caller must retry later rather than drop it. A closed outbox swallows the payload and returns `true`.
    */
  def sendText(payload: String): Boolean
  def close(code: Int, reason: String): Unit
  def complete(): Unit

/** Close code + reason the session chose for an explicit close. Written by the session actor before it completes the
  * outbound stream; read by the transport when it renders the WebSocket close frame (see
  * `org.apache.pekko.http.impl.engine.ws.SttWebSocket`). `code == 0` means "no explicit code" (normal 1000).
  */
final class CloseIntent:
  @volatile private var closeCode: Int = 0
  @volatile private var closeReason: String = ""

  def set(code: Int, reason: String): Unit =
    closeReason = reason
    closeCode = code

  def code: Int = closeCode
  def reason: String = closeReason

object SessionOutbox:

  def messageQueue(queue: BoundedSourceQueue[Message], closeIntent: CloseIntent): SessionOutbox = new SessionOutbox:
    private var closed = false

    override def sendText(payload: String): Boolean =
      closed || (queue.offer(TextMessage.Strict(payload)) ne QueueOfferResult.Dropped)

    override def close(code: Int, reason: String): Unit =
      if !closed then closeIntent.set(code, reason)
      complete()

    override def complete(): Unit =
      if !closed then
        closed = true
        try queue.complete(): Unit
        catch case _: IllegalStateException => ()

final private class SessionActor(
    context: ActorContext[SessionActor.Command],
    timers: TimerScheduler[SessionActor.Command],
    stash: StashBuffer[SessionActor.Command],
    config: Config,
    inference: InferenceClient,
    outbox: SessionOutbox
):

  import SessionActor.*

  private given ExecutionContext = context.executionContext
  private given Materializer = SystemMaterializer(context.system).materializer

  // Mutable state is safe — actor mailbox enforces serial processing.
  private var started: Boolean = false
  private var inflight: Boolean = false
  private var seq: Long = 0L
  private val buffer: ArrayBuffer[Frame] = ArrayBuffer.empty
  private var expectedNextFlushNanos: Long = 0L

  /** Partial/error envelope the outbound buffer refused (client back-pressure). While set, `inflight` stays true, so —
    * like the Rust gateway's awaited `send` — back-pressure holds the one-inflight slot instead of dropping a frame
    * range.
    */
  private var pendingOutbound: Option[String] = None

  def behavior: Behavior[Command] = Behaviors
    .receiveMessage[Command] {
      case WsMessage(message) => onWsMessage(message)
      case other => onInternal(other)
    }
    .receiveSignal { case (_, PostStop) =>
      completeOutbox()
      Behaviors.same
    }

  /** A fragmented WS message is being collected; later WS messages are stashed to preserve frame order. */
  private def awaitingStrict: Behavior[Command] = Behaviors
    .receiveMessage[Command] {
      case StrictReady(message) =>
        val next = onWsMessage(message)
        if next eq Behaviors.same[Command] then stash.unstashAll(behavior) else next
      case ws: WsMessage =>
        stash.stash(ws): Unit
        Behaviors.same
      case other => onInternal(other)
    }
    .receiveSignal { case (_, PostStop) =>
      completeOutbox()
      Behaviors.same
    }

  private def onWsMessage(message: Message): Behavior[Command] = message match
    case text: TextMessage.Strict => onText(text.text)
    case bin: BinaryMessage.Strict => onBinary(bin.data)
    // A frame split across TCP reads surfaces as `Streamed` even when it is a valid 640-byte frame; collect it
    // instead of rejecting it. Off the hot path: complete frames always arrive `Strict`.
    case text: TextMessage.Streamed =>
      collectStreamed(text.toStrict(StreamedMessageTimeout), Protocol.CloseProtocolError, Protocol.ReasonNeedStart)
    case bin: BinaryMessage.Streamed =>
      collectStreamed(bin.toStrict(StreamedMessageTimeout), Protocol.CloseUnsupportedData, Protocol.ReasonBadFrameSize)

  private def collectStreamed(strict: Future[Message], failCode: Int, failReason: String): Behavior[Command] =
    context.pipeToSelf(strict) {
      case Success(message) => StrictReady(message)
      case Failure(_) => CloseRequested(failCode, failReason)
    }
    awaitingStrict

  private def onInternal(command: Command): Behavior[Command] = command match
    case FlushTick => onFlushTick()
    case InferenceSucceeded(infer, ctx) => onInferenceSucceeded(infer, ctx)
    case InferenceFailed(err, ctx) => onInferenceFailed(err, ctx)
    case CloseRequested(code, reason) => closeWith(code, reason)
    case WsClosed => Behaviors.stopped
    case WsMessage(_) | StrictReady(_) => Behaviors.unhandled

  private def onText(text: String): Behavior[Command] =
    if started then closeWith(Protocol.CloseProtocolError, Protocol.ReasonTextAfterStart)
    else
      decode[StartMessage](text) match
        case Right(_) =>
          started = true
          scheduleFlush()
          Behaviors.same
        case Left(_) => closeWith(Protocol.CloseProtocolError, Protocol.ReasonNeedStart)

  private def onBinary(payload: ByteString): Behavior[Command] =
    if !started then closeWith(Protocol.CloseProtocolError, Protocol.ReasonNeedStart)
    else if payload.size != Protocol.FrameBytes then
      closeWith(Protocol.CloseUnsupportedData, Protocol.ReasonBadFrameSize)
    else
      seq += 1
      buffer += Frame(seq, payload.toArray, System.nanoTime())
      Behaviors.same

  private def scheduleFlush(): Unit =
    val jitterNanos =
      if config.flushPhaseJitter.toNanos == 0L then 0L
      else (Random.nextDouble() * config.flushPhaseJitter.toNanos.toDouble).toLong
    val initial: FiniteDuration = (config.flushInterval.toNanos + jitterNanos).nanos
    expectedNextFlushNanos = System.nanoTime() + initial.toNanos
    timers.startTimerAtFixedRate(FlushTimerKey, FlushTick, initial, config.flushInterval)

  private def onFlushTick(): Behavior[Command] =
    val now = System.nanoTime()
    val flushLatenessMs = math.max(0L, now - expectedNextFlushNanos) / 1_000_000.0
    expectedNextFlushNanos += config.flushInterval.toNanos

    pendingOutbound.foreach { payload =>
      if outbox.sendText(payload) then
        pendingOutbound = None
        inflight = false
    }

    if inflight || buffer.isEmpty then Behaviors.same
    else
      inflight = true
      val batch: Array[Frame] = buffer.toArray
      buffer.clear()
      val body = concatFrames(batch)
      val oldest = batch(0)
      val newest = batch(batch.length - 1)
      val ctx = BatchContext(
        oldestSeq = oldest.seq,
        newestSeq = newest.seq,
        frames = batch.length,
        bodyBytes = body.length,
        flushLatenessMs = flushLatenessMs,
        startedAtNanos = now,
        oldestReceivedAtNanos = oldest.receivedAtNanos,
        newestReceivedAtNanos = newest.receivedAtNanos
      )

      context.pipeToSelf(inference.infer(body, config.cpuPasses)) {
        case Success(infer) => InferenceSucceeded(infer, ctx)
        case Failure(f: InferenceFailure) => InferenceFailed(f, ctx)
        case Failure(other) =>
          InferenceFailed(
            InferenceFailure(
              stage = ErrorStage.InferenceRequest,
              kind = ErrorKind.ConnectionReset,
              detail = Option(other.getMessage).getOrElse(other.getClass.getSimpleName),
              status = None,
              retryable = true,
              cause = Some(other)
            ),
            ctx
          )
      }
      Behaviors.same

  private def onInferenceSucceeded(infer: InferResponse, ctx: BatchContext): Behavior[Command] =
    val partial = PartialMessage.of(
      infer = infer,
      oldestSeq = ctx.oldestSeq,
      newestSeq = ctx.newestSeq,
      frames = ctx.frames,
      cpuPasses = config.cpuPasses,
      modelDelayMs = config.modelDelayMs,
      flushLatenessMs = ctx.flushLatenessMs
    )
    enqueue(partial.asJson.noSpaces)
    Behaviors.same

  private def onInferenceFailed(err: InferenceFailure, ctx: BatchContext): Behavior[Command] =
    val now = System.nanoTime()
    val errMsg = ErrorMessage(
      `type` = Protocol.ErrorType,
      stage = err.stage,
      kind = err.kind,
      message = err.detail,
      oldestFrameSeq = ctx.oldestSeq,
      newestFrameSeq = ctx.newestSeq,
      frames = ctx.frames,
      audioBytes = ctx.bodyBytes,
      oldestAgeMs = elapsedMs(now, ctx.oldestReceivedAtNanos),
      newestAgeMs = elapsedMs(now, ctx.newestReceivedAtNanos),
      flushLatenessMs = ctx.flushLatenessMs,
      inferenceElapsedMs = Some(elapsedMs(now, ctx.startedAtNanos)),
      inflightGatewayBatches = 1,
      gatewayBufferFrames = buffer.size,
      inferenceStatus = err.status,
      retryable = err.retryable
    )
    enqueue(errMsg.asJson.noSpaces)
    Behaviors.same

  /** Releases the inflight slot once the envelope is accepted; otherwise parks it for retry on the next tick. */
  private def enqueue(payload: String): Unit =
    if outbox.sendText(payload) then inflight = false
    else pendingOutbound = Some(payload)

  private def closeWith(code: Int, reason: String): Behavior[Command] =
    outbox.close(code, reason)
    Behaviors.stopped

  private def completeOutbox(): Unit =
    outbox.complete()

  private def concatFrames(batch: Array[Frame]): Array[Byte] =
    val body = new Array[Byte](batch.length * Protocol.FrameBytes)
    var offset = 0
    var i = 0
    while i < batch.length do
      val payload = batch(i).payload
      System.arraycopy(payload, 0, body, offset, payload.length)
      offset += payload.length
      i += 1
    body

  private def elapsedMs(nowNanos: Long, earlierNanos: Long): Double =
    math.max(0L, nowNanos - earlierNanos) / 1_000_000.0
