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
    val ref = testKit.spawn(SessionActor(config, inference, SessionOutbox.messageQueue(queue, CloseIntent())))
    (ref, source)

  /** Records sends/closes; refuses the first `refuse` sends to simulate a full outbound buffer. */
  final private class RecordingOutbox(refuse: Int = 0) extends SessionOutbox:
    private val refused = java.util.concurrent.atomic.AtomicInteger(0)
    val sent = java.util.concurrent.ConcurrentLinkedQueue[String]()
    val closes = java.util.concurrent.ConcurrentLinkedQueue[Int]()

    override def sendText(payload: String): Boolean =
      if refused.getAndIncrement() < refuse then false
      else
        sent.add(payload): Unit
        true

    override def close(code: Int, reason: String): Unit = closes.add(code): Unit
    override def complete(): Unit = ()

  private val okInference: InferenceClient = new InferenceClient:
    override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
      Future.successful(InferResponse(0.0, 0L, 0L, (body.length / 2).toLong, "x", body.length.toLong))

  private val start = SessionActor.WsMessage(TextMessage.Strict("""{"type":"start"}"""))

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
      case other => fail(s"expected TextMessage.Strict, got ${other.getClass.getName}")
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
      case other => fail(s"expected TextMessage.Strict, got ${other.getClass.getName}")
    val node = parse(text).toOption.get.hcursor
    assertEquals(node.downField("type").as[String], Right("error"))
    assertEquals(node.downField("kind").as[String], Right("timeout"))
    assertEquals(node.downField("retryable").as[Boolean], Right(true))
  }

  test("fragmented (Streamed) 640-byte frame is reassembled in order, not rejected") {
    val bodies = java.util.concurrent.ConcurrentLinkedQueue[Array[Byte]]()
    val infer = new InferenceClient:
      override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
        bodies.add(body): Unit
        Future.successful(InferResponse(0.0, 0L, 0L, 640L, "x", body.length.toLong))
    val outbox = RecordingOutbox()
    val ref = testKit.spawn(SessionActor(config, infer, outbox))

    val first = Array.fill[Byte](Protocol.FrameBytes)(0x01)
    val split = Array.tabulate[Byte](Protocol.FrameBytes)(i => (i % 7).toByte)
    ref ! start
    ref ! SessionActor.WsMessage(newFrame(0x01))
    ref ! SessionActor.WsMessage(
      BinaryMessage.Streamed(Source(List(ByteString(split.take(100)), ByteString(split.drop(100)))))
    )
    ref ! SessionActor.WsMessage(newFrame(0x03))
    // Let the fragmented frame finish collecting; a tick during collection would (correctly) flush only 1..1.
    Thread.sleep(200)
    ref ! SessionActor.FlushTick
    eventually(1.second, 10.millis)(assertEquals(outbox.sent.size, 1))
    assertEquals(outbox.closes.size, 0)
    val body = bodies.peek()
    assertEquals(body.length, 3 * Protocol.FrameBytes)
    assertEquals(body.take(640).toSeq, first.toSeq)
    assertEquals(body.slice(640, 1280).toSeq, split.toSeq)
    assertEquals(body.drop(1280).toSeq, Array.fill[Byte](640)(0x03).toSeq)
    val node = parse(outbox.sent.peek()).toOption.get.hcursor
    assertEquals(node.downField("oldest_frame_seq").as[Long], Right(1L))
    assertEquals(node.downField("newest_frame_seq").as[Long], Right(3L))
  }

  test("fragmented frame of the wrong size still closes 1003") {
    val outbox = RecordingOutbox()
    val ref = testKit.spawn(SessionActor(config, okInference, outbox))
    ref ! start
    ref ! SessionActor.WsMessage(BinaryMessage.Streamed(Source(List(
      ByteString(new Array[Byte](600)),
      ByteString(new Array[Byte](41))
    ))))
    eventually(1.second, 10.millis)(assertEquals(outbox.closes.peek(), Protocol.CloseUnsupportedData))
  }

  test("invalid input records the contract close code") {
    val cases = List[(List[Message], Int)](
      List(TextMessage.Strict("not-json")) -> Protocol.CloseProtocolError,
      List(TextMessage.Strict("""{"type":"stop"}""")) -> Protocol.CloseProtocolError,
      List(newFrame(0x01)) -> Protocol.CloseProtocolError,
      List(start.message, BinaryMessage.Strict(ByteString(new Array[Byte](641)))) -> Protocol.CloseUnsupportedData,
      List(start.message, BinaryMessage.Strict(ByteString.empty)) -> Protocol.CloseUnsupportedData
    )
    cases.foreach { (messages, code) =>
      val (queue, _) = Source.queue[Message](config.partialChannelDepth).preMaterialize()
      val intent = CloseIntent()
      val ref = testKit.spawn(SessionActor(config, okInference, SessionOutbox.messageQueue(queue, intent)))
      messages.foreach(m => ref ! SessionActor.WsMessage(m))
      eventually(1.second, 10.millis)(assertEquals(intent.code, code))
    }
  }

  test("full outbound buffer holds the inflight slot instead of dropping the partial") {
    val calls = java.util.concurrent.atomic.AtomicInteger(0)
    val infer = new InferenceClient:
      override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
        calls.incrementAndGet(): Unit
        Future.successful(InferResponse(0.0, 0L, 0L, 320L, "x", body.length.toLong))
    val outbox = RecordingOutbox(refuse = 2)
    val ref = testKit.spawn(SessionActor(config, infer, outbox))

    ref ! start
    ref ! SessionActor.WsMessage(newFrame(0x01)) // seq 1
    ref ! SessionActor.FlushTick // flush 1..1, send refused (1)
    eventually(1.second, 10.millis)(assertEquals(calls.get, 1))
    ref ! SessionActor.WsMessage(newFrame(0x02)) // seq 2
    ref ! SessionActor.FlushTick // retry refused (2); no new inference
    Thread.sleep(100)
    assertEquals(calls.get, 1)
    assertEquals(outbox.sent.size, 0)
    ref ! SessionActor.FlushTick // retry accepted, then flush 2..2
    eventually(1.second, 10.millis)(assertEquals(outbox.sent.size, 2))
    val seqs = outbox.sent.toArray.toList.map { t =>
      val c = parse(t.toString).toOption.get.hcursor
      (c.downField("oldest_frame_seq").as[Long].toOption.get, c.downField("newest_frame_seq").as[Long].toOption.get)
    }
    assertEquals(seqs, List((1L, 1L), (2L, 2L)))
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
