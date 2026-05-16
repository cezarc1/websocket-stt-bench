package stt.server

import scala.concurrent.duration.DurationInt

import org.apache.pekko.actor.typed.ActorSystem
import org.apache.pekko.http.scaladsl.Http
import org.apache.pekko.http.scaladsl.model.{ContentTypes, HttpEntity}
import org.apache.pekko.http.scaladsl.server.Directives.*
import org.apache.pekko.http.scaladsl.server.Route
import stt.Config
import stt.inference.InferenceClient

object Server:

  def routes(config: Config, inference: InferenceClient)(using system: ActorSystem[?]): Route =
    concat(
      path("health")(
        complete(HttpEntity(ContentTypes.`application/json`, s"""{"ok":true,"runtime":"${Config.RuntimeName}"}"""))
      ),
      path("ws" / "stt")(handleWebSocketMessages(SttSessionFlow.create(config, inference)))
    )

  def start(config: Config, inference: InferenceClient)(using system: ActorSystem[?]): Unit =
    Http()
      .newServerAt(interface = "0.0.0.0", port = config.port)
      .bind(routes(config, inference))
      .map(_.addToCoordinatedShutdown(hardTerminationDeadline = 10.seconds))(using system.executionContext): Unit
