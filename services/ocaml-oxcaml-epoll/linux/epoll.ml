type t = int

let epollin = 0x001
let epollout = 0x004
let epollerr = 0x008
let epollhup = 0x010
let epoll_ctl_add = 1
let epoll_ctl_del = 2
let epoll_ctl_mod = 3

external create : int -> t = "stt_epoll_create1"
external ctl : t -> int -> Unix.file_descr -> int -> int -> unit = "stt_epoll_ctl"
external wait : t -> int -> int -> int array = "stt_epoll_wait"
external wait_into : t -> int -> int -> int array -> int = "stt_epoll_wait_into"
external eventfd : int -> int -> Unix.file_descr = "stt_eventfd"
external eventfd_write : Unix.file_descr -> int -> unit = "stt_eventfd_write"
external eventfd_read : Unix.file_descr -> int = "stt_eventfd_read"

let add t fd ~events ~token = ctl t epoll_ctl_add fd events token
let mod_ t fd ~events ~token = ctl t epoll_ctl_mod fd events token
let del t fd = ctl t epoll_ctl_del fd 0 0

let iter_ready t ~maxevents ~timeout_ms ~f =
  let events = wait t maxevents timeout_ms in
  let n = Array.length events / 2 in
  for i = 0 to n - 1 do
    f ~token:events.(i * 2) ~events:events.((i * 2) + 1)
  done
;;

let iter_ready_into t ~ready ~maxevents ~timeout_ms ~f =
  if Array.length ready < maxevents * 2
  then invalid_arg "Epoll.iter_ready_into: ready array too small";
  let n = wait_into t maxevents timeout_ms ready in
  for i = 0 to n - 1 do
    f ~token:ready.(i * 2) ~events:ready.((i * 2) + 1)
  done
;;
