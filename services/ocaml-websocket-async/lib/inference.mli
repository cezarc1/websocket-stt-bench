open! Core

(** Inference-server HTTP client.

    Posts a PCM batch to the shared inference server's [/infer] endpoint with the
    [x-cpu-passes] header (HTTP/1.1, Content-Length framed, over raw [Async.Tcp]) and
    decodes the response.

    Each session owns one {!conn}: a persistent keep-alive socket reused across flushes.
    The one-inflight-per-connection invariant makes requests on a [conn] strictly
    sequential, so one long-lived socket per session is both correct and optimal (no pool)
    and removes the per-flush connect+handshake that otherwise caps the gateway on
    connection churn. A stale/closed socket is transparently redialed once before a flush
    is reported as an error. Every request is bounded by {!request_timeout}. h2c is future
    work. *)

type t

val create : Config.t -> t

(** Per-session persistent connection state. Create one per WebSocket session and thread
    it through every {!send}. *)
type conn

val create_conn : unit -> conn
val close_conn : conn -> unit Async.Deferred.t

(** [stage] / [kind] are the wire-shared error categories ({!Protocol.Error_stage} /
    {!Protocol.Error_kind}); they flatten to the strings the Rust protocol defines only at
    serialization. *)
type error =
  { stage : Protocol.Error_stage.t
  ; kind : Protocol.Error_kind.t
  ; message : string
  ; status : int option
  }

type outcome = { result : (Protocol.Infer_response.t, error) Result.t }

val request_timeout : Time_ns.Span.t

(** [body] is the list of raw PCM frame strings (verbatim from the WebSocket layer);
    [body_len] is their total length. They are written straight to the socket after the
    request head — no concat buffer. *)
val send : t -> conn:conn -> body:string list -> body_len:int -> outcome Async.Deferred.t
