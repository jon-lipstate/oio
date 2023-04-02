package set
Nil_Struct :: struct {}
Set :: struct($T: typeid) {
	m: map[T]struct {},
}
init :: #force_inline proc($T: typeid, allocator := context.allocator) -> Set(T) {
	set := Set(T){}
	set.m = make_map(map[T]struct {}, 16, allocator)
	return set
}

destroy :: #force_inline proc(set: ^Set($T)) {
	delete(set.m)
}
contains :: #force_inline proc(set: ^Set($T), item: T) -> bool {
	return item in set.m
}
add :: #force_inline proc(set: ^Set($T), item: T, overwrite: bool = false) -> (ok: bool) {
	if item in set.m && !overwrite {return false} else {
		set.m[item] = {}
		return true
	}
}
remove :: #force_inline proc(set: ^Set($T), item: T) -> (ok: bool) {
	if item not_in set.m {return false} else {
		delete_key(set.m, item)
		return true
	}
}
is_empty :: #force_inline proc(set: ^Set($T)) -> bool {
	return len(set.m) == 0
}
