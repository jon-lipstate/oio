package oio

import "core:fmt"

invalid_code_path :: proc(p: string = "") {
	if true {fmt.panicf("Invalid Code Path - %v", p)}
}
unreachable :: proc(p: string = "") {
	if true {fmt.panicf("Unreachable Code Path - %v", p)}
}
not_implemented :: proc(p: string = "") -> ! {
	fmt.panicf("Not Implemented - %v", p)
}
