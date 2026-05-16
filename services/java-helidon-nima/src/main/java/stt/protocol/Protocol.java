package stt.protocol;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.module.blackbird.BlackbirdModule;

/** Wire-shared constants and shared Jackson {@link ObjectMapper} factory. */
public final class Protocol {

    public static final int FRAME_BYTES = 640;
    public static final String PARTIAL_TYPE = "partial";
    public static final String ERROR_TYPE = "error";

    public static final int CLOSE_PROTOCOL_ERROR = 1002;
    public static final int CLOSE_UNSUPPORTED_DATA = 1003;
    public static final String REASON_NEED_START = "first message must be start";
    public static final String REASON_TEXT_AFTER_START = "expected binary PCM frames after start";
    public static final String REASON_BAD_FRAME_SIZE = "expected 640 byte PCM frame";

    /**
     * Shared {@link ObjectMapper}. Strict on unknown fields. Null inclusion is Jackson's default
     * (ALWAYS), so {@code Optional}-shaped wire fields like {@code inference_status} serialize as
     * JSON {@code null} to match the Rust/Go gateways without further configuration. Blackbird
     * replaces reflective record ser/de with {@code LambdaMetafactory}-backed accessors for
     * measurable throughput on the per-flush partial/error path.
     */
    public static ObjectMapper newJsonMapper() {
        return new ObjectMapper()
                .registerModule(new BlackbirdModule())
                .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, true);
    }

    private Protocol() {}
}
