package org.apache.pekko.http.impl.engine.ws

import org.apache.pekko.NotUsed
import org.apache.pekko.event.LoggingAdapter
import org.apache.pekko.http.scaladsl.model.HttpResponse
import org.apache.pekko.http.scaladsl.model.ws.{Message, WebSocketUpgrade}
import org.apache.pekko.http.scaladsl.settings.WebSocketSettings
import org.apache.pekko.stream.scaladsl.{BidiFlow, Flow}
import stt.session.CloseIntent

/** Pekko HTTP's public message-level WebSocket API can only close with `1000` (handler completed) or `1011` (handler
  * failed); the benchmark contract needs `1002` / `1003`. This keeps Pekko's own message stack — exactly what
  * `handleMessages` builds — and adds one outbound-only stage that rewrites the server's close frame to the code the
  * session recorded in its [[CloseIntent]]. Inbound frames pass through untouched (identity flow, fused away).
  *
  * Pekko HTTP internals relied on (all `private[http]` / impl, verified against pekko-http 1.3.0):
  *   - `UpgradeToWebSocketLowLevel` is the runtime class of the server's `WebSocketUpgrade` (built by
  *     `Handshake.Server.websocketUpgrade`), and its `handleFrames(Flow[FrameEvent, FrameEvent], subprotocol)` installs
  *     a frame-level handler. This is why the object lives in this package.
  *   - `WebSocket.stack(serverSide = true, settings, log)` is the same frame <-> message stack that
  *     `Handshake.Server.buildResponse` joins for `handleMessages` (masking, fragmentation, ping/pong, close
  *     handshake).
  *   - The stack's outbound close is a single `FrameStart` with `opcode == Protocol.Opcode.Close`, and
  *     `FrameEvent.closeFrame(code, reason)` builds a replacement.
  *
  * Pekko's own `handleMessages` passes the connection's `ServerSettings.websocketSettings`, held in a private field of
  * the anonymous upgrade class. That isn't reachable, so the caller must pass the websocket settings of the exact
  * `ServerSettings` the listener was bound with (see `stt.server.Server`), which makes them identical.
  *
  * A Pekko HTTP bump MUST re-run `ServerSpec` (real-socket 1002/1003 assertions). If the upgrade is no longer an
  * `UpgradeToWebSocketLowLevel` this fails the request loudly instead of silently degrading to close code 1000.
  */
object SttWebSocket:

  def handleMessages(
      upgrade: WebSocketUpgrade,
      handler: Flow[Message, Message, Any],
      closeIntent: CloseIntent,
      settings: WebSocketSettings,
      log: LoggingAdapter
  ): HttpResponse =
    upgrade match
      case lowLevel: UpgradeToWebSocketLowLevel =>
        lowLevel.handleFrames(
          closeCodeLayer(closeIntent).atop(WebSocket.stack(serverSide = true, settings, log = log)).join(handler)
        )
      case other =>
        // No fallback to `other.handleMessages`: that would quietly close every protocol error with 1000.
        val msg = s"Pekko WebSocketUpgrade is ${other.getClass.getName}, not UpgradeToWebSocketLowLevel; " +
          "the 1002/1003 close-code stage cannot be installed (Pekko HTTP internals changed — re-check SttWebSocket)"
        log.error(msg)
        throw IllegalStateException(msg)

  private def closeCodeLayer(closeIntent: CloseIntent)
      : BidiFlow[FrameEvent, FrameEvent, FrameEvent, FrameEvent, NotUsed] =
    BidiFlow.fromFlows(
      Flow[FrameEvent],
      Flow[FrameEvent].map {
        case start: FrameStart if start.header.opcode == Protocol.Opcode.Close && closeIntent.code != 0 =>
          FrameEvent.closeFrame(closeIntent.code, closeIntent.reason)
        case other => other
      }
    )
