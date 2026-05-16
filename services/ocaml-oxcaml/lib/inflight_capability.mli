(** Per-session inflight-inference capability.

    Every other gateway in the comparison enforces "one in-flight inference per
    connection" at runtime (Rust [Semaphore<1>], Java [AtomicBoolean], Go single-slot
    channel, Elixir [busy?] flag, Python walrus-guarded [Task | None]). Here the same
    invariant is structured as an opaque capability:

    + The session mints one capability at construction via {!create_for_session}.
    + {!consume} turns the capability into a one-shot [Token.t] tied to a particular
      inference call.
    + {!of_token} re-mints a fresh capability after the inference call resolves.

    Combined with the runtime serialisation in [Session]'s [Mvar], the chain "one inflight
    in flight at a time" is enforced both at the type level (the only path from token back
    to capability is [of_token]) and at runtime (the [Mvar] is empty while a capability is
    consumed).

    A stricter compile-time-only proof would require passing the capability with OxCaml's
    [@ unique] mode all the way through Async's [Deferred] machinery, but stock Async APIs
    aren't mode-annotated, so the deferred boundary forces an [aliased]-mode cast.
    Tightening this is future work; today the linear-use property is enforced by API shape
    (no [create] export to fabricate a second capability outside the session) and runtime
    serialisation. *)

type t

module Token : sig
  type t
end

val create_for_session : unit -> t
val consume : t -> Token.t
val of_token : Token.t -> t
