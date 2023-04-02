package oio
import "core:sys/windows"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:unicode/utf16"
import "core:container/queue"
import "core:math/bits"
import "./sys/win"

///
IOCP :: HANDLE
PORTS := map[IOCP]Port_State{}
/*
Initializes a `Port_State` and `IOCP`, registers into `PORTS`, then returns `IOCP`
*/
epoll_create :: proc(allocator := context.allocator) -> IOCP {
	// port_new()
	port_state := new(Port_State, allocator);assert(port_state != nil)
	port_state^ = {}
	iocp: IOCP = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 0)
	port_state.iocp = iocp
	port_state.update_queue = make(map[^Sock_State]int)
	port_state.deleted_queue = make(Queue(Sock_State))
	port_state.poll_group_queue = make(Queue(Poll_Group))
	//Register the port-state
	PORTS[iocp] = port_state

	return iocp
}

/*
The `epoll_ctl` function is responsible for managing the interest set of an epoll instance (represented by `iocp`).
It is used to add, modify, or remove file descriptors from the interest set associated with the epoll instance.
The interest set is the set of file descriptors that the epoll instance is monitoring for specific events.

~~ Register in Mio (Handle + Token)
*/
epoll_ctl :: proc(iocp: IOCP, op: CTL_Action, sock: SOCKET, ev: ^Epoll_Event) -> int {
	port_state := &PORTS[iocp];assert(port_state != nil)
	status := port_ctl(port_state, op, sock, ev)

	if status < 0 {
		//On Linux, EBADF takes priority over other errors. Mimic this behavior.
		err := err_check_handle(iocp)
		err = err_check_handle(cast(HANDLE)sock)
		return -1
	}
	return STATUS_SUCCESS
}

/*
`epoll_wait` is the actual polling proc. It waits for events to occur on the `afd`'s that have been added to the epoll instance using `epoll_ctl`.
When an event occurs, `epoll_wait` fills the events array with the triggered events and returns the number of events.
If no events occur within the specified timeout, the function returns 0.

~~ Select in Mio

*/
epoll_wait :: proc(iocp: IOCP, events: []Epoll_Event, timeout: int) -> int {
	assert(len(events) > 0)
	port_state := &PORTS[iocp]
	num_events := port_wait(port_state, transmute([^]Epoll_Event)&events[0], len(events), timeout)
	// todo: unref
	if num_events < 0 {
		// err: err_check_handle(ephnd)
		return -1
	}
	return num_events
}
/*
The epoll_close function is responsible for closing the epoll instance and cleaning up its associated resources.
*/
epoll_close :: proc(iocp: IOCP) -> Errno {
	port_state := &PORTS[iocp];assert(port_state != nil) // ERROR_INVALID_PARAMETER
	delete_key(&PORTS, iocp)
	err := port_close(port_state)
	err = port_delete(port_state)
	return err
}
///////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////

// Add, Modify or Delete a target for a port
port_ctl :: proc(port_state: ^Port_State, op: CTL_Action, sock: SOCKET, ev: ^Epoll_Event, allocator := context.allocator) -> Errno {
	sync.guard(&port_state.lock)
	switch op {
	case .Add:
		sock_state: ^Sock_State = sock_new(port_state, sock, allocator);assert(sock_state != nil)
		if sock_set_event(port_state, sock_state, ev) < 0 {
			sock_delete(port_state, sock_state)
			return -1
		}
		port_update_events_if_polling(port_state)
	case .Mod:
		sock_state: ^Sock_State = port_state.sockets[socket];assert(sock_state != nil)
		if sock_set_event(port_state, sock_state, ev) < 0 {
			return -1
		}
		port_update_events_if_polling(port_state)
	case .Del:
		sock_state: ^Sock_State = port_state.sockets[socket];assert(sock_state != nil)
		sock_delete(port_state, sock_state)
	case:
		SetLastError(ERROR_INVALID_PARAMETER)
		return ERRNO_MAPPINGS[ERROR_INVALID_PARAMETER]
	}
	return STATUS_SUCCESS
}
// SetLastError + ret nil on failure
sock_new :: proc(port_state: ^Port_State, socket: SOCKET, allocator := context.allocator) -> ^Sock_State {
	if socket == 0 || socket == INVALID_SOCKET {
		SetLastError(ERROR_INVALID_HANDLE)
		return nil
	}
	base_socket := get_base_socket(socket)
	if base_socket == INVALID_SOCKET {
		return nil
	}
	poll_group := poll_group_acquire(port_state)
	if poll_group == nil {
		return nil
	}
	sock_state, alloc_err := new(Sock_State, allocator)
	if sock_state == nil {
		poll_group_release(poll_group)
		return nil
	}
	sock_state^ = {}
	sock_state.base_socket = base_socket
	sock_state.poll_group = poll_group
	sock_state.parent = port_state

	// port_register_socket
	if !try_set(port_state.sockets, socket, sock_state) {
		SetLastError(ERROR_ALREADY_EXISTS)
		free(sock_state)
		return nil
	}
	return sock_state
}
// registers `event` into `sock_state`, then places `sock_state` into `update_queue`
sock_set_event :: proc(port_state: ^Port_State, sock_state: ^Sock_State, ev: ^Epoll_Event) -> int {
	events: u32 = ev.events | u32(EPOLL_ERR | EPOLL_HUP)

	sock_state.user_events = events
	sock_state.user_data = ev.data

	if (events & u32(EPOLL_KNOWN_EVENTS) & ~sock_state.pending_events) != 0 {
		port_request_socket_update(port_state, sock_state)
	}

	return STATUS_SUCCESS
}
// Cancels a pending poll, removes from `sockets`, deletes, or puts on `delete_queue` if not `.Idle`
sock_delete :: proc(port_state: ^Port_State, sock_state: ^Sock_State, force := false) -> int {
	if !sock_state.delete_pending {
		if sock_state.poll_status == .Pending {
			sock_cancel_poll(sock_state)
		}
		delete_key(&port_state.sockets, sock_state) // take out of the main list
		sock_state.delete_pending = true
	}
	if (force || sock_state.poll_status == .Idle) {
		delete_key(&port_state.sockets, sock_state)
		poll_group_release(sock_state.poll_group)
		assert(sock_state != nil)
		free(sock_state)
	} else {
		// May still be pending, catch it on the next pass
		queue.push_back(port_state.sock_deleted_queue, sock_state)
	}
	return STATUS_SUCCESS
}
// iterates all items in the queue, draining it. early returns if an update error occurs
port_update_events :: proc(port_state: ^Port_State) -> int {
	// Walk the queue, submitting new poll requests for every socket that needs it.
	for sock_state, _ in &port_state.update_queue {
		if sock_update(port_state, sock_state) < 0 {
			return -1
		}
		// `sock_update` removes the socket from the update queue.
	}
	return 0
}
// wraps update_events in `if active_poll_count > 0`
port_update_events_if_polling :: #force_inline proc(port_state: ^Port_State) {
	if port_state.active_poll_count > 0 {
		port_update_events(port_state)
	}
}
// Find the actual base socket, on failure returns INVALID_SOCKET + SetLastError
get_base_socket :: proc(socket: SOCKET) -> SOCKET {
	socket := socket
	base_socket := INVALID_SOCKET
	error: u32
	// Layered Service Providers (LSPs)
	/* Even though Microsoft documentation clearly states that LSPs should
     * never intercept the `SIO_BASE_HANDLE` ioctl [1], Komodia based LSPs do
     * so anyway, breaking it, with the apparent intention of preventing LSP
     * bypass [2]. Fortunately they don't handle `SIO_BSP_HANDLE_POLL`, which
     * will at least let us obtain the socket associated with the next winsock
     * protocol chain entry. If this succeeds, loop around and call
     * `SIO_BASE_HANDLE` again with the returned BSP socket, to make sure that
     * we unwrap all layers and retrieve the actual base socket.
     *  [1]
     * https://docs.microsoft.com/en-us/windows/win32/winsock/winsock-ioctls [2]
     * https://www.komodia.com/newwiki/index.php?title=Komodia%27s_Redirector_bug_fixes#Version_2.2.2.6
     */
	ioctl_get_bsp_socket :: proc(socket: SOCKET, ioctl: u32) -> SOCKET {
		bsp_socket: SOCKET
		bytes: u32
		if win.WSAIoctl(socket, ioctl, nil, 0, cast(^u8)&bsp_socket, size_of(bsp_socket), &bytes, nil, nil) != SOCKET_ERROR {
			return bsp_socket
		} else {
			return INVALID_SOCKET
		}
	}
	for {
		base_socket = ioctl_get_bsp_socket(socket, SIO_BASE_HANDLE)
		if base_socket != INVALID_SOCKET {return base_socket}
		error = GetLastError()
		if error == WSAENOTSOCK {
			SetLastError(error)
			return INVALID_SOCKET
		}

		base_socket = ioctl_get_bsp_socket(socket, SIO_BSP_HANDLE_POLL)
		if base_socket != INVALID_SOCKET && base_socket != socket {
			socket = base_socket
		} else {
			SetLastError(error)
			return INVALID_SOCKET
		}
	}
}
// Checks for InvalidHandle, SetLastError if so. GetHandleInformation also
err_check_handle :: proc(h: HANDLE) -> Errno {
	if h == INVALID_HANDLE_VALUE {
		SetLastError(os.EBADF)
		return os.EBADF
	}
	flags: u32
	if windows.GetHandleInformation(h, &flags) == false {
		err_map_win_error()
		return os.EINVAL
	}
	return 0
}
// Either gets existing poll_group, or makes a new one
poll_group_acquire :: proc(port_state: ^Port_State, allocator := context.allocator) -> ^Poll_Group {
	sync.guard(port_state.lock)
	pgq := &port_state.poll_group_queue
	// Check if there is an existing Poll_Group in the queue
	if len(pgq) != 0 {
		last_pg := queue.peek_back(pgq)
		// If the existing Poll_Group has not reached the maximum group size, return it
		if last_pg.group_size < POLL_GROUP_MAX_GROUP_SIZE {
			last_pg.group_size += 1
			return last_pg
		}
	}
	// Create a new Poll_Group and add it to the queue
	new_pg, alloc_err := new(Poll_Group, allocator);assert(alloc_err == .None)
	new_pg.port_state = port_state
	new_pg.group_size = 1
	queue.push_back(pgq, new_pg)
	// not sure i understand the move_to_start bit in wepoll

	return new_pg
}
// Decrements `poll_group.group_size`, moves `poll_group` to back of queue
poll_group_release :: proc(poll_group: ^Poll_Group) {
	pgq := &poll_group.port_state.poll_group_queue
	poll_group.group_size -= 1
	assert(poll_group.group_size < POLL_GROUP__MAX_GROUP_SIZE)

	queue_move_to_end(pgq, poll_group)
	// Poll groups are currently only freed when the epoll port is closed.
}
// early out, registers in `update_queue`
port_request_socket_update :: proc(port_state: ^Port_State, sock_state: ^Sock_State) {
	if sock_state in port_state.update_queue {return}
	port_state.update_queue[sock_state] = {}
}
// cancels the afd_poll, sets state to cancelled
sock_cancel_poll :: proc(sock_state: ^Sock_State) -> int {
	assert(sock_state.poll_status == .Pending)
	if afd_cancel_poll(sock_state.poll_group.afd_device_handle, &sock_state.io_status_block) < 0 {
		return -1
	}
	sock_state.poll_status = .Cancelled
	sock_state.pending_events = 0
	return STATUS_SUCCESS
}
// early out, removes from `update_queue` TODO: remove `port_state`, use parent ptr??
cancel_socket_update :: proc(port_state: ^Port_State, sock_state: ^Sock_State) {
	if sock_state not_in port_state.update_queue {return} else {delete_key(&port_state.update_queue, sock_state)}
}
// Calls NtCancelIoFileEx, early out if already done or cancelled
afd_cancel_poll :: proc(afd_device_handle: HANDLE, iosb: ^IO_STATUS_BLOCK) -> Errno {
	using win
	// If the poll operation has already completed or has been cancelled earlier, there's nothing left for us to do.
	if iosb.Status != STATUS_PENDING {
		return STATUS_SUCCESS
	}
	cancel_iosb: IO_STATUS_BLOCK
	cancel_status := NtCancelIoFileEx(afd_device_handle, iosb, &cancel_iosb)
	// NtCancelIoFileEx() may return STATUS_NOT_FOUND if the operation completed just before calling NtCancelIoFileEx().
	// This is not an error.
	if cancel_status == STATUS_SUCCESS || cancel_status == STATUS_NOT_FOUND {
		return STATUS_SUCCESS
	} else {
		return Errno(RtlNtStatusToDosError(cancel_status))
	}
}

///////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////
// map_win_error_to_errno :: proc(error: u32) -> Errno {
// 	err, has := ERRNO_MAPPINGS[error]
// 	if has {return err}
// 	return os.EINVAL
// }
// err_map_win_error :: proc() -> Errno {
// 	err := map_win_error_to_errno(GetLastError())
// 	SetLastError(err)
// 	return err
// }
// err_set_win_error :: proc(win_err: u32) -> Errno {
// 	err := map_win_error_to_errno(win_err)
// 	SetLastError(err)
// 	return err
// }

afd_create_device_handle :: proc(iocp: HANDLE) -> Result(HANDLE, Errno) {
	using win
	afd_device_handle: HANDLE
	iosb: IO_STATUS_BLOCK
	status: i32 // NTSTATUS

	// Call NtCreateFile
	status = NtCreateFile(
		&afd_device_handle,
		SYNCHRONIZE,
		&AFD_HELPER_ATTRIBUTES, // Global static str
		&iosb,
		nil,
		0,
		FILE_SHARE_READ | FILE_SHARE_WRITE,
		FILE_OPEN,
		0,
		nil,
		0,
	)
	if status != STATUS_SUCCESS {
		err: u32 = RtlNtStatusToDosError(status)
		return Errno(err)
	}
	// associate handle
	ih := CreateIoCompletionPort(afd_device_handle, iocp, 0, 0)
	if ih == nil {return -1}
	// set async mode
	if !SetFileCompletionNotificationModes(afd_device_handle, FILE_SKIP_SET_EVENT_ON_HANDLE) {
		windows.CloseHandle(afd_device_handle)
		return -1
	}
	return afd_device_handle
}

afd_poll :: proc(afd_device_handle: HANDLE, poll_info: ^AFD_POLL_INFO, iosb: ^IO_STATUS_BLOCK) -> Errno {
	using win
	status: i32 // NTSTATUS
	// Blocking operation is not supported.
	assert(iosb != nil)

	iosb.Status = win.STATUS_PENDING
	status = NtDeviceIoControlFile(
		afd_device_handle,
		nil,
		nil,
		iosb,
		iosb,
		IOCTL_AFD_POLL,
		poll_info,
		size_of(AFD_POLL_INFO),
		poll_info,
		size_of(AFD_POLL_INFO),
	)

	if status == STATUS_SUCCESS {
		return STATUS_SUCCESS
	} else if status == STATUS_PENDING {
		return Errno(ERROR_IO_PENDING)
	} else {
		return Errno(RtlNtStatusToDosError(status))
	}
}

//////////////////////////////////////////////

////

port_new :: proc(allocator := context.allocator) -> (state: ^Port_State, iocp: HANDLE) {
	using win
	port_state: ^Port_State = new(Port_State, allocator)
	assert(port_state != nil)
	// error : free(port_state)
	port_state^ = {} // do i need?

	iocp: HANDLE
	iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 0)
	assert(iocp != nil)

	port_state.iocp = iocp
	tree_init(&port_state.sock_tree)
	fmt.println("todo: queue_init")
	// queue_init(&port_state.sock_update_queue)
	// queue_init(&port_state.sock_deleted_queue)
	// queue_init(&port_state.poll_group_queue)
	ts_tree_node_init(&port_state.handle_tree_node)

	return port_state, iocp
}
// Drains & Deletes Queues, frees self
port_delete :: proc(port_state: ^Port_State) -> Errno {
	// At this point the IOCP port should have been closed.
	assert(port_state.iocp == nil)
	assert(len(port_state.update_queue) == 0)
	assert(port_state.active_poll_count == 0)

	for ss in &port_state.sock_deleted_queue {
		sock_delete(port_state, ss, true)
	}

	for pg in &port_state.poll_group_queue {
		poll_group_delete(pg)
	}

	delete(port_state.update_queue)
	delete(port_state.sock_deleted_queue)
	delete(port_state.poll_group_queue)
	free(port_state)

	return STATUS_SUCCESS
}

// Closes IOCP Handle, sets to nil in port_state
port_close :: proc(port_state: ^Port_State) -> Errno {
	sync.guard(&port_state.lock)
	ok := windows.CloseHandle(port_state.iocp)
	port_state.iocp = nil
	assert(ok == true)
	return STATUS_SUCCESS
}

poll_group__new :: proc(port_state: ^Port_State) -> ^Poll_Group {
	iocp := port_get_iocp(port_state)
	poll_group_queue := port_get_poll_group_queue(port_state)

	poll_group := alloc(Poll_Group, size_of(Poll_Group))
	if poll_group == nil {
		return_set_error(nil, ERROR_NOT_ENOUGH_MEMORY)
	}

	memset(poll_group, 0, size_of(Poll_Group))

	queue_node_init(&poll_group.queue_node)
	poll_group.port_state = port_state

	if afd_create_device_handle(iocp, &poll_group.afd_device_handle) < 0 {
		free(poll_group)
		return nil
	}

	queue_append(poll_group_queue, &poll_group.queue_node)

	return poll_group
}
// CloseHandle(afd), free(self)
poll_group_delete :: proc(poll_group: ^Poll_Group) {
	assert(poll_group.group_size == 0)
	CloseHandle(poll_group.afd_device_handle)
	free(poll_group)
}
// executes the poll with wait
port_wait :: proc(port_state: ^Port_State, events: ^Epoll_Event, maxevents: int, timeout: int) -> int {
	using win
	assert(maxevents > 0) //set_error(-1, ERROR_INVALID_PARAMETER)

	stack_iocp_events: [PORT_MAX_ON_STACK_COMPLETIONS]OVERLAPPED_ENTRY
	p_make: []OVERLAPPED_ENTRY = nil
	// actual pointer to be used:
	iocp_events: [^]OVERLAPPED_ENTRY

	// verify stack is large enough:
	if maxevents > PORT_MAX_ON_STACK_COMPLETIONS {
		p_make = make([]OVERLAPPED_ENTRY, maxevents) // todo: allocator, alloc_occured:bool
		iocp_events = &p_make[0]
	} else {
		iocp_events = &stack_iocp_events[0]
	}

	due: u64 = 0
	gqcs_timeout: u64
	result: int
	if timeout > 0 {
		due = GetTickCount64() + u64(timeout)
		gqcs_timeout = u64(timeout)
	} else if timeout == 0 {
		gqcs_timeout = 0
	} else {
		gqcs_timeout = INFINITE
	}

	if sync.guard(&port_state.lock) {
		for {
			now: u64

			result = port_poll(port_state, events, iocp_events, u32(maxevents), gqcs_timeout)

			if result != 0 {break}
			if timeout < 0 {continue}

			now = win.GetTickCount64()

			if now >= due {
				SetLastError(WAIT_TIMEOUT)
				break
			}

			gqcs_timeout = (due - now)
		}

		port_update_events_if_polling(port_state)
	}

	if iocp_events != &stack_iocp_events[0] {delete(p_make)}

	if result >= 0 {
		return result
	} else if GetLastError() == WAIT_TIMEOUT {
		return 0
	} else {
		return -1
	}
}
port_poll :: proc(
	port_state: ^Port_State,
	epoll_events: [^]Epoll_Event,
	iocp_events: [^]OVERLAPPED_ENTRY,
	maxevents: u32,
	timeout: u32 = INFINITE,
) -> int {
	using win
	completion_count: u32

	if port_update_events(port_state) < 0 {return -1}

	port_state.active_poll_count += 1
	sync.unlock(&port_state.lock)

	r := GetQueuedCompletionStatusEx(port_state.iocp, iocp_events, maxevents, &completion_count, timeout, false)

	sync.lock(&port_state.lock)
	port_state.active_poll_count -= 1

	if !r {return -1}

	return port_feed_events(port_state, epoll_events, iocp_events, completion_count)
}
// calls `sock_feed_event` on each iosb (Read Poll Results), returns #events
port_feed_events :: #force_inline proc(
	port_state: ^Port_State,
	epoll_events: [^]Epoll_Event,
	iocp_events: [^]OVERLAPPED_ENTRY,
	iocp_event_count: u32,
) -> int {
	epoll_event_count := 0
	for i in 0 ..< iocp_event_count {
		io_status_block := cast(^IO_STATUS_BLOCK)iocp_events[i].lpOverlapped
		ev := &epoll_events[epoll_event_count]

		epoll_event_count += sock_feed_event(port_state, io_status_block, ev)
	}
	return epoll_event_count
}
// Converts EPOLL_XX to AFD_POLL_XX Events
epoll_events_into_afd_events :: proc(epoll_events: u32) -> (afd_events: u32) {
	afd_events = AFD_POLL_LOCAL_CLOSE
	if (epoll_events & (EPOLL_IN | EPOLL_RDNORM)) {
		afd_events |= AFD_POLL_RECEIVE | AFD_POLL_ACCEPT
	}
	if (epoll_events & (EPOLL_PRI | EPOLL_RDBAND)) {
		afd_events |= AFD_POLL_RECEIVE_EXPEDITED
	}
	if (epoll_events & (EPOLL_OUT | EPOLL_WRNORM | EPOLL_WRBAND)) {
		afd_events |= AFD_POLL_SEND
	}
	if (epoll_events & (EPOLL_IN | EPOLL_RDNORM | EPOLL_RDHUP)) {
		afd_events |= AFD_POLL_DISCONNECT
	}
	if (epoll_events & EPOLL_HUP) {
		afd_events |= AFD_POLL_ABORT
	}
	if (epoll_events & EPOLL_ERR) {
		afd_events |= AFD_POLL_CONNECT_FAIL
	}
	return afd_events
}
// Converts AFD_POLL_XX to EPOLL_XX Events
afd_events_into_epoll_events :: proc(afd_events: u32) -> (epoll_events: u32) {
	epoll_events = 0
	if (afd_events & (AFD_POLL_RECEIVE | AFD_POLL_ACCEPT)) {
		epoll_events |= EPOLL_IN | EPOLL_RDNORM
	}
	if (afd_events & AFD_POLL_RECEIVE_EXPEDITED) {
		epoll_events |= EPOLL_PRI | EPOLL_RDBAND
	}
	if (afd_events & AFD_POLL_SEND) {
		epoll_events |= EPOLL_OUT | EPOLL_WRNORM | EPOLL_WRBAND
	}
	if (afd_events & AFD_POLL_DISCONNECT) {
		epoll_events |= EPOLL_IN | EPOLL_RDNORM | EPOLL_RDHUP
	}
	if (afd_events & AFD_POLL_ABORT) {
		epoll_events |= EPOLL_HUP
	}
	if (afd_events & AFD_POLL_CONNECT_FAIL) {
		epoll_events |= EPOLL_IN | EPOLL_OUT | EPOLL_ERR | EPOLL_RDNORM | EPOLL_WRNORM | EPOLL_RDHUP
	}
	return epoll_events
}
// Starts new `afd_polls`, de-registers from `update_queue`
sock_update :: proc(port_state: ^Port_State, sock_state: ^Sock_State) -> int {
	assert(!sock_state.delete_pending)
	if sock_state.poll_status == .Pending && sock_state.user_events & EPOLL_KNOWN_EVENTS & ~sock_state.pending_events == 0 {
		/* All the events the user is interested in are already being monitored by
        * the pending poll operation. It might spuriously complete because of an
        * event that we're no longer interested in; when that happens we'll submit
        * a new poll operation with the updated event mask. */
	} else if (sock_state.poll_status == .Pending) {
		/* A poll operation is already pending, but it's not monitoring for all the
        * events that the user is interested in. Therefore, cancel the pending
        * poll operation; when we receive it's completion package, a new poll
        * operation will be submitted with the correct event mask. */
		if (sock_cancel_poll(sock_state) < 0) {return -1}
	} else if (sock_state.poll_status == .Cancelled) {
		/* The poll operation has already been cancelled, we're still waiting for
        * it to return. For now, there's nothing that needs to be done. */
	} else if (sock_state.poll_status == .Idle) {
		/* No poll operation is pending; start one. */
		sock_state.poll_info.Exclusive = false
		sock_state.poll_info.NumberOfHandles = 1
		sock_state.poll_info.Timeout.QuadPart = bits.I64_MAX
		sock_state.poll_info.Handles[0].Handle = HANDLE(sock_state.base_socket)
		sock_state.poll_info.Handles[0].Status = 0
		sock_state.poll_info.Handles[0].Events = epoll_events_into_afd_events(sock_state.user_events)

		if (afd_poll(sock_state.poll_group.afd_device_handle, &sock_state.poll_info, &sock_state.io_status_block) < 0) {
			switch (GetLastError()) {
			case ERROR_IO_PENDING:
				/* Overlapped poll operation in progress; this is expected. */
				break
			case ERROR_INVALID_HANDLE:
				/* Socket closed; it'll be dropped from the epoll set. */
				return sock_delete(port_state, sock_state, false)
			case:
				/* Other errors are propagated to the caller. */
				return -1
			}
		}
		sock_state.poll_status = .Pending
		sock_state.pending_events = sock_state.user_events

	} else {
		unreachable(#procedure)
	}
	// de-register from `update_queue`
	cancel_socket_update(port_state, sock_state)
	return STATUS_SUCCESS
}
// Reads Events, Deletes, Re-Registers and or feeds afd-events
sock_feed_event :: proc(port_state: ^Port_State, io_status_block: ^IO_STATUS_BLOCK, ev: ^Epoll_Event) -> int {
	sock_state: ^Sock_State = transmute(^Sock_State)io_status_block // iosb is first member of sock_state
	poll_info := &sock_state.poll_info
	epoll_events: u32 = 0

	sock_state.poll_status = .Idle
	sock_state.pending_events = 0

	if sock_state.delete_pending {
		/* Socket has been deleted earlier and can now be freed. */
		return sock_delete(port_state, sock_state, false)
	} else if io_status_block.Status == STATUS_CANCELLED {
		/* The poll request was cancelled by CancelIoEx. */
	} else if io_status_block.Status < 0 {
		/* The overlapped request itself failed in an unexpected way. */
		epoll_events = EPOLL_ERR
	} else if poll_info.NumberOfHandles < 1 {
		/* This poll operation succeeded but didn't report any socket events. */
	} else if poll_info.Handles[0].Events & AFD_POLL_LOCAL_CLOSE != 0 {
		/* The poll operation reported that the socket was closed. */
		return sock_delete(port_state, sock_state, false)
	} else {
		/* Events related to our socket were reported. */
		epoll_events = afd_events_into_epoll_events(poll_info.Handles[0].Events)
	}
	// re-register for next iteration
	port_request_socket_update(port_state, sock_state)

	epoll_events &= sock_state.user_events

	if (epoll_events == 0) {
		return 0
	}

	if sock_state.user_events & EPOLL_ONESHOT != 0 {
		sock_state.user_events = 0
	}

	ev.data = sock_state.user_data
	ev.events = epoll_events
	return 1
}
