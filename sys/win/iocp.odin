package sys_win

CompletionPort :: struct {
	handle: HANDLE,
}

CompletionStatus :: struct {
	entry: OVERLAPPED_ENTRY,
}

// The number of threads given corresponds to the level of concurrency allowed for threads associated with this port.
new_completion_port :: proc(n_threads: u32) -> (port: CompletionPort, err: Errno) {
	handle := CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, n_threads)
	if handle == nil {
		err = Errno(GetLastError())
		return {}, err
	} else {
		port.handle = handle
		err = ERROR_NONE
		return port, err
	}
}

add_handle :: proc(port: ^CompletionPort, token: ^Token, afd: HANDLE) -> Errno {
	handle := CreateIoCompletionPort(afd, port.handle, cast(u32)token^, 0) // todo:fix token stuff
	if handle == nil {
		return Errno(GetLastError())
	}
	return ERROR_NONE
}
INFINITE :: 0xFFFFFFFF
get_many :: proc(port: ^CompletionPort, items: ^[]CompletionStatus, timeout_ms: u32 = INFINITE) -> ([]CompletionStatus, Errno) {
	removed: u32 = 0
	entries := transmute([^]OVERLAPPED_ENTRY)raw_data(items^)
	ret := GetQueuedCompletionStatusEx(port.handle, entries, u32(len(items)), &removed, timeout_ms, false)
	if ret == false {
		return nil, Errno(GetLastError())
	}
	return items[:removed], ERROR_NONE
}

post :: proc(port: ^CompletionPort, status: CompletionStatus) -> Errno {
	e := status.entry
	ret := PostQueuedCompletionStatus(port.handle, e.dwNumberOfBytesTransferred, e.lpCompletionKey, e.lpOverlapped)
	if ret == false {
		return Errno(GetLastError())
	}
	return ERROR_NONE
}

init_status :: proc(bytes: u32, token: u32, overlapped: ^Overlapped) -> CompletionStatus {
	cs := OVERLAPPED_ENTRY {
		dwNumberOfBytesTransferred = bytes,
		lpCompletionKey            = token,
		lpOverlapped               = overlapped.inner,
		Internal                   = 0,
	}
	return CompletionStatus{cs}
}

from_entry :: proc(entry: ^OVERLAPPED_ENTRY) -> ^CompletionStatus {
	return transmute(^CompletionStatus)entry
}
