type t =
  { data : int array
  ; mutable len : int
  }

let create capacity =
  if capacity < 0 then invalid_arg "Int_stack.create";
  { data = Array.make capacity 0; len = 0 }
;;

let length t = t.len
let capacity t = Array.length t.data

let push t value =
  if t.len = Array.length t.data then invalid_arg "Int_stack.push";
  t.data.(t.len) <- value;
  t.len <- t.len + 1
;;

let pop t =
  if t.len = 0
  then None
  else (
    t.len <- t.len - 1;
    Some t.data.(t.len))
;;

let of_init length f =
  if length < 0 then invalid_arg "Int_stack.of_init";
  let t = create length in
  for i = length - 1 downto 0 do
    push t (f i)
  done;
  t
;;
