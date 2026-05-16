package stt.protocol

import io.circe.derivation.{Configuration, ConfiguredEncoder}
import io.circe.{Decoder, DecodingFailure, Encoder, Json}

object Protocol:
  val FrameBytes: Int = 640
  val PartialType: String = "partial"
  val ErrorType: String = "error"

  val CloseProtocolError: Int = 1002
  val CloseUnsupportedData: Int = 1003
  val ReasonNeedStart: String = "first message must be start"
  val ReasonTextAfterStart: String = "expected binary PCM frames after start"
  val ReasonBadFrameSize: String = "expected 640 byte PCM frame"

enum ErrorStage(val wire: String):
  case WebsocketReceive extends ErrorStage("websocket_receive")
  case BatchFlush extends ErrorStage("batch_flush")
  case InferenceRequest extends ErrorStage("inference_request")
  case InferenceResponseParse extends ErrorStage("inference_response_parse")
  case WebsocketSend extends ErrorStage("websocket_send")

object ErrorStage:
  given Encoder[ErrorStage] = Encoder[String].contramap(_.wire)

enum ErrorKind(val wire: String):
  case Timeout extends ErrorKind("timeout")
  case PoolTimeout extends ErrorKind("pool_timeout")
  case Http5xx extends ErrorKind("http_5xx")
  case Http429 extends ErrorKind("http_429")
  case ConnectionReset extends ErrorKind("connection_reset")
  case ParseError extends ErrorKind("parse_error")
  case SendError extends ErrorKind("send_error")

object ErrorKind:
  given Encoder[ErrorKind] = Encoder[String].contramap(_.wire)

/** Strict snake_case decoder configuration shared by inbound wire types. */
private object DecoderConfig:
  given Configuration = Configuration.default.withSnakeCaseMemberNames.withStrictDecoding

/** Strict snake_case encoder configuration shared by outbound wire types. */
private object EncoderConfig:
  given Configuration = Configuration.default.withSnakeCaseMemberNames

/** First message the client sends on a fresh WebSocket. */
final case class StartMessage(`type`: String)

object StartMessage:

  given Decoder[StartMessage] = Decoder.instance { c =>
    val expected = Set("type")
    c.keys match
      case Some(keys) if keys.toSet != expected =>
        Left(DecodingFailure(s"unknown fields: ${keys.toSet -- expected}", c.history))
      case _ =>
        c.downField("type").as[String].flatMap { tpe =>
          if tpe == "start" then Right(StartMessage(tpe))
          else Left(DecodingFailure(s"expected type=start, got $tpe", c.history))
        }
  }

/** Inference server response. Decoded strictly: unknown fields are rejected. */
final case class InferResponse(
    rms: Double,
    zeroCrossings: Long,
    checksum: Long,
    samples: Long,
    transcript: String,
    audioBytes: Long
)

object InferResponse:
  import EncoderConfig.given

  private val expectedFields = Set("rms", "zero_crossings", "checksum", "samples", "transcript", "audio_bytes")

  given Decoder[InferResponse] = Decoder.instance { c =>
    c.keys match
      case Some(keys) if keys.toSet != expectedFields =>
        Left(DecodingFailure(s"unknown fields: ${keys.toSet -- expectedFields}", c.history))
      case _ =>
        for
          rms <- c.downField("rms").as[Double]
          zeroCrossings <- c.downField("zero_crossings").as[Long]
          checksum <- c.downField("checksum").as[Long]
          samples <- c.downField("samples").as[Long]
          transcript <- c.downField("transcript").as[String]
          audioBytes <- c.downField("audio_bytes").as[Long]
        yield InferResponse(rms, zeroCrossings, checksum, samples, transcript, audioBytes)
  }

  given Encoder[InferResponse] = ConfiguredEncoder.derived[InferResponse]

/** `partial` message sent back on each successful flush. Field order is wire-compatible with the Rust/Go/Java gateways
  * via {@link ConfiguredEncoder} and the declared case-class order.
  */
final case class PartialMessage(
    `type`: String,
    oldestFrameSeq: Long,
    newestFrameSeq: Long,
    frames: Int,
    rms: Double,
    zeroCrossings: Long,
    checksum: Long,
    samples: Long,
    transcript: String,
    audioBytes: Long,
    cpuPasses: Int,
    modelDelayMs: Long,
    flushLatenessMs: Double,
    inflightModelJobs: Int
)

object PartialMessage:
  import EncoderConfig.given
  given Encoder[PartialMessage] = ConfiguredEncoder.derived[PartialMessage]

  def of(
      infer: InferResponse,
      oldestSeq: Long,
      newestSeq: Long,
      frames: Int,
      cpuPasses: Int,
      modelDelayMs: Long,
      flushLatenessMs: Double
  ): PartialMessage = PartialMessage(
    `type` = Protocol.PartialType,
    oldestFrameSeq = oldestSeq,
    newestFrameSeq = newestSeq,
    frames = frames,
    rms = infer.rms,
    zeroCrossings = infer.zeroCrossings,
    checksum = infer.checksum,
    samples = infer.samples,
    transcript = infer.transcript,
    audioBytes = infer.audioBytes,
    cpuPasses = cpuPasses,
    modelDelayMs = modelDelayMs,
    flushLatenessMs = flushLatenessMs,
    inflightModelJobs = 0
  )

/** `error` message emitted when the gateway fails to produce a partial for a batch. */
final case class ErrorMessage(
    `type`: String,
    stage: ErrorStage,
    kind: ErrorKind,
    message: String,
    oldestFrameSeq: Long,
    newestFrameSeq: Long,
    frames: Int,
    audioBytes: Long,
    oldestAgeMs: Double,
    newestAgeMs: Double,
    flushLatenessMs: Double,
    inferenceElapsedMs: Option[Double],
    inflightGatewayBatches: Int,
    gatewayBufferFrames: Int,
    inferenceStatus: Option[Int],
    retryable: Boolean
)

object ErrorMessage:
  given Configuration = Configuration.default.withSnakeCaseMemberNames

  // ConfiguredEncoder drops None-valued fields by default; we inject JSON null for the two
  // Optional fields so the wire shape matches Rust/Go/Java (which serialize null explicitly).
  given Encoder[ErrorMessage] = ConfiguredEncoder.derived[ErrorMessage].mapJson { json =>
    List("inference_elapsed_ms", "inference_status").foldLeft(json) { (acc, key) =>
      if acc.hcursor.downField(key).succeeded then acc
      else acc.deepMerge(Json.obj(key -> Json.Null))
    }
  }

/** Sealed dispatch shape for the actor's outbox. */
enum OutboundMessage:
  case Partial(message: PartialMessage)
  case Error(message: ErrorMessage)

/** Internal per-frame state captured at WS receive time. Not on the wire. {@code receivedAtNanos} is a
  * [[System.nanoTime]] reading — relative elapsed-millis math only, never an absolute time.
  */
final case class Frame(seq: Long, payload: Array[Byte], receivedAtNanos: Long)
