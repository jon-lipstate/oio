package arc
import "core:sync"

Arc :: struct($T: typeid) {
	data:  T, /* Access via add_ref only */
	count: u32, /* Atomic */
}
init :: proc(arc: ^Arc($T)) {
	sync.atomic_store(arc.count, 1)
}

add_ref :: proc(arc: ^Arc($T)) -> (acquired: bool, data: T) {
	for {
		old := sync.atomic_load(arc.count)
		if old == 0 { 	// Destroyed
			return false, nil
		}
		v, ok := sync.atomic_compare_exchange_weak(arc.count, old, old + 1)
		if ok {
			return true, arc.data
		}
	}
}
// Destroys (does _not_ deallocate) if this was last reference
unref :: proc(arc: ^Arc($T)) {
	if arc.count == 1 {
		destroy(arc)
	} else {
		sync.atomic_add(arc.count, -1)
	}
}
destroy :: proc(arc: ^Arc($T)) {
	ok := false
	for !ok {
		_, ok = sync.atomic_compare_exchange_weak(arc.count, 1, 0)
		sync.cpu_relax()
	}
}
