package events

import os "../sys/win"
Events :: struct {
	inner: os.Events,
}
make_events_with_capacity :: proc(cap: uint, allocator := context.allocator) -> Events {
	return Events{inner = os.make_events_with_capacity(cap, allocator)}
}
