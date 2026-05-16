package stt

import scala.concurrent.duration.DurationLong

import munit.FunSuite

final class ConfigSpec extends FunSuite:

  test("defaults load when env is empty") {
    val config = Config.load(_ => None)
    assertEquals(config.port, Config.DefaultPort)
    assertEquals(config.inferenceUrl, "http://inference-server:9000")
    assertEquals(config.inferenceTimeout, Config.DefaultInferenceTimeoutMs.millis)
    assertEquals(config.inferenceHttpClients, Config.DefaultInferenceHttpClients)
    assertEquals(config.cpuPasses, Config.DefaultCpuPasses)
    assertEquals(config.modelDelayMs, Config.DefaultModelDelayMs)
    assertEquals(config.flushInterval, Config.DefaultFlushIntervalMs.millis)
    assertEquals(config.flushPhaseJitter, 0L.millis)
    assertEquals(config.partialChannelDepth, Config.DefaultPartialChannelDepth)
  }

  test("env overrides are parsed") {
    val overrides = Map(
      "PORT" -> "2550",
      "INFERENCE_URL" -> "http://example.com:9001/",
      "INFERENCE_TIMEOUT_MS" -> "3000",
      "INFERENCE_HTTP_CLIENTS" -> "8",
      "CPU_PASSES" -> "8",
      "MODEL_DELAY_MS" -> "100",
      "FLUSH_INTERVAL_MS" -> "500",
      "FLUSH_PHASE_JITTER_MS" -> "250",
      "PARTIAL_CHANNEL_DEPTH" -> "16"
    )
    val config = Config.load(overrides.get)

    assertEquals(config.port, 2550)
    assertEquals(config.inferenceUrl, "http://example.com:9001") // trailing slash stripped
    assertEquals(config.inferenceTimeout, 3000L.millis)
    assertEquals(config.inferenceHttpClients, 8)
    assertEquals(config.cpuPasses, 8)
    assertEquals(config.modelDelayMs, 100L)
    assertEquals(config.flushInterval, 500L.millis)
    assertEquals(config.flushPhaseJitter, 250L.millis)
    assertEquals(config.partialChannelDepth, 16)
  }

  test("unparseable values fall back to defaults") {
    val env = Map("PORT" -> "not-a-number", "CPU_PASSES" -> "").get
    val config = Config.load(env)
    assertEquals(config.port, Config.DefaultPort)
    assertEquals(config.cpuPasses, Config.DefaultCpuPasses)
  }
