open! Core

(** Inference-server HTTP client.

    Posts a concatenated PCM batch to the shared inference server's [/infer] endpoint with
    the [x-cpu-passes] header and decodes the response. {!send} always returns a [Token.t]
    — even on error — so the session can mint a fresh capability and keep serving the
    client instead of wedging on a transient inference failure.

    Every request is bounded by {!request_timeout}; a stalled inference can't hold the
    session's capability forever (mirrors the Rust gateway's 2 s request deadline).

    Transport note: HTTP/1.1 over raw [Async.Tcp]. The inference server (axum/hyper)
    accepts both HTTP/1.1 and HTTP/2 cleartext on the same listener, so protocol semantics
    are correct. h2c is future work. *)

type t

val create : Config.t -> t

(** [stage] / [kind] use the wire-shared vocabulary from
    [services/rust-axum/src/protocol.rs] (ErrorStage / ErrorKind) so cross-runtime error
    analysis stays consistent:
    - stage ∈ [{inference_request, inference_response_parse}]
    - kind ∈ [{timeout, connection_reset, http_5xx, http_429, parse_error}] *)
type error =
  { stage : string
  ; kind : string
  ; message : string
  ; status : int option
  }

type outcome =
  { result : (Protocol.Infer_response.t, error) Result.t
  ; token : Inflight_capability.Token.t
  }

val request_timeout : Time_ns.Span.t

val send
  :  t
  -> capability:Inflight_capability.t
  -> payload:Bigstring.t
  -> outcome Async.Deferred.t
