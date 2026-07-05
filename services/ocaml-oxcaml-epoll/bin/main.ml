let () =
  Stt_ocaml_oxcaml_epoll_linux.Server.install_process_signal_handlers ();
  Random.self_init ();
  let config = Stt_ocaml_oxcaml_epoll_linux.Config.load () in
  Stt_ocaml_oxcaml_epoll_linux.Server.run config
;;
