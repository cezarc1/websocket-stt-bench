let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let encode s =
  let len = String.length s in
  let out_len = (len + 2) / 3 * 4 in
  let out = Bytes.create out_len in
  let i = ref 0 in
  let o = ref 0 in
  while !i + 3 <= len do
    let b0 = Char.code s.[!i] in
    let b1 = Char.code s.[!i + 1] in
    let b2 = Char.code s.[!i + 2] in
    Bytes.set out !o alphabet.[b0 lsr 2];
    Bytes.set out (!o + 1) alphabet.[((b0 land 0x03) lsl 4) lor (b1 lsr 4)];
    Bytes.set out (!o + 2) alphabet.[((b1 land 0x0f) lsl 2) lor (b2 lsr 6)];
    Bytes.set out (!o + 3) alphabet.[b2 land 0x3f];
    i := !i + 3;
    o := !o + 4
  done;
  (match len - !i with
   | 0 -> ()
   | 1 ->
     let b0 = Char.code s.[!i] in
     Bytes.set out !o alphabet.[b0 lsr 2];
     Bytes.set out (!o + 1) alphabet.[(b0 land 0x03) lsl 4];
     Bytes.set out (!o + 2) '=';
     Bytes.set out (!o + 3) '='
   | 2 ->
     let b0 = Char.code s.[!i] in
     let b1 = Char.code s.[!i + 1] in
     Bytes.set out !o alphabet.[b0 lsr 2];
     Bytes.set out (!o + 1) alphabet.[((b0 land 0x03) lsl 4) lor (b1 lsr 4)];
     Bytes.set out (!o + 2) alphabet.[(b1 land 0x0f) lsl 2];
     Bytes.set out (!o + 3) '='
   | _ -> assert false);
  Bytes.unsafe_to_string out
;;
