let h0_init = 0x67452301l
let h1_init = 0xefcdab89l
let h2_init = 0x98badcfel
let h3_init = 0x10325476l
let h4_init = 0xc3d2e1f0l
let rotl32 x n = Int32.logor (Int32.shift_left x n) (Int32.shift_right_logical x (32 - n))
let char_of_byte i = Char.chr (i land 0xff)

let pad_message s =
  let len = String.length s in
  let bit_len = Int64.of_int (len * 8) in
  let pad_len =
    let m = (len + 1) mod 64 in
    if m <= 56 then 56 - m else 56 + 64 - m
  in
  let total = len + 1 + pad_len + 8 in
  let buf = Bytes.make total '\x00' in
  Bytes.blit_string s 0 buf 0 len;
  Bytes.set buf len '\x80';
  for i = 0 to 7 do
    let shift = 8 * (7 - i) in
    let byte = Int64.(to_int (logand (shift_right_logical bit_len shift) 0xffL)) in
    Bytes.set buf (len + 1 + pad_len + i) (char_of_byte byte)
  done;
  Bytes.unsafe_to_string buf
;;

let read_be32 s pos =
  let b0 = Int32.of_int (Char.code s.[pos]) in
  let b1 = Int32.of_int (Char.code s.[pos + 1]) in
  let b2 = Int32.of_int (Char.code s.[pos + 2]) in
  let b3 = Int32.of_int (Char.code s.[pos + 3]) in
  Int32.logor
    (Int32.logor (Int32.shift_left b0 24) (Int32.shift_left b1 16))
    (Int32.logor (Int32.shift_left b2 8) b3)
;;

let write_be32 buf pos x =
  let byte shift = Int32.(to_int (logand (shift_right_logical x shift) 0xffl)) in
  Bytes.set buf pos (char_of_byte (byte 24));
  Bytes.set buf (pos + 1) (char_of_byte (byte 16));
  Bytes.set buf (pos + 2) (char_of_byte (byte 8));
  Bytes.set buf (pos + 3) (char_of_byte (byte 0))
;;

let process_block padded ~block_offset (h0, h1, h2, h3, h4) =
  let w = Array.make 80 0l in
  for i = 0 to 15 do
    w.(i) <- read_be32 padded (block_offset + (i * 4))
  done;
  for i = 16 to 79 do
    w.(i)
    <- rotl32
         (Int32.logxor
            (Int32.logxor w.(i - 3) w.(i - 8))
            (Int32.logxor w.(i - 14) w.(i - 16)))
         1
  done;
  let a = ref h0 in
  let b = ref h1 in
  let c = ref h2 in
  let d = ref h3 in
  let e = ref h4 in
  for i = 0 to 79 do
    let f, k =
      if i < 20
      then
        Int32.logor (Int32.logand !b !c) (Int32.logand (Int32.lognot !b) !d), 0x5a827999l
      else if i < 40
      then Int32.logxor !b (Int32.logxor !c !d), 0x6ed9eba1l
      else if i < 60
      then
        ( Int32.logor
            (Int32.logor (Int32.logand !b !c) (Int32.logand !b !d))
            (Int32.logand !c !d)
        , 0x8f1bbcdcl )
      else Int32.logxor !b (Int32.logxor !c !d), 0xca62c1d6l
    in
    let temp = Int32.add (Int32.add (Int32.add (rotl32 !a 5) f) (Int32.add !e k)) w.(i) in
    e := !d;
    d := !c;
    c := rotl32 !b 30;
    b := !a;
    a := temp
  done;
  Int32.add h0 !a, Int32.add h1 !b, Int32.add h2 !c, Int32.add h3 !d, Int32.add h4 !e
;;

let digest_string s =
  let padded = pad_message s in
  let h = ref (h0_init, h1_init, h2_init, h3_init, h4_init) in
  for block = 0 to (String.length padded / 64) - 1 do
    h := process_block padded ~block_offset:(block * 64) !h
  done;
  let h0, h1, h2, h3, h4 = !h in
  let out = Bytes.create 20 in
  write_be32 out 0 h0;
  write_be32 out 4 h1;
  write_be32 out 8 h2;
  write_be32 out 12 h3;
  write_be32 out 16 h4;
  Bytes.unsafe_to_string out
;;
