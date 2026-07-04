module Epoll = Stt_ocaml_oxcaml_epoll_linux.Epoll
module Config = Stt_ocaml_oxcaml_epoll_linux.Config
module Server = Stt_ocaml_oxcaml_epoll_linux.Server
module Int_stack = Stt_ocaml_oxcaml_epoll.Int_stack

let config clients : Config.t =
  { port = 0
  ; inference_host = "127.0.0.1"
  ; inference_port = 1
  ; inference_http_clients = clients
  ; cpu_passes = 4
  ; model_delay_ms = 75
  ; flush_interval_ms = 1000
  ; flush_phase_jitter_ms = 0
  }
;;

let close_quiet fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let cleanup_server (s : Server.server) =
  close_quiet s.listener;
  Array.iter
    (fun (slot : Server.slot) ->
      match slot.fd with
      | None -> ()
      | Some fd -> close_quiet fd)
    s.slots;
  Hashtbl.iter (fun _ (c : Server.conn) -> close_quiet c.fd) s.conns
;;

let with_server clients f =
  let s = Server.create_server (config clients) in
  Fun.protect ~finally:(fun () -> cleanup_server s) (fun () -> f s)
;;

let pop_free_slot (s : Server.server) =
  match Int_stack.pop s.free_slots with
  | Some idx -> idx
  | None -> Alcotest.fail "expected free slot"
;;

let contains haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    i + nlen <= hlen && (String.sub haystack i nlen = needle || loop (i + 1))
  in
  nlen = 0 || loop 0
;;

let test_signal_handlers_ignore_sigpipe () =
  Sys.Safe.set_signal Sys.sigpipe Sys.Signal_default;
  Server.install_process_signal_handlers ();
  let previous = Sys.Safe.signal Sys.sigpipe Sys.Signal_ignore in
  Alcotest.(check bool)
    "SIGPIPE ignored"
    true
    (match previous with
     | Sys.Signal_ignore -> true
     | Sys.Signal_default | Sys.Signal_handle _ -> false)
;;

let test_idle_slot_hup_event_is_ignored () =
  with_server 1 (fun s ->
    let slot = s.slots.(0) in
    let before = Int_stack.length s.free_slots in
    Server.handle_event s ~token:(Server.slot_token slot.idx) ~events:Epoll.epollhup;
    Alcotest.(check int) "free stack unchanged" before (Int_stack.length s.free_slots);
    Alcotest.(check bool)
      "slot stays idle"
      true
      (match slot.state with
       | Server.Slot_idle -> true
       | Server.Slot_connecting | Server.Slot_sending | Server.Slot_receiving -> false);
    Alcotest.(check bool) "slot has no fd" true (Option.is_none slot.fd))
;;

let test_free_slot_is_idempotent_for_stale_events () =
  with_server 1 (fun s ->
    let idx = pop_free_slot s in
    let slot = s.slots.(idx) in
    slot.owner <- Some 123;
    slot.state <- Server.Slot_receiving;
    Server.free_slot s slot;
    Server.free_slot s slot;
    Alcotest.(check int)
      "free stack restored once"
      (Int_stack.capacity s.free_slots)
      (Int_stack.length s.free_slots))
;;

let test_readable_hup_drains_complete_inference_response () =
  with_server 1 (fun s ->
    let idx = pop_free_slot s in
    let body =
      {|{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640}|}
    in
    let response =
      Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
        (String.length body)
        body
    in
    let peer, slot_fd = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let wrote = Unix.write_substring peer response 0 (String.length response) in
    Alcotest.(check int) "wrote response" (String.length response) wrote;
    close_quiet peer;
    let conn_peer, conn_fd = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    close_quiet conn_peer;
    let conn = Server.create_conn s conn_fd in
    conn.closed <- true;
    let pending : Server.pending =
      { oldest_seq = 1
      ; newest_seq = 1
      ; oldest_ms = 0.0
      ; newest_ms = 0.0
      ; frames = 1
      ; audio_bytes = 640
      ; flush_lateness_ms = 0.0
      ; started_ms = 0.0
      ; timeout_gen = 1
      ; slot_idx = idx
      }
    in
    conn.pending <- Some pending;
    Hashtbl.add s.conns conn.id conn;
    let slot = s.slots.(idx) in
    slot.fd <- Some slot_fd;
    slot.owner <- Some conn.id;
    slot.state <- Server.Slot_receiving;
    slot.retried <- true;
    Server.handle_event
      s
      ~token:(Server.slot_token slot.idx)
      ~events:(Epoll.epollin lor Epoll.epollhup);
    let output = Bytes.sub_string conn.output.out 0 conn.output.out_len in
    Alcotest.(check bool)
      "response delivered as partial"
      true
      (contains output {|"type":"partial"|});
    Alcotest.(check bool)
      "not delivered as error"
      false
      (contains output {|"type":"error"|});
    Alcotest.(check int)
      "free stack restored"
      (Int_stack.capacity s.free_slots)
      (Int_stack.length s.free_slots))
;;

let () =
  Alcotest.run
    "stt-ocaml-oxcaml-epoll-linux"
    [ ( "server"
      , [ Alcotest.test_case
            "signal handlers ignore SIGPIPE"
            `Quick
            test_signal_handlers_ignore_sigpipe
        ; Alcotest.test_case
            "idle slot HUP event is ignored"
            `Quick
            test_idle_slot_hup_event_is_ignored
        ; Alcotest.test_case
            "free slot is idempotent for stale events"
            `Quick
            test_free_slot_is_idempotent_for_stale_events
        ; Alcotest.test_case
            "readable HUP drains complete inference response"
            `Quick
            test_readable_hup_drains_complete_inference_response
        ] )
    ]
;;
