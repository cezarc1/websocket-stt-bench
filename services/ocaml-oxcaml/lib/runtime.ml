open! Core

let expected_ocaml_version = "5.2.0+ox"

let assert_oxcaml () =
  if String.( <> ) Sys.ocaml_version expected_ocaml_version
  then
    failwithf
      "expected OxCaml compiler %s, got %s. Recreate the switch with: just \
       ensure-oxcaml-switch"
      expected_ocaml_version
      Sys.ocaml_version
      ()
;;
