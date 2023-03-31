package sys_win
import "core:fmt"
import "core:sync"
import "core:math/bits"

NEXT_SELECTOR_TOKEN: Token = 1
get_next_selector_token :: proc() -> Token {
	return sync.atomic_add(&NEXT_SELECTOR_TOKEN, 2)
}
AtomicBool :: distinct bool

AfdGroup :: struct {
	port:      ^CompletionPort, // Arc<>
	afd_group: [dynamic]Afd, //Mutex<Vec<Arc<Afd>>>
	lock:      sync.Mutex,
}
Selector :: struct {
	id:        Token,
	inner:     SelectorInner, // Arc<>
	has_waker: AtomicBool,
}
SelectorInner :: struct {
	port:         CompletionPort, // Arc<>
	update_queue: [dynamic]^SockState, //Mutex<VecDeque<Pin<Arc<Mutex<SockState>>>>>,
	queue_lock:   sync.Mutex,
	afd_group:    AfdGroup,
	is_polling:   AtomicBool,
}

new_selector :: proc(allocator := context.allocator) -> Selector {
	s := Selector {
		id        = get_next_selector_token(),
		inner     = new_selector_inner(allocator),
		has_waker = false,
	}
	return s
}

make_afd_group :: proc(port: ^CompletionPort, allocator := context.allocator) -> AfdGroup {
	group := AfdGroup{}
	group.port = port
	group.afd_group = make([dynamic]Afd, allocator)
	group.lock = sync.Mutex{}
	return group
}

release_unused_afd :: proc(grp: ^AfdGroup) {
	sync.mutex_lock(&grp.lock)
	defer sync.mutex_unlock(&grp.lock)
	for i := 0; i < len(grp.afd_group); i += 1 {
		afd := grp.afd_group[i]
		// Check if there is more than one reference to the Afd
		if afd.ref_count < 1 {
			// Arc::strong_count(g) > 1 -- why not >=
			ordered_remove(&grp.afd_group, i)
		}
	}
}
POLL_GROUP_MAX_GROUP_SIZE :: 32

acquire_afd :: proc(grp: ^AfdGroup) -> ^Afd {
	sync.mutex_lock(&grp.lock)
	defer sync.mutex_unlock(&grp.lock)
	if len(grp.afd_group) == 0 {
		afd, err := afd_from_cp(grp.port)
		assert(err == ERROR_NONE)
		append(&grp.afd_group, afd)
	} else {
		last_afd := grp.afd_group[len(grp.afd_group) - 1]
		if sync.atomic_load(&last_afd.ref_count) > POLL_GROUP_MAX_GROUP_SIZE {
			afd, err := afd_from_cp(grp.port)
			assert(err == ERROR_NONE)
			append(&grp.afd_group, afd)
		}
	}

	last_afd := &grp.afd_group[len(grp.afd_group) - 1]

	if last_afd.fd != nil {
		return last_afd
	} else {
		// error?
		return nil
	}
}
/////////////////////////////////////////////////////////////////
SockPollStatus :: enum {
	Idle,
	Pending,
	Cancelled,
}
//
SockState :: struct {
	iosb:           IO_STATUS_BLOCK,
	poll_info:      AfdPollInfo,
	afd:            ^Afd, // arc
	base_socket:    SOCKET,
	user_evts:      u32,
	pending_evts:   u32,
	user_data:      u64,
	poll_status:    SockPollStatus,
	delete_pending: bool,

	// last raw os error
	error:          Maybe(Errno),
}
update_sock_state :: proc(state: ^SockState) {
	assert(!state.delete_pending)
	state.error = nil
	switch state.poll_status {
	case .Cancelled:
	/* The poll operation has already been cancelled, we're still waiting for
                * it to return. For now, there's nothing that needs to be done. */
	case .Pending:
		// TODO: learn what this mask is doing:
		if state.user_evts & transmute(u32)KNOWN_EVENTS & ~state.pending_evts == 0 {
			/* All the events the user is interested in are already being monitored by
                * the pending poll operation. It might spuriously complete because of an
                * event that we're no longer interested in; when that happens we'll submit
                * a new poll operation with the updated event mask. */
		} else {
			/* A poll operation is already pending, but it's not monitoring for all the
                * events that the user is interested in. Therefore, cancel the pending
                * poll operation; when we receive it's completion package, a new poll
                * operation will be submitted with the correct event mask. */
			cancel_sock_state(state)
			state.error = 69 // TODO: mio passes an error here
		}
		return
	case .Idle:
		/* No poll operation is pending; start one. */
		state.poll_info.exclusive = 0
		state.poll_info.number_of_handles = 1
		state.poll_info.timeout = bits.I64_MAX
		state.poll_info.handles[0].handle = cast(HANDLE)state.base_socket
		state.poll_info.handles[0].status = 0
		state.poll_info.handles[0].events = state.user_evts | transmute(u32)(PollFlags{.POLL_LOCAL_CLOSE})
		overlapped_ptr := into_overlapped(state) // Increase the ref count as the memory will be used by the kernel.
		success := afd_poll(state.afd, &state.poll_info, &state.iosb, overlapped_ptr)
		if !success {
			err := (GetLastError())
			if err == ERROR_IO_PENDING {
				/* Overlapped poll operation in progress; this is expected. */
			} else {
				// Since the operation failed it means the kernel won't be using the memory any more.
				// drop(from_overlapped(overlapped_ptr as *mut _));
				//     if code == ERROR_INVALID_HANDLE as i32 {
				//         /* Socket closed; it'll be dropped. */
				//         self.mark_delete();
				//         return Ok(());
				//     } else {
				//         self.error = e.raw_os_error();
				//         return Err(e);
				//     }
			}
		}
		state.poll_status = .Pending
		state.pending_evts = state.user_evts
	}

}
cancel_sock_state :: proc(state: ^SockState) {
	assert(state.poll_status == .Pending)
	afd_cancel(state.afd, &state.iosb) // can error?
	state.poll_status = .Cancelled
	state.pending_evts = 0
}
// This is the function called from the overlapped using as Arc<Mutex<SockState>>. Watch out for reference counting.
feed_event_sock_state :: proc(state: ^SockState) -> Maybe(Event) {
	state.poll_status = .Idle
	state.pending_evts = 0
	afd_events: u32 = 0

	if state.delete_pending {
		return nil
	} else if state.iosb.Status == transmute(i32)STATUS_CANCELLED {
		/* The poll request was cancelled by CancelIoEx. */
	} else if state.iosb.Status < 0 {
		/* The overlapped request itself failed in an unexpected way. */
	} else if state.poll_info.number_of_handles < 1 {
		/* This poll operation succeeded but didn't report any socket events. */
	} else if (state.poll_info.handles[0].events & transmute(u32)PollFlags{PollFlag.POLL_LOCAL_CLOSE}) != 0 {
		/* The poll operation reported that the socket was closed. */
		mark_delete_sock_state(state)
		return nil
	} else {
		afd_events = state.poll_info.handles[0].events
	}
	afd_events &= state.user_evts
	return Event{data = cast(Token)state.user_data, flags = transmute(PollFlags)afd_events}
}
mark_delete_sock_state :: proc(state: ^SockState) {
	if state.delete_pending {return}
	if state.poll_status == .Pending {
		cancel_sock_state(state)
	}
	state.delete_pending = true
	// TODO: when to de-allocate??
}

new_sock_state :: proc(socket: SOCKET, afd: ^Afd, allocator := context.allocator) -> ^SockState {
	state := new(SockState, allocator)
	state^ = {}
	state.base_socket = socket
	state.poll_status = .Idle
	return state
}
// True if need to be added on update queue, false otherwise.
set_event_sock_state :: proc(state: ^SockState, ev: Event) -> bool {
	events := ev.flags + {PollFlag.POLL_CONNECT_FAIL, PollFlag.POLL_ABORT}
	state.user_evts = transmute(u32)events
	state.user_data = cast(u64)ev.data

	return transmute(u32)events & ~(transmute(u32)state.pending_evts) != 0
}
// TODO: rework sockstate to be #raw_union, this doesnt feel good as a blind ptr
into_overlapped :: proc(state: ^SockState) -> ^OVERLAPPED {
	return transmute(^OVERLAPPED)state
}
from_overlapped :: proc(ptr: ^OVERLAPPED) -> ^SockState {
	return transmute(^SockState)ptr
}

register :: proc(sel: ^Selector, socket: SOCKET, token: Token, interests: Interests, alllocator := context.allocator) -> InternalState {
	return register_inner(&sel.inner, socket, token, interests, alllocator)
}
reregister :: proc(sel: ^Selector, sock: ^SockState, token: Token, interests: Interests) {
	reregister_inner(&sel.inner, sock, token, interests)
}

new_selector_inner :: proc(allocator := context.allocator) -> SelectorInner {
	port, port_ok := new_completion_port(0)
	assert(port_ok == ERROR_NONE)
	si := SelectorInner{}
	si.port = port
	si.update_queue = make([dynamic]^SockState, allocator)
	si.afd_group = make_afd_group(&si.port, allocator)
	si.is_polling = false
	return si
}

select :: proc(sel: ^Selector, events: ^Events, timeout: u32 = INFINITE) {
	fmt.println("OS_SELECT")
	clear(&events.events)
	if timeout == INFINITE {
		for {
			length, errno := select2(&sel.inner, &events.status, &events.events, 0)
			if length == 0 {continue}
			break
		}
	} else {
		select2(&sel.inner, &events.status, &events.events, timeout)
	}
}
select2 :: proc(sel: ^SelectorInner, statuses: ^[]CompletionStatus, events: ^[dynamic]Event, timeout: u32) -> (uint, Errno) {
	fmt.println("OS_SELECT2")
	assert(!bool(sync.atomic_exchange(&sel.is_polling, true)))
	update_sockets_events(sel)
	iocp_events, err := get_many(&sel.port, statuses, timeout)
	sel.is_polling = false
	if err == ERROR_NONE {
		feed_events(sel, events, iocp_events)
		return 99999, ERROR_NONE // TODO:
	} else if err == Errno(WAIT_TIMEOUT) {
		return 0, 0
	} else {
		return 0, Errno(GetLastError())
	}
}

update_sockets_events :: proc(sel: ^SelectorInner) -> Errno {
	sync.mutex_lock(&sel.queue_lock)
	defer sync.mutex_unlock(&sel.queue_lock)
	for sock in &sel.update_queue {
		// sync.mutex_lock(&sock.lock)
		// defer sync.mutex_unlock(&sock.lock)
		fmt.println(#procedure, "not impl")
		if !sock.delete_pending {
			update_sock_state(sock)
		}
	}
	// remove all sock which do not have error, they have afd op pending
	for i := 0; i < len(sel.update_queue); i += 1 {
		if sel.update_queue[i].error == nil {
			ordered_remove(&sel.update_queue, i)
		}
	}

	release_unused_afd(&sel.afd_group)

	return ERROR_NONE
}

feed_events :: proc(sel: ^SelectorInner, events: ^[dynamic]Event, iocp_events: []CompletionStatus) -> uint {
	n: uint = 0
	sync.mutex_lock(&sel.queue_lock)
	defer sync.mutex_unlock(&sel.queue_lock)
	for i := 0; i < len(iocp_events); i += 1 {
		iocp_event := &iocp_events[i]
		overlapped := iocp_event.entry.lpOverlapped
		if overlapped == nil {
			append(events, from_completion_status(iocp_event))
			n += 1
			continue
		} else if iocp_event.entry.lpCompletionKey % 2 == 1 {
			// Handle is a named pipe. This could be extended to be any non-AFD event.
			length: uint = len(events)
			// TODO: I REALLY dont understand how this cast is supposed to be working?!
			callback := (transmute(^Overlapped)overlapped).callback
			callback(&iocp_event.entry, events)
			n += len(events) - length
			continue
		}
		sock := from_overlapped(overlapped)
		// TODO: LOCK SOCKET?? let mut sock_guard = sock_state.lock().unwrap();
		ev := feed_event_sock_state(sock)
		if ev != nil {
			append(events, ev.?)
			n += 1
		}
		if !sock.delete_pending {
			append(&sel.update_queue, sock)
		}
	}
	release_unused_afd(&sel.afd_group)
	return n
}

register_inner :: proc(
	sel: ^SelectorInner,
	socket: SOCKET,
	token: Token,
	interests: Interests,
	allocator := context.allocator,
) -> InternalState {
	flags := interests_to_afd_flags(interests)
	sock := new_sock_state(socket, acquire_afd(&sel.afd_group), allocator)
	ev := Event {
		flags = flags,
		data  = token,
	}
	set_event_sock_state(sock, ev)
	state := InternalState {
		selector   = sel, //new_clone(sel, allocator), // TODO: dont think i nedd clones
		token      = token,
		interests  = interests,
		sock_state = sock, // same clone stuff
	}
	queue_sock(sel, sock)
	update_sockets_events_if_polling(sel)
	return state
}

reregister_inner :: proc(sel: ^SelectorInner, sock: ^SockState, token: Token, interests: Interests) {
	ev := Event {
		flags = interests_to_afd_flags(interests),
		data  = token,
	}
	set_event_sock_state(sock, ev)
	// FIXME: a sock which has_error true should not be re-added to the update queue because it's already there.
	queue_sock(sel, sock)
	update_sockets_events_if_polling(sel)
}

update_sockets_events_if_polling :: proc(sel: ^SelectorInner) {
	// NOTE: I dont see why i need atomic ops here?
	// self.is_polling.load(Ordering::Acquire)
	if sel.is_polling {
		update_sockets_events(sel)
	}
}
//Pin<Arc<Mutex<SockState>>>
queue_sock :: proc(sel: ^SelectorInner, sock: ^SockState) {
	sync.mutex_lock(&sel.queue_lock)
	defer sync.mutex_unlock(&sel.queue_lock)
	append(&sel.update_queue, sock)
}

try_get_base_socket :: proc(socket: SOCKET, ioctl: u32) -> (sock: SOCKET, err: Errno) {
	base_socket: SOCKET
	bytes: u32 = 0
	if WSAIoctl(socket, ioctl, nil, 0, &base_socket, 0, &bytes, nil, nil) == SOCKET_ERROR {
		return SOCKET(INVALID_HANDLE_VALUE), Errno(WSAGetLastError())
	}
	return base_socket, ERROR_NONE
}

get_base_socket :: proc(raw_socket: SOCKET) -> (SOCKET, Errno) {
	base_sock: SOCKET
	err: Errno

	sio := []u32{u32(SIO_BASE_HANDLE), u32(SIO_BSP_HANDLE_SELECT), u32(SIO_BSP_HANDLE_POLL), u32(SIO_BSP_HANDLE)}

	for ioctl in sio {
		base_sock, err = try_get_base_socket(raw_socket, u32(SIO_BASE_HANDLE))
		if err == ERROR_NONE {return base_sock, err}
	}
	return SOCKET(INVALID_HANDLE_VALUE), Errno(GetLastError())
}

drop_selector_inner :: proc(sel: ^SelectorInner) {
	panic("not impl")
	// for {
	// 	// statuses := [1024]CompletionStatus{}
	// }
	// loop {
	// 	let events_num: usize;
	// 	let mut statuses: [CompletionStatus; 1024] = [CompletionStatus::zero(); 1024];

	// 	let result = self
	// 		.cp
	// 		.get_many(&mut statuses, Some(std::time::Duration::from_millis(0)));
	// 	match result {
	// 		Ok(iocp_events) => {
	// 			events_num = iocp_events.iter().len();
	// 			for iocp_event in iocp_events.iter() {
	// 				if iocp_event.overlapped().is_null() {
	// 					// Custom event
	// 				} else if iocp_event.token() % 2 == 1 {
	// 					// Named pipe, dispatch the event so it can release resources
	// 					let callback = unsafe {
	// 						(*(iocp_event.overlapped() as *mut super::Overlapped)).callback
	// 					};

	// 					callback(iocp_event.entry(), None);
	// 				} else {
	// 					// drain sock state to release memory of Arc reference
	// 					let _sock_state = from_overlapped(iocp_event.overlapped());
	// 				}
	// 			}
	// 		}

	// 		Err(_) => {
	// 			break;
	// 		}
	// 	}

	// 	if events_num == 0 {
	// 		// continue looping until all completion statuses have been drained
	// 		break;
	// 	}
	// }

	// self.afd_group.release_unused_afd();
}
