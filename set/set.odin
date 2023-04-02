package set

Set :: struct($T: typeid) {
	m: map[T]struct {},
}
init :: #force_inline proc(set: Set($T), allocator := context.allocator) -> Set(T) {
	set := Set{make(map[T]struct {}, allocator)}
	return set
}
destroy :: #force_inline proc(set: ^Set($T)) {
	delete(set.m)
	set^ = nil
}
contains :: #force_inline proc(set: Set($T), item: T) -> bool {
	return item in set.m
}
add :: #force_inline proc(set: Set($T), item: T) -> (ok: bool) {
	if item in set.m {return false} else {
		set.m[item] = {}
		return true
	}
}
remove :: #force_inline proc(set: Set($T), item: T) -> (ok: bool) {
	if item not_in set.m {return false} else {
		delete_key(set.m, item)
		return true
	}
}
