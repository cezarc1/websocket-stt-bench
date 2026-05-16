package stt.protocol;

/**
 * Per-frame state captured at receive time. Not on the wire. {@code receivedAtNanos} is a
 * {@link System#nanoTime()} reading -- used only for relative elapsed-millis math, never as an
 * absolute timestamp.
 */
public final class Frame {
    private final long seq;
    private final byte[] payload;
    private final long receivedAtNanos;

    public Frame(long seq, byte[] payload, long receivedAtNanos) {
        this.seq = seq;
        this.payload = payload;
        this.receivedAtNanos = receivedAtNanos;
    }

    public long seq() {
        return seq;
    }

    public byte[] payload() {
        return payload;
    }

    public long receivedAtNanos() {
        return receivedAtNanos;
    }
}
