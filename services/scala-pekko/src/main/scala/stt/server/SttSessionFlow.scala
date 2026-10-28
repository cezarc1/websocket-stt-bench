package stt.server

import java.util.UUID

import org.apache.pekko.NotUsed
import org.apache.pekko.actor.typed.ActorSystem
import org.apache.pekko.http.scaladsl.model.ws.Message
import org.apache.pekko.stream.BoundedSourceQueue
import org.apache.pekko.stream.scaladsl.{Flow, Sink, Source}
import stt.Config
import stt.inference.InferenceClient
import stt.session.{CloseIntent, SessionActor, SessionOutbox}

/** Per-connection WebSocket flow built on Pekko HTTP's high-level `Message` API.
  *
  * Frames arrive already unmasked as `Message` values and the only per-connection allocations are the outbound
  * `Source.queue` and the `SessionActor` itself. Explicit `1002` / `1003` closes are recorded in `closeIntent` and
  * rendered by `org.apache.pekko.http.impl.engine.ws.SttWebSocket`, since the message API alone can only send `1000`.
  */
object SttSessionFlow:

  def create(
      config: Config,
      inference: InferenceClient,
      closeIntent: CloseIntent
  )(using system: ActorSystem[?]): Flow[Message, Message, NotUsed] =
    val (queue, source): (BoundedSourceQueue[Message], Source[Message, NotUsed]) =
      Source.queue[Message](config.partialChannelDepth).preMaterialize()

    val outbox = SessionOutbox.messageQueue(queue, closeIntent)
    val sessionRef =
      system.systemActorOf(SessionActor(config, inference, outbox), "session-" + UUID.randomUUID())

    val sink: Sink[Message, NotUsed] =
      Sink
        .foreach[Message](msg => sessionRef ! SessionActor.WsMessage(msg))
        .mapMaterializedValue(_ => NotUsed)

    Flow
      .fromSinkAndSourceCoupled(sink, source)
      .watchTermination() { (mat, termination) =>
        termination.onComplete(_ => sessionRef ! SessionActor.WsClosed)(using system.executionContext)
        mat
      }
