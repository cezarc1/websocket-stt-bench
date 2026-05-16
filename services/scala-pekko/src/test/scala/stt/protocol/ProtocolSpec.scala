package stt.protocol

import io.circe.parser.{decode, parse}
import io.circe.syntax.*
import munit.FunSuite

final class ProtocolSpec extends FunSuite:

  test("StartMessage strictly requires type=start") {
    assert(decode[StartMessage]("""{}""").isLeft, "missing type should fail")
    assert(decode[StartMessage]("""{"type":"stop"}""").isLeft, "wrong type should fail")
    assert(decode[StartMessage]("""{"type":"start","extra":1}""").isLeft, "unknown field should fail")
    assert(decode[StartMessage]("""{"type":"start"}""").isRight, "valid start should parse")
  }

  test("InferResponse rejects unknown fields") {
    val good = """{"rms":1.0,"zero_crossings":2,"checksum":3,"samples":4,"transcript":"x","audio_bytes":5}"""
    assertEquals(decode[InferResponse](good).map(_.transcript), Right("x"))

    val withExtra =
      """{"rms":1.0,"zero_crossings":2,"checksum":3,"samples":4,"transcript":"x","audio_bytes":5,"unknown":true}"""
    assert(decode[InferResponse](withExtra).isLeft, "unknown field should fail")
  }

  test("PartialMessage round-trips with snake_case fields") {
    val infer =
      InferResponse(rms = 1.5, zeroCrossings = 2L, checksum = 3L, samples = 4L, transcript = "now", audioBytes = 5L)
    val partial = PartialMessage.of(
      infer,
      oldestSeq = 10L,
      newestSeq = 20L,
      frames = 1,
      cpuPasses = 4,
      modelDelayMs = 75L,
      flushLatenessMs = 2.5
    )

    val json = parse(partial.asJson.noSpaces).toOption.get
    val cursor = json.hcursor

    assertEquals(cursor.downField("type").as[String], Right("partial"))
    assertEquals(cursor.downField("oldest_frame_seq").as[Long], Right(10L))
    assertEquals(cursor.downField("newest_frame_seq").as[Long], Right(20L))
    assertEquals(cursor.downField("frames").as[Int], Right(1))
    assertEquals(cursor.downField("model_delay_ms").as[Long], Right(75L))
    assertEquals(cursor.downField("flush_lateness_ms").as[Double], Right(2.5))
    assertEquals(cursor.downField("inflight_model_jobs").as[Int], Right(0))
  }

  test("ErrorMessage emits nullable fields as JSON null") {
    val err = ErrorMessage(
      `type` = Protocol.ErrorType,
      stage = ErrorStage.InferenceRequest,
      kind = ErrorKind.Timeout,
      message = "timed out",
      oldestFrameSeq = 10L,
      newestFrameSeq = 20L,
      frames = 1,
      audioBytes = 640L,
      oldestAgeMs = 12.0,
      newestAgeMs = 3.0,
      flushLatenessMs = 4.0,
      inferenceElapsedMs = None,
      inflightGatewayBatches = 1,
      gatewayBufferFrames = 0,
      inferenceStatus = None,
      retryable = true
    )

    val json = parse(err.asJson.noSpaces).toOption.get
    val cursor = json.hcursor

    assertEquals(cursor.downField("type").as[String], Right("error"))
    assertEquals(cursor.downField("stage").as[String], Right("inference_request"))
    assertEquals(cursor.downField("kind").as[String], Right("timeout"))
    assert(cursor.downField("inference_elapsed_ms").focus.exists(_.isNull), "inference_elapsed_ms must be JSON null")
    assert(cursor.downField("inference_status").focus.exists(_.isNull), "inference_status must be JSON null")
    assertEquals(cursor.downField("retryable").as[Boolean], Right(true))
  }
