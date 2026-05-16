package stt.protocol;

import com.fasterxml.jackson.annotation.JsonValue;

/** Wire-shared error kind. {@code @JsonValue} pins the serialized form to lower_snake_case. */
public enum ErrorKind {
    TIMEOUT("timeout"),
    POOL_TIMEOUT("pool_timeout"),
    HTTP_5XX("http_5xx"),
    HTTP_429("http_429"),
    CONNECTION_RESET("connection_reset"),
    PARSE_ERROR("parse_error"),
    SEND_ERROR("send_error");

    private final String wire;

    ErrorKind(String wire) {
        this.wire = wire;
    }

    @JsonValue
    public String wire() {
        return wire;
    }
}
