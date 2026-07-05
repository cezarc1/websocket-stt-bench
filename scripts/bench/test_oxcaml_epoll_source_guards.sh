#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER="$ROOT/services/ocaml-oxcaml-epoll/linux/server.ml"
CSTUB="$ROOT/services/ocaml-oxcaml-epoll/linux/epoll_stubs.c"
PROTOCOL="$ROOT/services/ocaml-oxcaml-epoll/lib/protocol.ml"
MASK="$ROOT/services/ocaml-oxcaml-epoll/lib/mask.ml"
TIMER_HEAP="$ROOT/services/ocaml-oxcaml-epoll/lib/timer_heap.ml"

assert_contains() {
  local needle="$1"
  if ! grep -Fq "$needle" "$SERVER"; then
    echo "expected server.ml to contain: $needle" >&2
    exit 1
  fi
}

assert_absent() {
  local needle="$1"
  if grep -Fq "$needle" "$SERVER"; then
    echo "server.ml should not contain: $needle" >&2
    exit 1
  fi
}

assert_block_absent() {
  local start="$1"
  local needle="$2"
  if awk "/$start/,/;;/" "$SERVER" | grep -Fq "$needle"; then
    echo "server.ml block $start should not contain: $needle" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "expected $file to contain: $needle" >&2
    exit 1
  fi
}

assert_file_block_absent() {
  local file="$1"
  local start="$2"
  local stop="$3"
  local needle="$4"
  if awk "/$start/,/$stop/" "$file" | grep -Fq "$needle"; then
    echo "$file block $start should not contain: $needle" >&2
    exit 1
  fi
}

assert_file_block_contains() {
  local file="$1"
  local start="$2"
  local stop="$3"
  local needle="$4"
  if ! awk "/$start/,/$stop/" "$file" | grep -Fq "$needle"; then
    echo "$file block $start should contain: $needle" >&2
    exit 1
  fi
}

assert_contains "read_scratch : Bytes.t"
assert_contains "resp_scratch : Bytes.t"
assert_contains "read_scratch = Bytes.create 8192"
assert_contains "resp_scratch = Bytes.create 4096"
assert_contains "let enqueue_text"
assert_contains "out_add_ws_frame c.output Ws.Text payload"
assert_contains "let enqueue_partial"
assert_contains "let enqueue_error"
assert_contains "P.write_partial_json c.writer"
assert_contains "P.write_error_json c.writer"
assert_contains "Http_request.write_infer_header"
assert_contains "free_slots : Int_stack.t"
assert_contains "Int_stack.pop s.free_slots"
assert_contains "Int_stack.push s.free_slots slot.idx"
assert_contains "let consume_fast_binary_640_run"
assert_contains "Mask.copy_unmasked_640"
assert_contains "timers : Timer_heap.t"
assert_contains "timer_event : Timer_heap.event"
assert_contains "Timer_heap.push"
assert_contains "Timer_heap.pop_into s.timers s.timer_event"
assert_contains "P.infer_response_of_bytes slot.resp.data"
assert_contains "batch_oldest_seq"
assert_contains "batch_newest_seq"
assert_contains "batch_frames"
assert_file_contains "$PROTOCOL" "let infer_response_of_bytes_fast"
assert_file_contains "$PROTOCOL" "let infer_response_of_bytes"
assert_file_contains "$MASK" "let copy_unmasked_640"
assert_file_contains "$TIMER_HEAP" "let pop_into"
assert_file_block_absent "$CSTUB" "stt_epoll_ctl" "return Val_unit" "caml_release_runtime_system"
assert_file_block_absent "$CSTUB" "stt_epoll_ctl" "return Val_unit" "caml_acquire_runtime_system"
assert_file_block_contains "$CSTUB" "stt_epoll_wait_raw" "return n" "caml_release_runtime_system"
assert_file_block_contains "$CSTUB" "stt_epoll_wait_raw" "return n" "caml_acquire_runtime_system"
assert_absent "let tmp = Bytes.create 8192"
assert_absent "let tmp = Bytes.create 4096"
assert_absent "type timer ="
assert_absent "dummy_timer"
assert_absent "free_slots : int list"
assert_absent "meta_seq : int array"
assert_absent "meta_ms : float array"
assert_absent "mutable meta_len"
assert_absent "let grow_meta"
assert_absent "Array.make 64 0.0"
assert_absent "slot.idx :: s.free_slots"
assert_absent "let fast_binary_640"
assert_absent "P.infer_response_of_string body"
assert_absent "P.partial_to_string partial"
assert_absent "P.error_to_string err"
assert_absent "Ws.text (P.partial_to_string partial)"
assert_absent "Ws.text (P.error_to_string err)"
assert_block_absent "let build_request" "Printf.sprintf"
assert_block_absent "let parse_http_response" "Bytes.sub_string"
assert_block_absent "let record_pcm_masked" "i land 3"
