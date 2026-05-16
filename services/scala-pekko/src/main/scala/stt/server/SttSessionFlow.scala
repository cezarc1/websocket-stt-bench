package stt.server

import java.util.UUID

import org.apache.pekko.NotUsed
import org.apache.pekko.actor.typed.ActorSystem
import org.apache.pekko.http.scaladsl.model.ws.Message
import org.apache.pekko.stream.BoundedSourceQueue
import org.apache.pekko.stream.scaladsl.{Flow, Sink, Source}
import stt.Config
import stt.inference.InferenceClient
import stt.session.{SessionActor, SessionOutbox}

/** Per-connection WebSocket flow built on Pekko HTTP's high-level `Message` API.
  *
  * Replaces the previous low-level `FrameEvent` bridge so the connection admission path costs as little as possible:
  * the upgrade is handled by the framework, frames arrive already unmasked as `Message` values, and the only
  * per-connection allocations are the outbound `Source.queue` and the `SessionActor` itself. Close-code precision
  * (`1002` / `1003`) is intentionally traded away here in exchange for measuring whether the low-level bridge was the
  * bottleneck on 1-vCPU pods — the high-level upgrade collapses any explicit close to a normal `1000` closure.
  */
object SttSessionFlow:

  def create(
      config: Config,
      inference: InferenceClient
  )(using system: ActorSystem[?]): Flow[Message, Message, NotUsed] =
    val (queue, source): (BoundedSourceQueue[Message], Source[Message, NotUsed]) =
      Source.queue[Message](config.partialChannelDepth).preMaterialize()

    val outbox = SessionOutbox.messageQueue(queue)
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
