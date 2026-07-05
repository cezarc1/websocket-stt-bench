let post_prefix = "POST /infer HTTP/1.1\r\nHost: "
let port_prefix = ":"
let cpu_passes_prefix = "\r\nx-cpu-passes: "
let content_type_prefix = "\r\nContent-Type: application/octet-stream\r\nContent-Length: "
let suffix = "\r\nConnection: keep-alive\r\n\r\n"

let decimal_len n =
  let rec loop n digits = if n < 10 then digits else loop (n / 10) (digits + 1) in
  loop (max 0 n) 1
;;

let infer_header_len ~host ~port ~cpu_passes ~body_len =
  String.length post_prefix
  + String.length host
  + String.length port_prefix
  + decimal_len port
  + String.length cpu_passes_prefix
  + decimal_len cpu_passes
  + String.length content_type_prefix
  + decimal_len body_len
  + String.length suffix
;;

let write_string out pos s =
  let len = String.length s in
  Bytes.blit_string s 0 out pos len;
  pos + len
;;

let write_decimal out pos n =
  let n = max 0 n in
  let len = decimal_len n in
  let rec loop value i =
    let digit = value mod 10 in
    Bytes.set out (pos + i) (Char.chr (Char.code '0' + digit));
    if i > 0 then loop (value / 10) (i - 1)
  in
  loop n (len - 1);
  pos + len
;;

let write_infer_header ~host ~port ~cpu_passes ~body_len out pos =
  let start = pos in
  let pos = write_string out pos post_prefix in
  let pos = write_string out pos host in
  let pos = write_string out pos port_prefix in
  let pos = write_decimal out pos port in
  let pos = write_string out pos cpu_passes_prefix in
  let pos = write_decimal out pos cpu_passes in
  let pos = write_string out pos content_type_prefix in
  let pos = write_decimal out pos body_len in
  let pos = write_string out pos suffix in
  pos - start
;;
