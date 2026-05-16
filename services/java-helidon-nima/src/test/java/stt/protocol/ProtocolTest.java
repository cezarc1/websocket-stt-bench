package stt.protocol;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

final class ProtocolTest {

    private final ObjectMapper mapper = Protocol.newJsonMapper();

    @Test
    void startMessageStrictlyRequiresTypeStart() {
        assertThrows(Exception.class, () -> mapper.readValue("{}", StartMessage.class));
        assertThrows(Exception.class, () -> mapper.readValue("{\"type\":\"stop\"}", StartMessage.class));
        assertThrows(Exception.class, () -> mapper.readValue("{\"type\":\"start\",\"extra\":1}", StartMessage.class));
    }

    @Test
    void inferResponseRejectsUnknownFields() throws Exception {
        String good = "{\"rms\":1.0,\"zero_crossings\":2,\"checksum\":3,\"samples\":4,"
                + "\"transcript\":\"x\",\"audio_bytes\":5}";
        assertEquals("x", mapper.readValue(good, InferResponse.class).transcript());

        String withExtra = "{\"rms\":1.0,\"zero_crossings\":2,\"checksum\":3,\"samples\":4,"
                + "\"transcript\":\"x\",\"audio_bytes\":5,\"unknown\":true}";
        assertThrows(Exception.class, () -> mapper.readValue(withExtra, InferResponse.class));
    }

    @Test
    void partialMessageRoundTripsAndCarriesAllRequiredFields() throws Exception {
        InferResponse infer = new InferResponse(1.5, 2L, 3L, 4L, "now", 5L);
        PartialMessage partial = PartialMessage.of(infer, 10L, 20L, 1, 4, 75L, 2.5);
        String json = mapper.writeValueAsString(partial);
        JsonNode node = mapper.readTree(json);

        assertEquals("partial", node.get("type").asText());
        assertEquals(10L, node.get("oldest_frame_seq").asLong());
        assertEquals(20L, node.get("newest_frame_seq").asLong());
        assertEquals(1, node.get("frames").asInt());
        assertEquals(75L, node.get("model_delay_ms").asLong());
        assertEquals(2.5, node.get("flush_lateness_ms").asDouble());
        assertEquals(0, node.get("inflight_model_jobs").asInt());
    }

    @Test
    void errorMessageEmitsNullableFieldsAsJsonNull() throws Exception {
        ErrorMessage error = new ErrorMessage(
                Protocol.ERROR_TYPE,
                ErrorStage.INFERENCE_REQUEST,
                ErrorKind.TIMEOUT,
                "timed out",
                10L,
                20L,
                1,
                640L,
                12.0,
                3.0,
                4.0,
                null,
                1,
                0,
                null,
                true);
        JsonNode node = mapper.readTree(mapper.writeValueAsString(error));

        assertEquals("error", node.get("type").asText());
        assertTrue(node.has("inference_elapsed_ms"));
        assertTrue(node.get("inference_elapsed_ms").isNull());
        assertTrue(node.has("inference_status"));
        assertTrue(node.get("inference_status").isNull());
        assertTrue(node.get("retryable").asBoolean());
    }
}
