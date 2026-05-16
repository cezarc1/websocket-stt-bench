package stt.inference;

import org.jspecify.annotations.Nullable;
import stt.protocol.ErrorKind;
import stt.protocol.ErrorStage;

/** Classified failure bubbled up to {@code Session} for error-message synthesis. */
public final class InferenceException extends RuntimeException {

    private final ErrorStage stage;
    private final ErrorKind kind;
    private final @Nullable Integer status;
    private final boolean retryable;

    public InferenceException(
            ErrorStage stage, ErrorKind kind, String message, @Nullable Integer status, boolean retryable) {
        this(stage, kind, message, status, retryable, null);
    }

    public InferenceException(
            ErrorStage stage,
            ErrorKind kind,
            String message,
            @Nullable Integer status,
            boolean retryable,
            @Nullable Throwable cause) {
        super(message, cause);
        this.stage = stage;
        this.kind = kind;
        this.status = status;
        this.retryable = retryable;
    }

    public ErrorStage stage() {
        return stage;
    }

    public ErrorKind kind() {
        return kind;
    }

    public @Nullable Integer status() {
        return status;
    }

    public boolean retryable() {
        return retryable;
    }
}
