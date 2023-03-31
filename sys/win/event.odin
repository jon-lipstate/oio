package sys_win
// +build windows

Event :: struct {
	flags: PollFlags,
	data:  Token,
}
// set_readable :: proc(e: ^Event) {
// 	e.flags += {.POLL_RECEIVE}
// }
// set_writeable :: proc(e: ^Event) {
// 	e.flags += {.POLL_SEND}
// }
from_completion_status :: proc(cs: ^CompletionStatus) -> Event {
	c := cs.entry
	return Event{flags = transmute(PollFlags)c.dwNumberOfBytesTransferred, data = Token(c.lpCompletionKey)}
}
into_completion_status :: proc(ev: ^Event) -> CompletionStatus {
	return init_status(transmute(u32)ev.flags, u32(ev.data), nil)
}
/////////////////////////////////

Events :: struct {
	// Raw I/O event completions are filled in here by the call to `get_many`
	// on the completion port above. These are then processed to run callbacks
	// which figure out what to do after the event is done.
	status: []CompletionStatus,
	// Literal events returned by `get` to the upwards `EventLoop`. This file
	// doesn't really modify this (except for the waker), instead almost all
	// events are filled in by the `ReadinessQueue` from the `poll` module.
	events: [dynamic]Event,
}
make_events_with_capacity :: proc(cap: uint, allocator := context.allocator) -> Events {
	ev := Events{}
	ev.status = make([]CompletionStatus, cap, allocator)
	ev.events = make_dynamic_array_len_cap([dynamic]Event, 0, cap, allocator)
	return ev
}
is_empty :: proc(events: ^Events) -> bool {
	return len(events.events) == 0
}
clear_events :: proc(events: ^Events) {
	clear(&events.events)
	for i := 0; i < len(events.status); i += 1 {
		events.status[i] = {}
	}
}
