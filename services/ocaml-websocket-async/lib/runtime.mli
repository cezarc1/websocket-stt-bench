(** Startup-time assertion that we're running on the pinned stock OCaml compiler.

    Mirrors the [Py_GIL_DISABLED=1] check in the Python gateway: the benchmark's identity
    is "this runtime exactly", so any silent fallback to a different compiler is a
    defect. *)

val expected_ocaml_version : string
val assert_stock_ocaml : unit -> unit
