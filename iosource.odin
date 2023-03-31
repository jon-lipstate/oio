package oio
// Adapter for a [`RawFd`] or [`RawSocket`] providing an [`event::Source`]
// implementation.

// `IoSource` enables registering any FD or socket wrapper with [`Poll`].

// While only implementations for TCP, UDP, and UDS (Unix only) are provided,
// Mio supports registering any FD or socket that can be registered with the
// underlying OS selector. `IoSource` provides the necessary bridge.

import "core:fmt"
import "core:os"
// import "core:sync/atomic"
// import "core:os/winsock"

// when runtime.GOOS == "windows" {
//     import "core:os/windows/winsock"
// }
IoSourceState :: struct {}
IoSource :: struct {
	state: IoSourceState,
	inner: uint, // T sys.T
	// when ODIN_DEBUG {
	//     selector_id: SelectorId,
	// }
}

// create_io_source :: proc(io: T) -> IoSource(T) {
//     return IoSource {
//         state: create_io_source_state(),
//         inner: io,
//         when ODIN_DEBUG {
//             selector_id: create_selector_id(),
//         },
//     }
// }

// do_io :: proc(io_source: ^IoSource(T), f: proc(^T) -> os.IO_Result) -> os.IO_Result {
//     return io_source.state.do_io(f, io_source.inner)
// }

// when ODIN_OS == "windows" {
//     register :: proc(io_source: ^IoSource(T), registry: ^Registry, token: Token, interests: Interest) -> os.IO_Result {
//         when debug {
//             io_source.selector_id.associate(registry)?
//         }
//         return io_source.state.register(registry, token, interests, io_source.inner.as_raw_socket())
//     }

//     reregister :: proc(io_source: ^IoSource(T), registry: ^Registry, token: Token, interests: Interest) -> os.IO_Result {
//         when debug {
//             io_source.selector_id.check_association(registry)?
//         }
//         return io_source.state.reregister(registry, token, interests)
//     }

//     deregister :: proc(io_source: ^IoSource(T), _registry: ^Registry) -> os.IO_Result {
//         when debug {
//             io_source.selector_id.remove_association(_registry)?
//         }
//         return io_source.state.deregister()
//     }
// }

// when ODIN_DEBUG {
//     SelectorId :: struct {
//         id: atomic.Atomic_Usize,
//     }

//     create_selector_id :: proc() -> SelectorId {
//         return SelectorId {
//             id: atomic.new_atomic_usize(0),
//         }
//     }

//     associate :: proc(selector_id: ^SelectorId, registry: ^Registry) -> os.IO_Result {
//         registry_id := registry.selector().id()
//         previous_id := atomic.swap_usize(selector_id.id, registry_id, atomic.Ordering.Acq_Rel)

//         if previous_id == 0 {
//             return ok
//         } else {
//             return os.new_io_error(os.IO_ErrorKind.AlreadyExists, "I/O source already registered with a `Registry`")
//         }
//     }

//     check_association :: proc(selector_id: ^SelectorId, registry: ^Registry) -> os.IO_Result {
//         registry_id := registry.selector().id()
//         id := atomic.load_usize(selector_id.id, atomic.Ordering.Acquire)

//         if id == registry_id {
//             return ok
//         } else if id == 0 {
//             return os.new_io_error(os.IO_ErrorKind.NotFound, "I/O source not registered with `Registry`")
//         } else {
//             return os.new_io_error(os.IO_Error)
//         }
//     }
// }
