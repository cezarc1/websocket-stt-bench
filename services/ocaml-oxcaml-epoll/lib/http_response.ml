type parsed =
  { status : int
  ; body_pos : int
  ; body_len : int
  ; has_content_length : bool
  }

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

let digit c =
  let code = Char.code c in
  if code >= Char.code '0' && code <= Char.code '9'
  then Some (code - Char.code '0')
  else None
;;

let parse_int b start stop =
  let rec loop i acc seen =
    if i >= stop
    then if seen then acc else 0
    else (
      match digit (Bytes.get b i) with
      | None -> if seen then acc else loop (i + 1) acc false
      | Some d -> loop (i + 1) ((acc * 10) + d) true)
  in
  loop start 0 false
;;

let status b head_end =
  let rec first_space i =
    if i >= head_end
    then head_end
    else if Bytes.get b i = ' '
    then i + 1
    else first_space (i + 1)
  in
  parse_int b (first_space 0) head_end
;;

let lower_code c =
  let code = Char.code c in
  if code >= Char.code 'A' && code <= Char.code 'Z' then code + 32 else code
;;

let matches_ascii_ci b pos stop s =
  let len = String.length s in
  pos + len <= stop
  &&
  let rec loop i =
    if i = len
    then true
    else if lower_code (Bytes.get b (pos + i)) = Char.code s.[i]
    then loop (i + 1)
    else false
  in
  loop 0
;;

let content_length b head_end =
  let rec line_start i =
    if i >= head_end
    then None
    else (
      let line_stop =
        match Bytes.index_from_opt b i '\n' with
        | Some stop when stop <= head_end -> stop
        | _ -> head_end
      in
      let stop =
        if line_stop > i && Bytes.get b (line_stop - 1) = '\r'
        then line_stop - 1
        else line_stop
      in
      if matches_ascii_ci b i stop "content-length"
      then (
        let colon = i + String.length "content-length" in
        if colon < stop && Bytes.get b colon = ':'
        then Some (parse_int b (colon + 1) stop)
        else line_start (line_stop + 1))
      else line_start (line_stop + 1))
  in
  line_start 0
;;

let parse b ~len =
  match find_double_crlf b len with
  | None -> None
  | Some head_end ->
    let body_pos = head_end + 4 in
    let content_length = content_length b head_end in
    let body_len =
      match content_length with
      | None -> 0
      | Some len -> len
    in
    if len < body_pos + body_len
    then None
    else
      Some
        { status = status b head_end
        ; body_pos
        ; body_len
        ; has_content_length = Option.is_some content_length
        }
;;
