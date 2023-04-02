package set
Set :: struct($T: typeid) {
	m: map[T]struct {},
}
// Allocates interior `map`
init :: #force_inline proc($T: typeid, allocator := context.allocator) -> Set(T) {
	set := Set(T){}
	set.m = make_map(map[T]struct {}, 16, allocator)
	return set
}
// Deallocates interior `map`
destroy :: #force_inline proc(set: ^Set($T)) {
	delete(set.m)
}
contains :: #force_inline proc(set: ^Set($T), item: T) -> bool {
	return item in set.m
}
// `if item in set` -> `false`
add :: #force_inline proc(set: ^Set($T), item: T) -> (ok: bool) {
	if item in set.m {return false} else {
		set.m[item] = {}
		return true
	}
}
// `if item not_in set` -> `false`
remove :: #force_inline proc(set: ^Set($T), item: T) -> (ok: bool) {
	if item not_in set.m {return false} else {
		delete_key(set.m, item)
		return true
	}
}
is_empty :: #force_inline proc(set: ^Set($T)) -> bool {
	return len(set.m) == 0
}
