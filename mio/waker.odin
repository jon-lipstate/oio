package oio

Waker :: struct {
	inner: uint, //sys::Waker,
}

make_waker :: proc(registry: ^Registry, token: Token) -> Waker { 	//-> io::Result<Waker>
	// registry.register_waker();
	// sys::Waker::new(registry.selector(), token).map(|inner| Waker { inner })
	not_implemented()
}
// Wake up the [`Poll`] associated with this `Waker`.
// [`Poll`]: struct.Poll.html
wake :: proc(w: ^Waker) {
	//pub fn wake(&self) -> io::Result<()> { self.inner.wake() }
}
