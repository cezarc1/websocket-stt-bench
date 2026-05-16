open! Core

let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let encode s =
  let len = String.length s in
  let out_len = (len + 2) / 3 * 4 in
  let buf = Bytes.create out_len in
  let i = ref 0
  and o = ref 0 in
  while !i + 3 <= len do
    let b0 = Char.to_int s.[!i]
    and b1 = Char.to_int s.[!i + 1]
    and b2 = Char.to_int s.[!i + 2] in
    Bytes.set buf !o alphabet.[b0 lsr 2];
    Bytes.set buf (!o + 1) alphabet.[((b0 land 0x3) lsl 4) lor (b1 lsr 4)];
    Bytes.set buf (!o + 2) alphabet.[((b1 land 0xF) lsl 2) lor (b2 lsr 6)];
    Bytes.set buf (!o + 3) alphabet.[b2 land 0x3F];
    i := !i + 3;
    o := !o + 4
  done;
  let remaining = len - !i in
  if remaining = 1
  then (
    let b0 = Char.to_int s.[!i] in
    Bytes.set buf !o alphabet.[b0 lsr 2];
    Bytes.set buf (!o + 1) alphabet.[(b0 land 0x3) lsl 4];
    Bytes.set buf (!o + 2) '=';
    Bytes.set buf (!o + 3) '=')
  else if remaining = 2
  then (
    let b0 = Char.to_int s.[!i] in
    let b1 = Char.to_int s.[!i + 1] in
    Bytes.set buf !o alphabet.[b0 lsr 2];
    Bytes.set buf (!o + 1) alphabet.[((b0 land 0x3) lsl 4) lor (b1 lsr 4)];
    Bytes.set buf (!o + 2) alphabet.[(b1 land 0xF) lsl 2];
    Bytes.set buf (!o + 3) '=');
  Bytes.to_string buf
;;
