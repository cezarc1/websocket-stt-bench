package stt.server

import scala.concurrent.duration.DurationInt
import scala.concurrent.{Await, ExecutionContext, Future}

import munit.FunSuite
import org.apache.pekko.actor.testkit.typed.scaladsl.ActorTestKit
import org.apache.pekko.actor.typed.ActorSystem
import org.apache.pekko.event.Logging
import org.apache.pekko.http.impl.engine.ws.SttWebSocket
import org.apache.pekko.http.scaladsl.Http
import org.apache.pekko.http.scaladsl.model.HttpResponse
import org.apache.pekko.http.scaladsl.model.ws.{
  BinaryMessage,
  Message,
  PeerClosedConnectionException,
  TextMessage,
  WebSocketRequest,
  WebSocketUpgrade
}
import org.apache.pekko.http.scaladsl.settings.ServerSettings
import org.apache.pekko.stream.scaladsl.{Flow, Sink, Source}
import org.apache.pekko.stream.{FlowShape, Graph}
import org.apache.pekko.util.ByteString
import stt.Config
import stt.inference.InferenceClient
import stt.protocol.InferResponse
import stt.session.CloseIntent

/** End-to-end over a real socket: the client must observe the contract close codes, not Pekko's default 1000. */
final class ServerSpec extends FunSuite:

  private val testKit = ActorTestKit("server-spec")
  private given system: ActorSystem[Nothing] = testKit.system

  override def afterAll(): Unit = testKit.shutdownTestKit()

  private val config = Config.load(_ => None)

  private val inference: InferenceClient = new InferenceClient:
    override def infer(body: Array[Byte], cpuPasses: Int)(using ExecutionContext): Future[InferResponse] =
      Future.successful(InferResponse(0.0, 0L, 0L, 320L, "x", body.length.toLong))

  private lazy val port: Int =
    val settings = ServerSettings(system.classicSystem)
    Await
      .result(
        Http().newServerAt("127.0.0.1", 0).withSettings(settings).bind(Server.routes(config, inference, settings)),
        5.seconds
      )
      .localAddress
      .getPort

  /** Sends `messages`, keeps the socket open, and returns how the server's close surfaced on the client. */
  private def closeCodeAfter(messages: Message*): Option[Int] =
    val closed = Http()
      .singleWebSocketRequest(
        WebSocketRequest(s"ws://127.0.0.1:$port/ws/stt"),
        Flow.fromSinkAndSourceMat(Sink.ignore, Source(messages.toList).concat(Source.maybe[Message]))((done, _) => done)
      )
      ._2
    Await.ready(closed, 5.seconds).value.get.failed.toOption.collect { case e: PeerClosedConnectionException =>
      e.closeCode
    }

  test("invalid first message closes 1002") {
    assertEquals(closeCodeAfter(TextMessage.Strict("not-json")), Some(1002))
    assertEquals(closeCodeAfter(TextMessage.Strict("""{"type":"stop"}""")), Some(1002))
    assertEquals(closeCodeAfter(BinaryMessage.Strict(ByteString(new Array[Byte](640)))), Some(1002))
  }

  test("invalid binary frame size closes 1003") {
    val start = TextMessage.Strict("""{"type":"start"}""")
    for size <- List(0, 10, 639, 641) do
      assertEquals(closeCodeAfter(start, BinaryMessage.Strict(ByteString(new Array[Byte](size)))), Some(1003), size)
  }

  test("an upgrade that isn't Pekko's low-level one fails loudly instead of falling back to close code 1000") {
    var fellBack = false
    val foreign = new WebSocketUpgrade:
      override def requestedProtocols: Seq[String] = Nil
      override def handleMessages(
          handler: Graph[FlowShape[Message, Message], Any],
          subprotocol: Option[String]
      ): HttpResponse =
        fellBack = true
        HttpResponse()
    val err = intercept[IllegalStateException](
      SttWebSocket.handleMessages(
        foreign,
        Flow[Message],
        CloseIntent(),
        ServerSettings(system.classicSystem).websocketSettings,
        Logging(system.classicSystem, "server-spec")
      )
    )
    assert(err.getMessage.contains("UpgradeToWebSocketLowLevel"), err.getMessage)
    assert(!fellBack, "must not delegate to the message-level handleMessages")
  }
