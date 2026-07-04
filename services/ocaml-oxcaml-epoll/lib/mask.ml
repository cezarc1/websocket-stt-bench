let copy_unmasked_640 src ~payload_pos ~mask_pos dst ~dst_pos =
  let m0 = Char.code (Bytes.get src mask_pos) in
  let m1 = Char.code (Bytes.get src (mask_pos + 1)) in
  let m2 = Char.code (Bytes.get src (mask_pos + 2)) in
  let m3 = Char.code (Bytes.get src (mask_pos + 3)) in
  let rec loop i =
    if i < Protocol.frame_bytes
    then (
      let src_pos = payload_pos + i in
      let dst_pos = dst_pos + i in
      Bytes.set dst dst_pos (Char.chr (Char.code (Bytes.get src src_pos) lxor m0));
      Bytes.set
        dst
        (dst_pos + 1)
        (Char.chr (Char.code (Bytes.get src (src_pos + 1)) lxor m1));
      Bytes.set
        dst
        (dst_pos + 2)
        (Char.chr (Char.code (Bytes.get src (src_pos + 2)) lxor m2));
      Bytes.set
        dst
        (dst_pos + 3)
        (Char.chr (Char.code (Bytes.get src (src_pos + 3)) lxor m3));
      loop (i + 4))
  in
  loop 0
;;
