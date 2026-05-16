package stt.protocol;

/**
 * Sealed sum of the two wire shapes the gateway emits on each flush — {@link PartialMessage} on
 * success, {@link ErrorMessage} on inference failure. Exhaustiveness lets {@code Session}'s
 * outbound dispatch be a complete {@code switch} expression with no default arm.
 */
public sealed interface OutboundMessage permits PartialMessage, ErrorMessage {}
