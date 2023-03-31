package oio
import "core:time"
//
when ODIN_OS == .Windows {
	import os "./sys/win"
}
//
Registry :: struct {
	selector: os.Selector,
}
Poll :: struct {
	registry: Registry,
}
register :: proc(r: ^Registry, src: ^EventSource, t: Token, interests: Interests, allocator := context.allocator) -> (ok: bool) {
	// pub fn register<S>(&self, source: &mut S, token: Token, interests: Interest) -> io::Result<()>
	// where S: event::Source + ?Sized,
	// { source.register(self, token, interests)  }
	os.register(&r.selector, os.SOCKET(src), t, interests, allocator)
	return true
}
deregister :: proc(r: ^Registry, t: Token, interests: Interests) -> (ok: bool) {
	// pub fn deregister<S>(&self, source: &mut S) -> io::Result<()>
	// where S: event::Source + ?Sized,
	// {source.deregister(self) }
	not_implemented(#procedure)
}
// Internal check to ensure only a single `Waker` is active per [`Poll`]instance.
register_waker :: proc(r: ^Registry) -> bool {

	not_implemented(#procedure)
}
make_poll :: proc(allocator := context.allocator) -> (poll: Poll, ok: bool) {
	// sys::Selector::new().map(|selector| Poll {
	// 	registry: Registry { selector },
	// })
	p := Poll{}
	p.registry.selector = os.new_selector(allocator) // todo:alloc error?
	return p, true
}
poll :: proc(p: ^Poll, events: ^Events, timeout_ms: time.Duration) {
	// pub fn poll(&mut self, events: &mut Events, timeout: Option<Duration>) -> io::Result<()> {
	//     self.registry.selector.select(events.sys(), timeout)
	// }
	s := &p.registry.selector
	os.select(s, &events.inner, u32(timeout_ms))
}
