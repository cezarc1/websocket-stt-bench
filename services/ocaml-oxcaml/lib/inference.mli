open! Core

(** Inference-server HTTP client.

    Posts a concatenated PCM batch to the shared inference server's [/infer] endpoint with
    the [x-cpu-passes] header and decodes the response. {!send} always returns a [Token.t]
    — even on error — so the session can mint a fresh capability and keep serving the
    client instead of wedging on a transient inference failure.

    Each session owns one {!conn}: a persistent HTTP/1.1 keep-alive connection reused
    across flushes. The per-connection one-inflight-inference invariant means requests on
    a [conn] are strictly sequential, so a single long-lived connection per session is
    both correct and optimal — it removes the per-flush TCP connect + DNS + handshake that
    otherwise caps the gateway on connection churn. A dead/closed keep-alive connection is
    transparently redialed (one retry) before a flush is reported as an error.

    Every request is bounded by {!request_timeout}.

    Transport note: HTTP/1.1 (Content-Length framed) over raw [Async.Tcp]. The inference
    server (axum/hyper) speaks HTTP/1.1 keep-alive, so protocol semantics are correct. h2c
    is future work. *)

type t

val create : Config.t -> t

(** Per-session persistent connection state. Create one per WebSocket session and thread
    it through every {!send}. *)
type conn

val create_conn : unit -> conn
val close_conn : conn -> unit Async.Deferred.t

(** [stage] / [kind] use the wire-shared vocabulary from
    [services/rust-axum/src/protocol.rs] (ErrorStage / ErrorKind):
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

(** [body] is the list of raw PCM frame strings (verbatim from the WebSocket layer);
    [body_len] is their total length. They are written straight to the socket after the
    request head — no concat buffer. *)
val send
  :  t
  -> conn:conn
  -> capability:Inflight_capability.t
  -> body:string list
  -> body_len:int
  -> outcome Async.Deferred.t
