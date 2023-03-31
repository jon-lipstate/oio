package events

EventSource :: struct #raw_union {
	socket:   uint,
	fdHandle: uint,
}
