package sys_win

InternalState :: struct {
	selector:   ^SelectorInner, //Arc<SelectorInner>
	token:      Token,
	interests:  Interests,
	sock_state: ^SockState, // Pin<Arc<Mutex<SockState>>>
}
drop_internal_state :: proc(is: ^InternalState) {
	mark_delete_sock_state(is.sock_state)
}

IoSourceState :: struct {
	inner: ^InternalState, // Option<Box<InternalState>>
}

// Perform I/O operation and re-register the socket if the operation would block
do_io :: proc(state: ^IoSourceState, f: proc(io: ^$T) -> (^T, Errno)) -> Errno {
	res, err := f(state.inner)
	if err != ERROR_NONE {
		if GetLastError() == ERROR_IO_PENDING {
			if state.inner != nil {
				i := state.inner
				reregister(i.selector, i.sock_state, i.token, i.interests)
			}
		}
	}
	return err
}
