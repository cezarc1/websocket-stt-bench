open! Core

let h0_init = 0x67452301l
let h1_init = 0xEFCDAB89l
let h2_init = 0x98BADCFEl
let h3_init = 0x10325476l
let h4_init = 0xC3D2E1F0l

let rotl32 x n =
  Int32.bit_or (Int32.shift_left x n) (Int32.shift_right_logical x (32 - n))
;;

let pad_message s =
  let len = String.length s in
  let bit_len = Int64.of_int (len * 8) in
  let pad_len =
    let m = (len + 1) mod 64 in
    if m <= 56 then 56 - m else 56 + 64 - m
  in
  let total = len + 1 + pad_len + 8 in
  let buf = Bytes.create total in
  for i = 0 to len - 1 do
    Bytes.set buf i s.[i]
  done;
  Bytes.set buf len '\x80';
  for i = len + 1 to len + pad_len do
    Bytes.set buf i '\x00'
  done;
  for i = 0 to 7 do
    let shift = 8 * (7 - i) in
    let byte =
      Int64.shift_right_logical bit_len shift |> Int64.bit_and 0xFFL |> Int64.to_int_exn
    in
    Bytes.set buf (len + 1 + pad_len + i) (Char.of_int_exn byte)
  done;
  Bytes.to_string buf
;;

let read_be32 s pos =
  let b0 = Int32.of_int_exn (Char.to_int s.[pos]) in
  let b1 = Int32.of_int_exn (Char.to_int s.[pos + 1]) in
  let b2 = Int32.of_int_exn (Char.to_int s.[pos + 2]) in
  let b3 = Int32.of_int_exn (Char.to_int s.[pos + 3]) in
  Int32.bit_or
    (Int32.bit_or (Int32.shift_left b0 24) (Int32.shift_left b1 16))
    (Int32.bit_or (Int32.shift_left b2 8) b3)
;;

let write_be32_bytes buf pos x =
  let byte k =
    Int32.shift_right_logical x (8 * k)
    |> Int32.bit_and 0xFFl
    |> Int32.to_int_exn
    |> Char.of_int_exn
  in
  Bytes.set buf pos (byte 3);
  Bytes.set buf (pos + 1) (byte 2);
  Bytes.set buf (pos + 2) (byte 1);
  Bytes.set buf (pos + 3) (byte 0)
;;

let process_block padded ~block_offset (h0, h1, h2, h3, h4) =
  let w = Array.create ~len:80 0l in
  for i = 0 to 15 do
    w.(i) <- read_be32 padded (block_offset + (i * 4))
  done;
  for i = 16 to 79 do
    w.(i)
    <- rotl32
         (Int32.bit_xor
            (Int32.bit_xor w.(i - 3) w.(i - 8))
            (Int32.bit_xor w.(i - 14) w.(i - 16)))
         1
  done;
  let a = ref h0
  and b = ref h1
  and c = ref h2
  and d = ref h3
  and e = ref h4 in
  for i = 0 to 79 do
    let f, k =
      if i < 20
      then
        ( Int32.bit_or (Int32.bit_and !b !c) (Int32.bit_and (Int32.bit_not !b) !d)
        , 0x5A827999l )
      else if i < 40
      then Int32.bit_xor !b (Int32.bit_xor !c !d), 0x6ED9EBA1l
      else if i < 60
      then
        ( Int32.bit_or
            (Int32.bit_or (Int32.bit_and !b !c) (Int32.bit_and !b !d))
            (Int32.bit_and !c !d)
        , 0x8F1BBCDCl )
      else Int32.bit_xor !b (Int32.bit_xor !c !d), 0xCA62C1D6l
    in
    let temp =
      Int32.( + ) (Int32.( + ) (Int32.( + ) (rotl32 !a 5) f) (Int32.( + ) !e k)) w.(i)
    in
    e := !d;
    d := !c;
    c := rotl32 !b 30;
    b := !a;
    a := temp
  done;
  ( Int32.( + ) h0 !a
  , Int32.( + ) h1 !b
  , Int32.( + ) h2 !c
  , Int32.( + ) h3 !d
  , Int32.( + ) h4 !e )
;;

let digest_string s =
  let padded = pad_message s in
  let block_count = String.length padded / 64 in
  let h = ref (h0_init, h1_init, h2_init, h3_init, h4_init) in
  for block = 0 to block_count - 1 do
    h := process_block padded ~block_offset:(block * 64) !h
  done;
  let h0, h1, h2, h3, h4 = !h in
  let out = Bytes.create 20 in
  write_be32_bytes out 0 h0;
  write_be32_bytes out 4 h1;
  write_be32_bytes out 8 h2;
  write_be32_bytes out 12 h3;
  write_be32_bytes out 16 h4;
  Bytes.to_string out
;;
