(* [@zero_alloc]: called once per inbound 640-byte frame. A local recursive [loop] here
   captured the mask bytes and allocated an 88-byte closure per call; the [for] loop keeps
   the hot path allocation-free. *)
let[@zero_alloc] copy_unmasked_640 src ~payload_pos ~mask_pos dst ~dst_pos =
  let m0 = Char.code (Bytes.get src mask_pos) in
  let m1 = Char.code (Bytes.get src (mask_pos + 1)) in
  let m2 = Char.code (Bytes.get src (mask_pos + 2)) in
  let m3 = Char.code (Bytes.get src (mask_pos + 3)) in
  for k = 0 to (Protocol.frame_bytes / 4) - 1 do
    let i = k * 4 in
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
      (Char.chr (Char.code (Bytes.get src (src_pos + 3)) lxor m3))
  done
;;
