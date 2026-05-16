package stt.inference

import java.net.URI
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.nio.charset.StandardCharsets
import java.time.Duration as JDuration
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

import scala.concurrent.duration.FiniteDuration
import scala.concurrent.{ExecutionContext, Future}
import scala.jdk.FutureConverters.*

import io.circe.parser.decode
import stt.protocol.{ErrorKind, ErrorStage, InferResponse}

/** Classified inference-call failure surfaced to [[stt.session.SessionActor]] for error-message synthesis. Carries
  * stage/kind/status/retryable on the wire-protocol side, plus the original cause for diagnostics.
  */
final case class InferenceFailure(
    stage: ErrorStage,
    kind: ErrorKind,
    detail: String,
    status: Option[Int],
    retryable: Boolean,
    cause: Option[Throwable] = None
) extends RuntimeException(detail, cause.orNull)

trait InferenceClient:
  def infer(body: Array[Byte], cpuPasses: Int)(using ec: ExecutionContext): Future[InferResponse]

/** Pool of JDK [[java.net.http.HttpClient]] instances. Each client maintains its own connection cache and prefers
  * HTTP/2 via {@code .version(HTTP_2)} ; the JDK upgrades over h2c when the Axum/Hyper inference server accepts the
  * upgrade, otherwise it falls back to HTTP/1.1. Sibling gateways (Rust/Go/Java/Helidon) configure prior-knowledge h2c;
  * the inference server accepts both negotiation modes.
  */
final class JdkHttpInferenceClient(
    baseUrl: String,
    timeout: FiniteDuration,
    clientCount: Int
) extends InferenceClient:

  private val endpoint: URI = URI.create(baseUrl + "/infer")
  private val timeoutJ: JDuration = JDuration.ofMillis(timeout.toMillis)

  private val pool: Vector[HttpClient] = Vector.tabulate(math.max(1, clientCount)) { _ =>
    HttpClient
      .newBuilder()
      .version(HttpClient.Version.HTTP_2)
      .connectTimeout(timeoutJ)
      .build()
  }

  private val next: AtomicLong = AtomicLong(0L)

  private def pick(): HttpClient =
    pool(math.floorMod(next.getAndIncrement(), pool.size.toLong).toInt)

  override def infer(body: Array[Byte], cpuPasses: Int)(using ec: ExecutionContext): Future[InferResponse] =
    val request = HttpRequest
      .newBuilder(endpoint)
      .timeout(timeoutJ)
      .header("x-cpu-passes", cpuPasses.toString)
      .POST(HttpRequest.BodyPublishers.ofByteArray(body))
      .build()

    pick()
      .sendAsync(request, HttpResponse.BodyHandlers.ofByteArray())
      .asScala
      .flatMap { response =>
        val status = response.statusCode
        if status < 200 || status >= 300 then Future.failed(classifyStatus(status))
        else
          decode[InferResponse](String(response.body, StandardCharsets.UTF_8)) match
            case Right(infer) => Future.successful(infer)
            case Left(err) =>
              Future.failed(
                InferenceFailure(
                  stage = ErrorStage.InferenceResponseParse,
                  kind = ErrorKind.ParseError,
                  detail = err.getMessage,
                  status = Some(status),
                  retryable = false,
                  cause = Some(err)
                )
              )
      }
      .recoverWith {
        case f: InferenceFailure => Future.failed(f)
        case t: Throwable => Future.failed(classifyRequest(t))
      }

  private def classifyStatus(code: Int): InferenceFailure =
    val is429 = code == 429
    InferenceFailure(
      stage = ErrorStage.InferenceRequest,
      kind = if is429 then ErrorKind.Http429 else ErrorKind.Http5xx,
      detail = s"inference returned status $code",
      status = Some(code),
      retryable = is429 || (code >= 500 && code < 600)
    )

  private def classifyRequest(err: Throwable): InferenceFailure =
    val kind = if isTimeout(err) then ErrorKind.Timeout else ErrorKind.ConnectionReset
    InferenceFailure(
      stage = ErrorStage.InferenceRequest,
      kind = kind,
      detail = Option(err.getMessage).getOrElse(err.getClass.getSimpleName),
      status = None,
      retryable = true,
      cause = Some(err)
    )

  private def isTimeout(err: Throwable): Boolean =
    Iterator
      .iterate(err)(_.getCause)
      .takeWhile(_ != null)
      .exists {
        case _: TimeoutException => true
        case _: java.net.http.HttpTimeoutException => true
        case _: java.net.SocketTimeoutException => true
        // Tighten the message-substring fallback to socket exceptions only (matches Java sibling);
        // walking the full chain with a generic substring match would mis-classify too many errors.
        case s: java.net.SocketException if Option(s.getMessage).exists(_.toLowerCase.contains("timed out")) => true
        case _ => false
      }
