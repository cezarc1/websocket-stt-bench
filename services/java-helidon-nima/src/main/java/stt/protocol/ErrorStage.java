package stt.protocol;

import com.fasterxml.jackson.annotation.JsonValue;

/** Wire-shared error stage. {@code @JsonValue} pins the serialized form to lower_snake_case. */
public enum ErrorStage {
    WEBSOCKET_RECEIVE("websocket_receive"),
    BATCH_FLUSH("batch_flush"),
    INFERENCE_REQUEST("inference_request"),
    INFERENCE_RESPONSE_PARSE("inference_response_parse"),
    WEBSOCKET_SEND("websocket_send");

    private final String wire;

    ErrorStage(String wire) {
        this.wire = wire;
    }

    @JsonValue
    public String wire() {
        return wire;
    }
}
