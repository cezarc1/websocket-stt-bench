open! Core

let expected_ocaml_version = "5.4.1"

let assert_stock_ocaml () =
  if String.( <> ) Sys.ocaml_version expected_ocaml_version
  then
    failwithf
      "expected stock OCaml compiler %s, got %s. Recreate the switch with: just \
       ensure-stock-ocaml-switch"
      expected_ocaml_version
      Sys.ocaml_version
      ()
;;
