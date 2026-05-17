(** STT gateway entry point.

    Reads config from the env (PORT, INFERENCE_URL, INFERENCE_HTTP_CLIENTS,
    WORKER_THREADS, FLUSH_INTERVAL_MS, FLUSH_PHASE_JITTER_MS, CPU_PASSES, MODEL_DELAY_MS),
    boots the Async scheduler, hands control to
    [Stt_ocaml_websocket_async.Server.start]. *)

open! Core
open! Async

let main () =
  Stt_ocaml_websocket_async.Runtime.assert_stock_ocaml ();
  let config = Stt_ocaml_websocket_async.Config.from_env () in
  Stt_ocaml_websocket_async.Server.start config
;;

let () =
  don't_wait_for (main ());
  never_returns (Scheduler.go ())
;;
