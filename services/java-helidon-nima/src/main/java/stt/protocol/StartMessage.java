package stt.protocol;

/**
 * First message the client sends on a fresh WebSocket. Strict: must be {@code type=start}. The
 * compact-constructor validation runs on Jackson's canonical-constructor invocation; combined with
 * {@code FAIL_ON_UNKNOWN_PROPERTIES=true} on the shared mapper, that's the full strictness story.
 */
public record StartMessage(String type) {

    public StartMessage {
        if (!"start".equals(type)) {
            throw new IllegalArgumentException("expected type=start, got " + type);
        }
    }
}
