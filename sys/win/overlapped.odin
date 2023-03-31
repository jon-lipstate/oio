package sys_win

Callback :: proc(entry: ^OVERLAPPED_ENTRY, events: ^[dynamic]Event)

Overlapped :: struct {
	inner:    ^OVERLAPPED,
	callback: Callback,
}

new_overlapped :: proc(cb: Callback) -> Overlapped {
	return Overlapped{inner = nil, callback = cb}
}
