package stt.session

import scala.concurrent.duration.{DurationInt, FiniteDuration}
import scala.concurrent.{Await, ExecutionContext, Future, Promise}
import scala.util.Try

import io.circe.parser.parse
import munit.FunSuite
import org.apache.pekko.actor.testkit.typed.scaladsl.ActorTestKit
import org.apache.pekko.http.scaladsl.model.ws.{BinaryMessage, Message, TextMessage}
import org.apache.pekko.stream.Materializer
import org.apache.pekko.stream.scaladsl.{Sink, Source}
import org.apache.pekko.util.ByteString
import stt.Config
import stt.inference.{InferenceClient, InferenceFailure}
import stt.protocol.*

final class SessionSpec extends FunSuite:

  private val testKit = ActorTestKit("session-spec")
  private given Materializer = Materializer(testKit.system)

  override def afterAll(): Unit = testKit.shutdownTestKit()

  private val config: Config = Config(
    port = 2500,
    inferenceUrl = "http://stub",
    inferenceTimeout = 1.second,
    inferenceHttpClients = 1,
    cpuPasses = 4,
    modelDelayMs = 75L,
    flushInterval = 1.second,
    flushPhaseJitter = 0.millis,
    partialChannelDepth = 4
  )

  private def newFrame(fill: Byte): BinaryMessage.Strict =
    BinaryMessage.Strict(ByteString(Array.fill[Byte](Protocol.FrameBytes)(fill)))

  /** Spawns the actor with a pre-materialized outbox queue and returns the actor ref plus a Source that consumes from
    * the outbox. Tests pull from the source via `Sink.head`/`Sink.seq`.
    */
  private def spawn(inference: InferenceClient)
      : (org.apache.pekko.actor.typed.ActorRef[SessionActor.Command], Source[Message, ?]) =
    val (queue, source) = Source.queue[Message](config.partialChannelDepth).preMaterialize()
    val ref = testKit.spawn(SessionActor(config, inference, SessionOutbox.messageQueue(queue)))
    (ref, source)

  test("flush builds partial and clears the buffer") {
    val infer = new InferenceClient:
      override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
        Future.successful(InferResponse(1.5, 2L, 3L, 1280L, "now", 1280L))

    val (ref, source) = spawn(infer)
    val first: Future[Message] = source.runWith(Sink.head)

    ref ! SessionActor.WsMessage(TextMessage.Strict("""{"type":"start"}"""))
    ref ! SessionActor.WsMessage(newFrame(0x01.toByte))
    ref ! SessionActor.FlushTick

    val msg = Await.result(first, 2.seconds)
    val text = msg match
      case t: TextMessage.Strict => t.text
      case other => fail(s"expected TextMessage.Strict, got $other")
    val node = parse(text).toOption.get.hcursor
    assertEquals(node.downField("type").as[String], Right("partial"))
    assertEquals(node.downField("oldest_frame_seq").as[Long], Right(1L))
    assertEquals(node.downField("newest_frame_seq").as[Long], Right(1L))
    assertEquals(node.downField("frames").as[Int], Right(1))
  }

  test("second flush is skipped while first is inflight") {
    val calls = java.util.concurrent.atomic.AtomicInteger(0)
    val gate = Promise[InferResponse]()
    val infer = new InferenceClient:
      override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
        calls.incrementAndGet(): Unit
        gate.future

    val (ref, _) = spawn(infer)
    ref ! SessionActor.WsMessage(TextMessage.Strict("""{"type":"start"}"""))
    ref ! SessionActor.WsMessage(newFrame(0x01.toByte))
    ref ! SessionActor.FlushTick

    // Wait briefly for the first inference to have started.
    eventually(1.second, 25.millis)(assertEquals(calls.get, 1))

    // Buffer a second frame and trigger another flush — must be skipped (inflight=true).
    ref ! SessionActor.WsMessage(newFrame(0x02.toByte))
    ref ! SessionActor.FlushTick

    // Give the actor a moment to process the second tick; calls must remain 1.
    Thread.sleep(150)
    assertEquals(calls.get, 1)

    gate.success(InferResponse(0.0, 0L, 0L, 1L, "x", 1L)): Unit
  }

  test("inference failure produces an error envelope on the wire") {
    val infer = new InferenceClient:
      override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
        Future.failed(
          InferenceFailure(
            stage = ErrorStage.InferenceRequest,
            kind = ErrorKind.Timeout,
            detail = "timed out",
            status = None,
            retryable = true
          )
        )

    val (ref, source) = spawn(infer)
    val first: Future[Message] = source.runWith(Sink.head)

    ref ! SessionActor.WsMessage(TextMessage.Strict("""{"type":"start"}"""))
    ref ! SessionActor.WsMessage(newFrame(0x01.toByte))
    ref ! SessionActor.FlushTick

    val msg = Await.result(first, 2.seconds)
    val text = msg match
      case t: TextMessage.Strict => t.text
      case other => fail(s"expected TextMessage.Strict, got $other")
    val node = parse(text).toOption.get.hcursor
    assertEquals(node.downField("type").as[String], Right("error"))
    assertEquals(node.downField("kind").as[String], Right("timeout"))
    assertEquals(node.downField("retryable").as[Boolean], Right(true))
  }

  /** Polls `assertion` every `interval` until `total` has elapsed; throws on the last failure. */
  private def eventually(total: FiniteDuration, interval: FiniteDuration)(assertion: => Unit): Unit =
    val deadline = System.nanoTime() + total.toNanos
    var lastError: Option[Throwable] = None
    var done = false
    while !done && System.nanoTime() < deadline do
      Try(assertion).fold(
        t => {
          lastError = Some(t)
          Thread.sleep(interval.toMillis)
        },
        _ => done = true
      )
    if !done then lastError.foreach(throw _)
