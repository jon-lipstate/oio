package events

import "../shared"
Token :: shared.Token
import os "../sys/win"

Event :: struct {
	inner: os.Event,
}
is_readable :: proc(ev: ^Event) -> bool {
	return false
	// return ev.inner.flags
}
