package stt

import scala.concurrent.duration.*

final case class Config(
    port: Int,
    inferenceUrl: String,
    inferenceTimeout: FiniteDuration,
    inferenceHttpClients: Int,
    cpuPasses: Int,
    modelDelayMs: Long,
    flushInterval: FiniteDuration,
    flushPhaseJitter: FiniteDuration,
    partialChannelDepth: Int
)

object Config:
  val RuntimeName: String = "scala-pekko"
  val RuntimeScalaVersion: String = "3.3.7"

  val DefaultPort: Int = 2500
  val DefaultInferenceUrl: String = "http://inference-server:9000"
  val DefaultInferenceTimeoutMs: Long = 2000L
  val DefaultInferenceHttpClients: Int = 4
  val DefaultCpuPasses: Int = 4
  val DefaultModelDelayMs: Long = 75L
  val DefaultFlushIntervalMs: Long = 1000L
  val DefaultFlushPhaseJitterMs: Long = 0L
  val DefaultPartialChannelDepth: Int = 4

  def load(env: String => Option[String] = name => Option(System.getenv(name))): Config =
    Config(
      port = envLong(env, "PORT", DefaultPort.toLong).toInt,
      inferenceUrl = envString(env, "INFERENCE_URL", DefaultInferenceUrl).replaceAll("/+$", ""),
      inferenceTimeout = envLong(env, "INFERENCE_TIMEOUT_MS", DefaultInferenceTimeoutMs).millis,
      inferenceHttpClients =
        math.max(1L, envLong(env, "INFERENCE_HTTP_CLIENTS", DefaultInferenceHttpClients.toLong)).toInt,
      cpuPasses = math.max(1L, envLong(env, "CPU_PASSES", DefaultCpuPasses.toLong)).toInt,
      modelDelayMs = math.max(0L, envLong(env, "MODEL_DELAY_MS", DefaultModelDelayMs)),
      flushInterval = math.max(1L, envLong(env, "FLUSH_INTERVAL_MS", DefaultFlushIntervalMs)).millis,
      flushPhaseJitter = math.max(0L, envLong(env, "FLUSH_PHASE_JITTER_MS", DefaultFlushPhaseJitterMs)).millis,
      partialChannelDepth =
        math.max(1L, envLong(env, "PARTIAL_CHANNEL_DEPTH", DefaultPartialChannelDepth.toLong)).toInt
    )

  private def envString(env: String => Option[String], name: String, fallback: String): String =
    env(name).filter(_.nonEmpty).getOrElse(fallback)

  private def envLong(env: String => Option[String], name: String, fallback: Long): Long =
    env(name).filter(_.nonEmpty).flatMap(_.toLongOption).getOrElse(fallback)
