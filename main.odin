package oio
import "core:fmt"
import "core:net"
import "core:strings"
import "core:os"
import "core:c/libc"
import "core:thread"
import "core:time"
import "core:runtime"
import "core:io"
//
import "./shared"
Token :: shared.Token
Interests :: shared.Interests
Interest :: shared.Interest
//
import "./event"
Events :: event.Events
Event :: event.Event
EventSource :: event.EventSource
//
mainn :: proc() {
	addr := "127.0.0.1:3000"
	fmt.println("Making poll")
	p, ok := make_poll()
	events := event.make_events_with_capacity(128)
	ep, epok := net.parse_endpoint(addr)
	assert(epok)
	sock, serr := net.listen_tcp(ep, 5)
	defer net.close(sock)
	src := EventSource {
		socket = uint(sock),
	}
	SERVER :: Token(0)
	register(&p.registry, &src, SERVER, {.Reader})
	connections := map[Token]EventSource{}
	unique_token := Token(SERVER + 1)
	fmt.println("Server Running at:", addr)
	for {
		poll(&p, &events, time.Millisecond * 500)
		//
		for event in events.inner.events {
			switch Token(event.data) {
			case SERVER:
				fmt.println("SERVER EVENT")
			// net.accept_tcp()
			// accept_tcp(listener)
			// drop(connection)
			// errors: break on would_block
			case:
				// default
				// unreachable()
				fmt.println("Default case")
			}
		}
	}
	fmt.println("Exiting")
}
