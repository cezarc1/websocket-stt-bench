package stt.session

import scala.collection.mutable.ArrayBuffer
import scala.concurrent.ExecutionContext
import scala.concurrent.duration.{DurationLong, FiniteDuration}
import scala.util.{Failure, Random, Success}

import io.circe.parser.decode
import io.circe.syntax.*
import org.apache.pekko.actor.typed.scaladsl.{ActorContext, Behaviors, TimerScheduler}
import org.apache.pekko.actor.typed.{Behavior, PostStop}
import org.apache.pekko.http.scaladsl.model.ws.{BinaryMessage, Message, TextMessage}
import org.apache.pekko.stream.BoundedSourceQueue
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

  /** Periodic flush trigger (started by the start-message handler). Package-private so unit tests can drive a flush
    * without waiting on real timers.
    */
  private[session] case object FlushTick extends Command

  /** Pipe-to-self: inference Future succeeded. Package-private for direct test injection. */
  final private[session] case class InferenceSucceeded(infer: InferResponse, ctx: BatchContext) extends Command

  /** Pipe-to-self: inference Future failed (classified). Package-private for direct test injection. */
  final private[session] case class InferenceFailed(err: InferenceFailure, ctx: BatchContext) extends Command

  private case object FlushTimerKey

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
      new SessionActor(context, timers, config, inference, outbox).behavior
    }
  }

trait SessionOutbox:
  def sendText(payload: String): Unit
  def close(code: Int, reason: String): Unit
  def complete(): Unit

object SessionOutbox:

  def messageQueue(queue: BoundedSourceQueue[Message]): SessionOutbox = new SessionOutbox:
    private var closed = false

    override def sendText(payload: String): Unit =
      if !closed then queue.offer(TextMessage.Strict(payload)): Unit

    override def close(code: Int, reason: String): Unit =
      complete()

    override def complete(): Unit =
      if !closed then
        closed = true
        try queue.complete(): Unit
        catch case _: IllegalStateException => ()

final private class SessionActor(
    context: ActorContext[SessionActor.Command],
    timers: TimerScheduler[SessionActor.Command],
    config: Config,
    inference: InferenceClient,
    outbox: SessionOutbox
):

  import SessionActor.*

  private given ExecutionContext = context.executionContext

  // Mutable state is safe — actor mailbox enforces serial processing.
  private var started: Boolean = false
  private var inflight: Boolean = false
  private var seq: Long = 0L
  private val buffer: ArrayBuffer[Frame] = ArrayBuffer.empty
  private var expectedNextFlushNanos: Long = 0L

  val behavior: Behavior[Command] = Behaviors
    .receiveMessage[Command] {
      case WsMessage(text: TextMessage.Strict) => onText(text.text)
      case WsMessage(_: TextMessage.Streamed) =>
        closeWith(Protocol.CloseProtocolError, Protocol.ReasonNeedStart)
      case WsMessage(bin: BinaryMessage.Strict) => onBinary(bin.data)
      case WsMessage(_: BinaryMessage.Streamed) =>
        closeWith(Protocol.CloseUnsupportedData, Protocol.ReasonBadFrameSize)
      case FlushTick => onFlushTick()
      case InferenceSucceeded(infer, ctx) => onInferenceSucceeded(infer, ctx)
      case InferenceFailed(err, ctx) => onInferenceFailed(err, ctx)
      case WsClosed => Behaviors.stopped
    }
    .receiveSignal { case (_, PostStop) =>
      completeOutbox()
      Behaviors.same
    }

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
    inflight = false
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
    inflight = false
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

  private def enqueue(payload: String): Unit =
    outbox.sendText(payload)

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
