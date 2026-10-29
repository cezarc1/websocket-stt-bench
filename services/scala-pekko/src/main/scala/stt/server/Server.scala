package stt.server

import scala.concurrent.duration.DurationInt

import org.apache.pekko.actor.typed.ActorSystem
import org.apache.pekko.event.Logging
import org.apache.pekko.http.impl.engine.ws.SttWebSocket
import org.apache.pekko.http.scaladsl.Http
import org.apache.pekko.http.scaladsl.model.{ContentTypes, HttpEntity}
import org.apache.pekko.http.scaladsl.server.Directives.*
import org.apache.pekko.http.scaladsl.server.Route
import org.apache.pekko.http.scaladsl.settings.ServerSettings
import stt.Config
import stt.inference.InferenceClient
import stt.session.CloseIntent

object Server:

  /** `settings` must be the same `ServerSettings` the listener is bound with: `SttWebSocket` builds the WebSocket stack
    * itself and cannot read the connection's settings, so this is how they are kept identical.
    */
  def routes(config: Config, inference: InferenceClient, settings: ServerSettings)(using
      system: ActorSystem[?]
  ): Route =
    val wsSettings = settings.websocketSettings
    val wsLog = Logging(system.classicSystem, "stt.websocket")
    concat(
      path("health")(
        complete(HttpEntity(ContentTypes.`application/json`, s"""{"ok":true,"runtime":"${Config.RuntimeName}"}"""))
      ),
      path("ws" / "stt") {
        extractWebSocketUpgrade { upgrade =>
          val closeIntent = CloseIntent()
          complete(
            SttWebSocket.handleMessages(
              upgrade,
              SttSessionFlow.create(config, inference, closeIntent),
              closeIntent,
              wsSettings,
              wsLog
            )
          )
        }
      }
    )

  def start(config: Config, inference: InferenceClient)(using system: ActorSystem[?]): Unit =
    val settings = ServerSettings(system.classicSystem)
    Http()
      .newServerAt(interface = "0.0.0.0", port = config.port)
      .withSettings(settings)
      .bind(routes(config, inference, settings))
      .map(_.addToCoordinatedShutdown(hardTerminationDeadline = 10.seconds))(using system.executionContext): Unit
