type event =
  { mutable at_ms : float
  ; mutable token : int
  ; mutable kind : int
  ; mutable gen : int
  }

type t =
  { mutable at_ms : float array
  ; mutable token : int array
  ; mutable kind : int array
  ; mutable gen : int array
  ; mutable len : int
  }

let create_event () = { at_ms = 0.0; token = 0; kind = 0; gen = 0 }

let create capacity =
  if capacity <= 0 then invalid_arg "Timer_heap.create";
  { at_ms = Array.make capacity infinity
  ; token = Array.make capacity 0
  ; kind = Array.make capacity 0
  ; gen = Array.make capacity 0
  ; len = 0
  }
;;

let length t = t.len
let peek_at_ms t = if t.len = 0 then None else Some t.at_ms.(0)

let less (t : t) i j =
  t.at_ms.(i) < t.at_ms.(j)
  || (t.at_ms.(i) = t.at_ms.(j)
      && (t.token.(i) < t.token.(j)
          || (t.token.(i) = t.token.(j)
              && (t.kind.(i) < t.kind.(j)
                  || (t.kind.(i) = t.kind.(j) && t.gen.(i) < t.gen.(j))))))
;;

let set (t : t) i ~at_ms ~token ~kind ~gen =
  t.at_ms.(i) <- at_ms;
  t.token.(i) <- token;
  t.kind.(i) <- kind;
  t.gen.(i) <- gen
;;

let copy (t : t) ~src ~dst =
  t.at_ms.(dst) <- t.at_ms.(src);
  t.token.(dst) <- t.token.(src);
  t.kind.(dst) <- t.kind.(src);
  t.gen.(dst) <- t.gen.(src)
;;

let swap (t : t) i j =
  let at_ms = t.at_ms.(i) in
  let token = t.token.(i) in
  let kind = t.kind.(i) in
  let gen = t.gen.(i) in
  copy t ~src:j ~dst:i;
  set t j ~at_ms ~token ~kind ~gen
;;

let grow (t : t) =
  let old_len = Array.length t.at_ms in
  let next_len = old_len * 2 in
  let next_at_ms = Array.make next_len infinity in
  let next_token = Array.make next_len 0 in
  let next_kind = Array.make next_len 0 in
  let next_gen = Array.make next_len 0 in
  Array.blit t.at_ms 0 next_at_ms 0 t.len;
  Array.blit t.token 0 next_token 0 t.len;
  Array.blit t.kind 0 next_kind 0 t.len;
  Array.blit t.gen 0 next_gen 0 t.len;
  t.at_ms <- next_at_ms;
  t.token <- next_token;
  t.kind <- next_kind;
  t.gen <- next_gen
;;

let push (t : t) ~at_ms ~token ~kind ~gen =
  if t.len = Array.length t.at_ms then grow t;
  let i = ref t.len in
  set t !i ~at_ms ~token ~kind ~gen;
  t.len <- t.len + 1;
  while !i > 0 do
    let parent = (!i - 1) / 2 in
    if less t !i parent
    then (
      swap t !i parent;
      i := parent)
    else i := 0
  done
;;

let pop_into (t : t) (event : event) =
  if t.len = 0
  then false
  else (
    event.at_ms <- t.at_ms.(0);
    event.token <- t.token.(0);
    event.kind <- t.kind.(0);
    event.gen <- t.gen.(0);
    t.len <- t.len - 1;
    if t.len > 0 then copy t ~src:t.len ~dst:0;
    let i = ref 0 in
    let continue = ref true in
    while !continue do
      let left = (!i * 2) + 1 in
      let right = left + 1 in
      let smallest = ref !i in
      if left < t.len && less t left !smallest then smallest := left;
      if right < t.len && less t right !smallest then smallest := right;
      if !smallest <> !i
      then (
        swap t !i !smallest;
        i := !smallest)
      else continue := false
    done;
    true)
;;
