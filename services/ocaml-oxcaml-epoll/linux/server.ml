module P = Stt_ocaml_oxcaml_epoll.Protocol
module Ws = Stt_ocaml_oxcaml_epoll.Ws
module Handshake = Stt_ocaml_oxcaml_epoll.Handshake
module Http_request = Stt_ocaml_oxcaml_epoll.Http_request
module Http_response = Stt_ocaml_oxcaml_epoll.Http_response
module Int_stack = Stt_ocaml_oxcaml_epoll.Int_stack
module Mask = Stt_ocaml_oxcaml_epoll.Mask
module Timer_heap = Stt_ocaml_oxcaml_epoll.Timer_heap

let listener_token = 1
let first_slot_token = 2
let first_conn_token = 10000
let request_timeout_ms = 2000.0
let now_ms () = Unix.gettimeofday () *. 1000.0
let install_process_signal_handlers () = Sys.Safe.set_signal Sys.sigpipe Sys.Signal_ignore

type dynbuf =
  { mutable data : Bytes.t
  ; mutable len : int
  }

let dynbuf cap = { data = Bytes.create cap; len = 0 }

let ensure b extra =
  let need = b.len + extra in
  if need > Bytes.length b.data
  then (
    let next_len = ref (max 1 (Bytes.length b.data * 2)) in
    while !next_len < need do
      next_len := !next_len * 2
    done;
    let next = Bytes.create !next_len in
    Bytes.blit b.data 0 next 0 b.len;
    b.data <- next)
;;

let append_bytes b src pos len =
  ensure b len;
  Bytes.blit src pos b.data b.len len;
  b.len <- b.len + len
;;

let append_string b s =
  let len = String.length s in
  ensure b len;
  Bytes.blit_string s 0 b.data b.len len;
  b.len <- b.len + len
;;

let clear b = b.len <- 0

let consume_prefix b n =
  if n >= b.len
  then b.len <- 0
  else (
    Bytes.blit b.data n b.data 0 (b.len - n);
    b.len <- b.len - n)
;;

type outbuf =
  { mutable out : Bytes.t
  ; mutable out_pos : int
  ; mutable out_len : int
  }

let outbuf cap = { out = Bytes.create cap; out_pos = 0; out_len = 0 }
let out_pending b = b.out_pos < b.out_len

let out_compact b =
  if b.out_pos > 0
  then (
    if b.out_pos < b.out_len
    then Bytes.blit b.out b.out_pos b.out 0 (b.out_len - b.out_pos);
    b.out_len <- b.out_len - b.out_pos;
    b.out_pos <- 0)
;;

let out_ensure b extra =
  out_compact b;
  let need = b.out_len + extra in
  if need > Bytes.length b.out
  then (
    let next_len = ref (max 1 (Bytes.length b.out * 2)) in
    while !next_len < need do
      next_len := !next_len * 2
    done;
    let next = Bytes.create !next_len in
    Bytes.blit b.out 0 next 0 b.out_len;
    b.out <- next)
;;

let out_add_string b s =
  let len = String.length s in
  out_ensure b len;
  Bytes.blit_string s 0 b.out b.out_len len;
  b.out_len <- b.out_len + len
;;

let out_add_char b c =
  out_ensure b 1;
  Bytes.set b.out b.out_len c;
  b.out_len <- b.out_len + 1
;;

let out_add_ws_frame b opcode payload =
  out_ensure b (Ws.frame_len payload);
  let wrote = Ws.write_frame opcode payload b.out b.out_len in
  b.out_len <- b.out_len + wrote
;;

let out_add_text_generated b write_payload =
  out_compact b;
  out_ensure b 10;
  let frame_start = b.out_len in
  b.out_len <- b.out_len + 10;
  let payload_start = b.out_len in
  write_payload ();
  let payload_len = b.out_len - payload_start in
  let header_len = Ws.write_header Ws.Text payload_len b.out frame_start in
  if header_len <> 10
  then Bytes.blit b.out payload_start b.out (frame_start + header_len) payload_len;
  b.out_len <- frame_start + header_len + payload_len
;;

type conn_state =
  | Handshake
  | Open

type pending =
  { oldest_seq : int
  ; newest_seq : int
  ; oldest_ms : float
  ; newest_ms : float
  ; frames : int
  ; audio_bytes : int
  ; flush_lateness_ms : float
  ; started_ms : float
  ; timeout_gen : int
  ; slot_idx : int
  }

type conn =
  { id : int
  ; fd : Unix.file_descr
  ; input : dynbuf
  ; read_scratch : Bytes.t
  ; output : outbuf
  ; writer : P.json_writer
  ; pcm : dynbuf
  ; mutable batch_oldest_seq : int
  ; mutable batch_newest_seq : int
  ; mutable batch_oldest_ms : float
  ; mutable batch_newest_ms : float
  ; mutable batch_frames : int
  ; mutable seq : int
  ; mutable state : conn_state
  ; mutable started : bool
  ; mutable next_flush_ms : float
  ; mutable flush_gen : int
  ; mutable pending : pending option
  ; mutable timeout_gen : int
  ; mutable close_after_write : bool
  ; mutable closed : bool
  }

type slot_state =
  | Slot_idle
  | Slot_connecting
  | Slot_sending
  | Slot_receiving

type slot =
  { idx : int
  ; mutable fd : Unix.file_descr option
  ; mutable registered : bool
  ; mutable state : slot_state
  ; req : dynbuf
  ; mutable req_pos : int
  ; resp : dynbuf
  ; resp_scratch : Bytes.t
  ; mutable owner : int option
  ; mutable started_ms : float
  ; mutable retried : bool
  }

type server =
  { config : Config.t
  ; epoll : Epoll.t
  ; listener : Unix.file_descr
  ; inference_addr : Unix.sockaddr
  ; conns : (int, conn) Hashtbl.t
  ; slots : slot array
  ; free_slots : Int_stack.t
  ; timers : Timer_heap.t
  ; timer_event : Timer_heap.event
  ; mutable next_conn_id : int
  }

let conn_token id = first_conn_token + id
let token_conn token = token - first_conn_token
let slot_token idx = first_slot_token + idx
let token_slot token = token - first_slot_token
let timer_flush = 0
let timer_timeout = 1
let slot_is_free slot = slot.state = Slot_idle && slot.owner = None

let slot_can_handle_event slot =
  match slot.state, slot.owner with
  | Slot_idle, _ | _, None -> false
  | (Slot_connecting | Slot_sending | Slot_receiving), Some _ -> true
;;

let slot_has_readable_response_event slot events =
  slot.state = Slot_receiving && events land Epoll.epollin <> 0
;;

let has_socket_error_event events = events land (Epoll.epollerr lor Epoll.epollhup) <> 0

let schedule_flush (s : server) (c : conn) =
  Timer_heap.push
    s.timers
    ~at_ms:c.next_flush_ms
    ~token:c.id
    ~kind:timer_flush
    ~gen:c.flush_gen
;;

let schedule_timeout (s : server) (c : conn) (p : pending) =
  Timer_heap.push
    s.timers
    ~at_ms:(p.started_ms +. request_timeout_ms)
    ~token:c.id
    ~kind:timer_timeout
    ~gen:p.timeout_gen
;;

let set_nonblock fd =
  Unix.set_nonblock fd;
  try Unix.setsockopt fd Unix.TCP_NODELAY true with
  | Unix.Unix_error _ -> ()
;;

let epoll_del_quiet s fd =
  try Epoll.del s.epoll fd with
  | Unix.Unix_error _ -> ()
;;

let close_fd_quiet fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let conn_events (c : conn) =
  let read = if c.close_after_write || c.closed then 0 else Epoll.epollin in
  let write = if out_pending c.output then Epoll.epollout else 0 in
  read lor write lor Epoll.epollerr lor Epoll.epollhup
;;

let update_conn (s : server) (c : conn) =
  if not c.closed
  then (
    let events = conn_events c in
    if events = 0 then () else Epoll.mod_ s.epoll c.fd ~events ~token:(conn_token c.id))
;;

let clear_batch (c : conn) = c.batch_frames <- 0

let record_batch_frame (c : conn) received_ms =
  c.seq <- c.seq + 1;
  if c.batch_frames = 0
  then (
    c.batch_oldest_seq <- c.seq;
    c.batch_oldest_ms <- received_ms);
  c.batch_newest_seq <- c.seq;
  c.batch_newest_ms <- received_ms;
  c.batch_frames <- c.batch_frames + 1
;;

let record_pcm (c : conn) payload =
  let received_ms = now_ms () in
  record_batch_frame c received_ms;
  append_string c.pcm payload
;;

let record_pcm_masked (c : conn) src payload_pos mask_pos =
  let received_ms = now_ms () in
  record_batch_frame c received_ms;
  ensure c.pcm P.frame_bytes;
  Mask.copy_unmasked_640 src ~payload_pos ~mask_pos c.pcm.data ~dst_pos:c.pcm.len;
  c.pcm.len <- c.pcm.len + P.frame_bytes
;;

let enqueue_raw (s : server) (c : conn) payload =
  out_add_string c.output payload;
  update_conn s c
;;

let enqueue_text (s : server) (c : conn) payload =
  out_add_ws_frame c.output Ws.Text payload;
  update_conn s c
;;

let enqueue_generated_text (s : server) (c : conn) write_payload =
  out_add_text_generated c.output write_payload;
  update_conn s c
;;

let enqueue_partial (s : server) (c : conn) partial =
  enqueue_generated_text s c (fun () -> P.write_partial_json c.writer partial)
;;

let enqueue_error (s : server) (c : conn) err =
  enqueue_generated_text s c (fun () -> P.write_error_json c.writer err)
;;

let enqueue_close (s : server) (c : conn) code =
  if not c.closed
  then (
    enqueue_raw s c (Ws.close ~code ());
    c.close_after_write <- true;
    update_conn s c)
;;

let close_conn (s : server) (c : conn) =
  if not c.closed
  then (
    c.closed <- true;
    Array.iter
      (fun slot ->
        match slot.owner with
        | Some owner when owner = c.id ->
          (match slot.fd with
           | None -> ()
           | Some fd ->
             if slot.registered then epoll_del_quiet s fd;
             close_fd_quiet fd);
          slot.fd <- None;
          slot.registered <- false;
          slot.owner <- None;
          slot.state <- Slot_idle;
          slot.req_pos <- 0;
          clear slot.resp;
          Int_stack.push s.free_slots slot.idx
        | _ -> ())
      s.slots;
    epoll_del_quiet s c.fd;
    close_fd_quiet c.fd;
    Hashtbl.remove s.conns c.id)
;;

let write_conn (s : server) (c : conn) =
  let rec loop () =
    if not (out_pending c.output)
    then ()
    else (
      match
        Unix.write c.fd c.output.out c.output.out_pos (c.output.out_len - c.output.out_pos)
      with
      | 0 -> close_conn s c
      | n ->
        c.output.out_pos <- c.output.out_pos + n;
        loop ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
      | exception Unix.Unix_error _ -> close_conn s c)
  in
  loop ();
  if not (out_pending c.output)
  then (
    c.output.out_pos <- 0;
    c.output.out_len <- 0;
    if c.close_after_write then close_conn s c else update_conn s c)
  else update_conn s c
;;

let find_double_crlf b len =
  let rec loop i =
    if i + 3 >= len
    then None
    else if Bytes.get b i = '\r'
            && Bytes.get b (i + 1) = '\n'
            && Bytes.get b (i + 2) = '\r'
            && Bytes.get b (i + 3) = '\n'
    then Some i
    else loop (i + 1)
  in
  loop 0
;;

let trim_cr s =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '\r' then String.sub s 0 (len - 1) else s
;;

let header_value lines name =
  let lower = String.lowercase_ascii name in
  List.find_map
    (fun line ->
      match String.index_opt line ':' with
      | None -> None
      | Some i ->
        let k = String.sub line 0 i |> String.trim |> String.lowercase_ascii in
        if k = lower
        then Some (String.sub line (i + 1) (String.length line - i - 1) |> String.trim)
        else None)
    lines
;;

let http_response code reason body =
  Printf.sprintf
    "HTTP/1.1 %d %s\r\n\
     Content-Length: %d\r\n\
     Content-Type: text/plain\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    code
    reason
    (String.length body)
    body
;;

let websocket_upgrade key =
  Printf.sprintf
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Accept: %s\r\n\
     \r\n"
    (Handshake.accept_key key)
;;

let consume_input (c : conn) n = consume_prefix c.input n

let fixed_binary_640_at (c : conn) pos =
  c.started
  && c.input.len - pos >= 648
  && Char.code (Bytes.get c.input.data pos) = 0x82
  && Char.code (Bytes.get c.input.data (pos + 1)) = 0xfe
  && Bytes.get_uint16_be c.input.data (pos + 2) = P.frame_bytes
;;

let consume_fast_binary_640_run (c : conn) =
  let rec loop pos =
    if fixed_binary_640_at c pos
    then (
      record_pcm_masked c c.input.data (pos + 8) (pos + 4);
      loop (pos + 648))
    else pos
  in
  let consumed = loop 0 in
  if consumed > 0
  then (
    consume_input c consumed;
    true)
  else false
;;

let rec process_frames (s : server) (c : conn) =
  if c.closed
  then ()
  else if consume_fast_binary_640_run c
  then process_frames s c
  else (
    match Ws.parse_one c.input.data ~pos:0 ~len:c.input.len with
    | Error _ -> enqueue_close s c 1002
    | Ok None -> ()
    | Ok (Some (frame, next)) ->
      consume_input c next;
      (match frame.opcode with
       | Ws.Text when not c.started ->
         (match P.start_message_ok frame.payload with
          | Ok () ->
            c.started <- true;
            process_frames s c
          | Error _ -> enqueue_close s c 1002)
       | Ws.Text -> enqueue_close s c 1002
       | Ws.Binary when not c.started -> enqueue_close s c 1002
       | Ws.Binary ->
         if String.length frame.payload = P.frame_bytes
         then (
           record_pcm c frame.payload;
           process_frames s c)
         else enqueue_close s c 1003
       | Ws.Ping ->
         enqueue_raw s c (Ws.pong frame.payload);
         process_frames s c
       | Ws.Pong -> process_frames s c
       | Ws.Close ->
         enqueue_raw s c (Ws.close ~code:1000 ());
         c.close_after_write <- true;
         update_conn s c
       | Ws.Continuation | Ws.Other _ -> enqueue_close s c 1002))
;;

let process_http (s : server) (c : conn) =
  match find_double_crlf c.input.data c.input.len with
  | None -> if c.input.len > 16 * 1024 then close_conn s c
  | Some head_end ->
    let head = Bytes.sub_string c.input.data 0 head_end in
    let lines = String.split_on_char '\n' head |> List.map trim_cr in
    let request_line =
      match lines with
      | [] -> ""
      | line :: _ -> line
    in
    let parts = String.split_on_char ' ' request_line in
    let method_, path =
      match parts with
      | method_ :: path :: _ -> method_, path
      | _ -> "", ""
    in
    consume_input c (head_end + 4);
    if method_ <> "GET"
    then (
      enqueue_raw s c (http_response 405 "Method Not Allowed" "");
      c.close_after_write <- true;
      update_conn s c)
    else (
      match path with
      | "/health" ->
        enqueue_raw s c (http_response 200 "OK" "ok");
        c.close_after_write <- true;
        update_conn s c
      | "/ws/stt" ->
        (match header_value lines "sec-websocket-key" with
         | None ->
           enqueue_raw s c (http_response 400 "Bad Request" "invalid websocket upgrade");
           c.close_after_write <- true;
           update_conn s c
         | Some key ->
           c.state <- Open;
           enqueue_raw s c (websocket_upgrade key);
           process_frames s c)
      | _ ->
        enqueue_raw s c (http_response 404 "Not Found" "not found");
        c.close_after_write <- true;
        update_conn s c)
;;

let read_conn (s : server) (c : conn) =
  let rec loop () =
    match Unix.read c.fd c.read_scratch 0 (Bytes.length c.read_scratch) with
    | 0 -> close_conn s c
    | n ->
      append_bytes c.input c.read_scratch 0 n;
      if n = Bytes.length c.read_scratch then loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | exception Unix.Unix_error _ -> close_conn s c
  in
  loop ();
  if not c.closed
  then (
    match c.state with
    | Handshake -> process_http s c
    | Open -> process_frames s c)
;;

let slot_events = function
  | Slot_connecting | Slot_sending -> Epoll.epollout lor Epoll.epollerr lor Epoll.epollhup
  | Slot_receiving -> Epoll.epollin lor Epoll.epollerr lor Epoll.epollhup
  | Slot_idle -> 0
;;

let register_slot (s : server) (slot : slot) =
  match slot.fd with
  | None -> ()
  | Some fd ->
    let events = slot_events slot.state in
    if events <> 0
    then
      if slot.registered
      then Epoll.mod_ s.epoll fd ~events ~token:(slot_token slot.idx)
      else (
        Epoll.add s.epoll fd ~events ~token:(slot_token slot.idx);
        slot.registered <- true)
;;

let unregister_slot (s : server) (slot : slot) =
  match slot.fd with
  | None -> ()
  | Some fd ->
    if slot.registered
    then (
      epoll_del_quiet s fd;
      slot.registered <- false)
;;

let close_slot_fd (s : server) (slot : slot) =
  unregister_slot s slot;
  match slot.fd with
  | None -> ()
  | Some fd ->
    close_fd_quiet fd;
    slot.fd <- None
;;

let free_slot (s : server) (slot : slot) =
  if slot_is_free slot
  then ()
  else (
    unregister_slot s slot;
    slot.owner <- None;
    slot.state <- Slot_idle;
    slot.req_pos <- 0;
    clear slot.resp;
    Int_stack.push s.free_slots slot.idx)
;;

let connect_slot (s : server) (slot : slot) =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  set_nonblock fd;
  slot.fd <- Some fd;
  slot.state <- Slot_connecting;
  (try Unix.connect fd s.inference_addr with
   | Unix.Unix_error ((Unix.EINPROGRESS | Unix.EALREADY | Unix.EWOULDBLOCK), _, _) -> ()
   | exn ->
     close_slot_fd s slot;
     raise exn);
  register_slot s slot
;;

let build_request (s : server) (slot : slot) body body_len =
  clear slot.req;
  slot.req_pos <- 0;
  let header_len =
    Http_request.infer_header_len
      ~host:s.config.inference_host
      ~port:s.config.inference_port
      ~cpu_passes:s.config.cpu_passes
      ~body_len
  in
  ensure slot.req (header_len + body_len);
  let wrote =
    Http_request.write_infer_header
      ~host:s.config.inference_host
      ~port:s.config.inference_port
      ~cpu_passes:s.config.cpu_passes
      ~body_len
      slot.req.data
      slot.req.len
  in
  slot.req.len <- slot.req.len + wrote;
  append_bytes slot.req body 0 body_len
;;

let classify_status status =
  if status = 429 then P.Http_429, true else P.Http_5xx, status >= 500
;;

let parse_http_response b =
  match Http_response.parse b.data ~len:b.len with
  | None -> None
  | Some parsed -> Some (parsed.status, parsed.body_pos, parsed.body_len)
;;

let make_transport_error kind message elapsed_ms : P.error =
  { P.stage = P.Inference_request
  ; kind
  ; message
  ; oldest_frame_seq = 0
  ; newest_frame_seq = 0
  ; frames = 0
  ; audio_bytes = 0
  ; oldest_age_ms = 0.0
  ; newest_age_ms = 0.0
  ; flush_lateness_ms = 0.0
  ; inference_elapsed_ms = Some elapsed_ms
  ; inflight_gateway_batches = 1
  ; gateway_buffer_frames = 0
  ; inference_status = None
  ; retryable = true
  }
;;

let deliver_error (s : server) (c : conn) (p : pending) (err : P.error) =
  let now = now_ms () in
  let err =
    { err with
      P.oldest_frame_seq = p.oldest_seq
    ; newest_frame_seq = p.newest_seq
    ; frames = p.frames
    ; audio_bytes = p.audio_bytes
    ; oldest_age_ms = max 0.0 (now -. p.oldest_ms)
    ; newest_age_ms = max 0.0 (now -. p.newest_ms)
    ; flush_lateness_ms = p.flush_lateness_ms
    ; gateway_buffer_frames = c.batch_frames
    }
  in
  c.pending <- None;
  enqueue_error s c err
;;

let deliver_result (s : server) owner result =
  match Hashtbl.find_opt s.conns owner with
  | None -> ()
  | Some c ->
    (match c.pending with
     | None -> ()
     | Some p ->
       c.pending <- None;
       (match result with
        | Ok (infer : P.infer_response) ->
          let partial : P.partial =
            { P.oldest_frame_seq = p.oldest_seq
            ; newest_frame_seq = p.newest_seq
            ; frames = p.frames
            ; rms = infer.rms
            ; zero_crossings = infer.zero_crossings
            ; checksum = infer.checksum
            ; samples = infer.samples
            ; transcript = infer.transcript
            ; audio_bytes = infer.audio_bytes
            ; cpu_passes = s.config.cpu_passes
            ; model_delay_ms = s.config.model_delay_ms
            ; flush_lateness_ms = p.flush_lateness_ms
            }
          in
          enqueue_partial s c partial
        | Error err -> deliver_error s c p err))
;;

let slot_done (s : server) (slot : slot) result =
  let owner = slot.owner in
  free_slot s slot;
  match owner with
  | None -> ()
  | Some owner -> deliver_result s owner result
;;

let retry_or_fail (s : server) (slot : slot) message =
  if not slot.retried
  then (
    slot.retried <- true;
    close_slot_fd s slot;
    slot.req_pos <- 0;
    clear slot.resp;
    try connect_slot s slot with
    | Unix.Unix_error _ ->
      slot_done s slot (Error (make_transport_error P.Connection_reset message 0.0)))
  else (
    let elapsed = now_ms () -. slot.started_ms in
    close_slot_fd s slot;
    slot_done s slot (Error (make_transport_error P.Connection_reset message elapsed)))
;;

let drive_slot (s : server) (slot : slot) =
  match slot.fd, slot.state with
  | None, _ | _, Slot_idle -> ()
  | Some fd, Slot_connecting ->
    (match Unix.getsockopt_error fd with
     | None ->
       slot.state <- Slot_sending;
       register_slot s slot
     | Some err -> retry_or_fail s slot (Unix.error_message err))
  | Some fd, Slot_sending ->
    let rec loop () =
      if slot.req_pos >= slot.req.len
      then (
        slot.state <- Slot_receiving;
        register_slot s slot)
      else (
        match Unix.write fd slot.req.data slot.req_pos (slot.req.len - slot.req_pos) with
        | 0 -> retry_or_fail s slot "inference write returned zero"
        | n ->
          slot.req_pos <- slot.req_pos + n;
          loop ()
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          register_slot s slot
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
        | exception Unix.Unix_error (_, name, msg) ->
          retry_or_fail s slot (name ^ ": " ^ msg))
    in
    loop ()
  | Some fd, Slot_receiving ->
    let rec loop () =
      match Unix.read fd slot.resp_scratch 0 (Bytes.length slot.resp_scratch) with
      | 0 -> retry_or_fail s slot "inference closed response"
      | n ->
        append_bytes slot.resp slot.resp_scratch 0 n;
        (match parse_http_response slot.resp with
         | None -> loop ()
         | Some (status, body_pos, body_len) ->
           if status < 200 || status >= 300
           then (
             let kind, retryable = classify_status status in
             slot_done
               s
               slot
               (Error
                  { (make_transport_error
                       kind
                       (Printf.sprintf "inference returned HTTP %d" status)
                       (now_ms () -. slot.started_ms))
                    with
                    P.inference_status = Some status
                  ; retryable
                  }))
           else (
             match
               P.infer_response_of_bytes slot.resp.data ~pos:body_pos ~len:body_len
             with
             | Ok infer -> slot_done s slot (Ok infer)
             | Error message ->
               slot_done
                 s
                 slot
                 (Error
                    { (make_transport_error
                         P.Parse_error
                         message
                         (now_ms () -. slot.started_ms))
                      with
                      P.stage = P.Inference_response_parse
                    ; inference_status = Some status
                    ; retryable = false
                    })))
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
        register_slot s slot
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
      | exception Unix.Unix_error (_, name, msg) ->
        retry_or_fail s slot (name ^ ": " ^ msg)
    in
    loop ()
;;

let submit_inference (s : server) (c : conn) (p : pending) =
  match Int_stack.pop s.free_slots with
  | None ->
    deliver_error
      s
      c
      p
      (make_transport_error P.Connection_reset "inference pool exhausted" 0.0)
  | Some idx ->
    let slot = s.slots.(idx) in
    slot.owner <- Some c.id;
    slot.started_ms <- p.started_ms;
    slot.retried <- false;
    clear slot.resp;
    build_request s slot c.pcm.data c.pcm.len;
    clear c.pcm;
    clear_batch c;
    c.pending <- Some p;
    schedule_timeout s c p;
    if slot.fd = None
    then (
      try connect_slot s slot with
      | Unix.Unix_error (_, name, msg) ->
        slot_done
          s
          slot
          (Error (make_transport_error P.Connection_reset (name ^ ": " ^ msg) 0.0)))
    else (
      slot.state <- Slot_sending;
      register_slot s slot)
;;

let flush_conn (s : server) (c : conn) now =
  if c.closed
  then ()
  else (
    let expected = c.next_flush_ms in
    let flush_lateness_ms = max 0.0 (now -. expected) in
    c.next_flush_ms <- expected +. float_of_int s.config.flush_interval_ms;
    c.flush_gen <- c.flush_gen + 1;
    schedule_flush s c;
    match c.pending with
    | Some _ -> ()
    | None ->
      if c.batch_frames > 0
      then (
        let frames = c.batch_frames in
        let p =
          { oldest_seq = c.batch_oldest_seq
          ; newest_seq = c.batch_newest_seq
          ; oldest_ms = c.batch_oldest_ms
          ; newest_ms = c.batch_newest_ms
          ; frames
          ; audio_bytes = c.pcm.len
          ; flush_lateness_ms
          ; started_ms = now
          ; timeout_gen = c.timeout_gen + 1
          ; slot_idx = -1
          }
        in
        c.timeout_gen <- p.timeout_gen;
        submit_inference s c p))
;;

let timeout_conn (s : server) (c : conn) now gen =
  match c.pending with
  | None -> ()
  | Some p when p.timeout_gen <> gen -> ()
  | Some p ->
    Array.iter
      (fun slot ->
        if slot.owner = Some c.id
        then (
          close_slot_fd s slot;
          free_slot s slot))
      s.slots;
    deliver_error
      s
      c
      p
      (make_transport_error P.Timeout "inference timed out" (now -. p.started_ms))
;;

let process_timers s =
  let now = now_ms () in
  let rec loop () =
    match Timer_heap.peek_at_ms s.timers with
    | None -> ()
    | Some at_ms when at_ms > now -> ()
    | Some _ ->
      if Timer_heap.pop_into s.timers s.timer_event
      then (
        (match Hashtbl.find_opt s.conns s.timer_event.token with
         | None -> ()
         | Some c ->
           if s.timer_event.kind = timer_flush && s.timer_event.gen = c.flush_gen
           then flush_conn s c now
           else if s.timer_event.kind = timer_timeout
           then timeout_conn s c now s.timer_event.gen);
        loop ())
  in
  loop ()
;;

let next_timeout_ms s =
  match Timer_heap.peek_at_ms s.timers with
  | None -> 1000
  | Some at_ms ->
    let delta = at_ms -. now_ms () in
    if delta <= 0.0 then 0 else min 1000 (int_of_float (ceil delta))
;;

let create_conn s fd =
  let jitter =
    if s.config.flush_phase_jitter_ms <= 0
    then 0.0
    else Random.float (float_of_int s.config.flush_phase_jitter_ms)
  in
  let id = s.next_conn_id in
  s.next_conn_id <- s.next_conn_id + 1;
  let output = outbuf 1024 in
  let writer : P.json_writer =
    { add_string = (fun str -> out_add_string output str)
    ; add_char = (fun chr -> out_add_char output chr)
    }
  in
  { id
  ; fd
  ; input = dynbuf 4096
  ; read_scratch = Bytes.create 8192
  ; output
  ; writer
  ; pcm = dynbuf (64 * P.frame_bytes)
  ; batch_oldest_seq = 0
  ; batch_newest_seq = 0
  ; batch_oldest_ms = 0.0
  ; batch_newest_ms = 0.0
  ; batch_frames = 0
  ; seq = 0
  ; state = Handshake
  ; started = false
  ; next_flush_ms = now_ms () +. float_of_int s.config.flush_interval_ms +. jitter
  ; flush_gen = 0
  ; pending = None
  ; timeout_gen = 0
  ; close_after_write = false
  ; closed = false
  }
;;

let accept_loop s =
  let rec loop () =
    match Unix.accept s.listener with
    | fd, _addr ->
      set_nonblock fd;
      let c = create_conn s fd in
      Hashtbl.add s.conns c.id c;
      Epoll.add s.epoll fd ~events:(conn_events c) ~token:(conn_token c.id);
      schedule_flush s c;
      loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | exception Unix.Unix_error _ -> ()
  in
  loop ()
;;

let bind_listener port =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt fd Unix.SO_REUSEADDR true;
  set_nonblock fd;
  Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_any, port));
  Unix.listen fd 8192;
  fd
;;

let resolve_inference config =
  let entry = Unix.gethostbyname config.Config.inference_host in
  if Array.length entry.Unix.h_addr_list = 0
  then failwith ("cannot resolve " ^ config.inference_host)
  else Unix.ADDR_INET (entry.Unix.h_addr_list.(0), config.inference_port)
;;

let create_slot idx =
  { idx
  ; fd = None
  ; registered = false
  ; state = Slot_idle
  ; req = dynbuf (64 * P.frame_bytes)
  ; req_pos = 0
  ; resp = dynbuf 1024
  ; resp_scratch = Bytes.create 4096
  ; owner = None
  ; started_ms = 0.0
  ; retried = false
  }
;;

let create_server config =
  let epoll = Epoll.create 0 in
  let listener = bind_listener config.Config.port in
  Epoll.add epoll listener ~events:Epoll.epollin ~token:listener_token;
  let slots = Array.init config.inference_http_clients create_slot in
  { config
  ; epoll
  ; listener
  ; inference_addr = resolve_inference config
  ; conns = Hashtbl.create 4096
  ; slots
  ; free_slots = Int_stack.of_init config.inference_http_clients Fun.id
  ; timers = Timer_heap.create 1024
  ; timer_event = Timer_heap.create_event ()
  ; next_conn_id = 1
  }
;;

let handle_event s ~token ~events =
  if token = listener_token
  then accept_loop s
  else if token >= first_slot_token && token < first_slot_token + Array.length s.slots
  then (
    let slot = s.slots.(token_slot token) in
    if slot_can_handle_event slot
    then (
      let readable_response = slot_has_readable_response_event slot events in
      if readable_response then drive_slot s slot;
      if slot_can_handle_event slot
      then
        if has_socket_error_event events
        then retry_or_fail s slot "inference socket error"
        else if not readable_response
        then drive_slot s slot))
  else if token >= first_conn_token
  then (
    match Hashtbl.find_opt s.conns (token_conn token) with
    | None -> ()
    | Some c ->
      if events land (Epoll.epollerr lor Epoll.epollhup) <> 0
      then close_conn s c
      else (
        if events land Epoll.epollin <> 0 then read_conn s c;
        if (not c.closed) && events land Epoll.epollout <> 0 then write_conn s c))
;;

let run config =
  let s = create_server config in
  let ready = Array.make (4096 * 2) 0 in
  Printf.eprintf
    "{\"runtime\":\"ocaml-oxcaml-epoll\",\"port\":%d,\"inference\":\"%s:%d\",\"inference_clients\":%d,\"flush_interval_ms\":%d}\n\
     %!"
    config.Config.port
    config.inference_host
    config.inference_port
    config.inference_http_clients
    config.flush_interval_ms;
  while true do
    process_timers s;
    Epoll.iter_ready_into
      s.epoll
      ~ready
      ~maxevents:4096
      ~timeout_ms:(next_timeout_ms s)
      ~f:(handle_event s);
    process_timers s
  done
;;
