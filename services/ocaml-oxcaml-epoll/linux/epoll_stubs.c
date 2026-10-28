#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>

CAMLprim value stt_epoll_create1(value flags_v) {
  int fd = epoll_create1(Int_val(flags_v));
  if (fd < 0) caml_uerror("epoll_create1", Nothing);
  return Val_int(fd);
}

CAMLprim value stt_epoll_ctl(value epfd_v, value op_v, value fd_v, value events_v, value token_v) {
  struct epoll_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.events = (uint32_t)Int_val(events_v);
  ev.data.u64 = (uint64_t)Int_val(token_v);
  int rc = epoll_ctl(Int_val(epfd_v), Int_val(op_v), Int_val(fd_v), &ev);
  if (rc < 0) {
    caml_uerror("epoll_ctl", Nothing);
  }
  return Val_unit;
}

static int stt_epoll_wait_raw(int epfd, int maxevents, int timeout, struct epoll_event *events) {
  int n;
  caml_release_runtime_system();
  do {
    n = epoll_wait(epfd, events, maxevents, timeout);
  } while (n < 0 && errno == EINTR);
  caml_acquire_runtime_system();
  return n;
}

CAMLprim value stt_epoll_wait(value epfd_v, value maxevents_v, value timeout_v) {
  CAMLparam3(epfd_v, maxevents_v, timeout_v);
  CAMLlocal1(out);
  int maxevents = Int_val(maxevents_v);
  if (maxevents <= 0) caml_invalid_argument("stt_epoll_wait: maxevents <= 0");
  struct epoll_event events[maxevents];
  int n = stt_epoll_wait_raw(Int_val(epfd_v), maxevents, Int_val(timeout_v), events);
  if (n < 0) caml_uerror("epoll_wait", Nothing);
  out = caml_alloc(n * 2, 0);
  for (int i = 0; i < n; i++) {
    Store_field(out, i * 2, Val_int((int)events[i].data.u64));
    Store_field(out, i * 2 + 1, Val_int((int)events[i].events));
  }
  CAMLreturn(out);
}

CAMLprim value stt_epoll_wait_into(value epfd_v, value maxevents_v, value timeout_v, value out_v) {
  CAMLparam4(epfd_v, maxevents_v, timeout_v, out_v);
  int maxevents = Int_val(maxevents_v);
  if (maxevents <= 0) caml_invalid_argument("stt_epoll_wait_into: maxevents <= 0");
  if (Wosize_val(out_v) < (mlsize_t)(maxevents * 2)) {
    caml_invalid_argument("stt_epoll_wait_into: output array too small");
  }
  struct epoll_event events[maxevents];
  int n = stt_epoll_wait_raw(Int_val(epfd_v), maxevents, Int_val(timeout_v), events);
  if (n < 0) caml_uerror("epoll_wait", Nothing);
  for (int i = 0; i < n; i++) {
    Store_field(out_v, i * 2, Val_int((int)events[i].data.u64));
    Store_field(out_v, i * 2 + 1, Val_int((int)events[i].events));
  }
  CAMLreturn(Val_int(n));
}

CAMLprim value stt_eventfd(value init_v, value flags_v) {
  CAMLparam2(init_v, flags_v);
  caml_release_runtime_system();
  int fd = eventfd((unsigned int)Int_val(init_v), Int_val(flags_v));
  caml_acquire_runtime_system();
  if (fd < 0) caml_uerror("eventfd", Nothing);
  CAMLreturn(Val_int(fd));
}

CAMLprim value stt_eventfd_write(value fd_v, value v_v) {
  CAMLparam2(fd_v, v_v);
  uint64_t v = (uint64_t)Int_val(v_v);
  ssize_t n;
  caml_release_runtime_system();
  do {
    n = write(Int_val(fd_v), &v, sizeof(v));
  } while (n < 0 && errno == EINTR);
  caml_acquire_runtime_system();
  if (n < 0) caml_uerror("eventfd_write", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value stt_eventfd_read(value fd_v) {
  CAMLparam1(fd_v);
  uint64_t v = 0;
  ssize_t n;
  caml_release_runtime_system();
  do {
    n = read(Int_val(fd_v), &v, sizeof(v));
  } while (n < 0 && errno == EINTR);
  caml_acquire_runtime_system();
  if (n < 0) caml_uerror("eventfd_read", Nothing);
  CAMLreturn(Val_int((int)v));
}
