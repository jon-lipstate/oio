package mio_shared
//
Token :: distinct u32

Interests :: bit_set[Interest]
Interest :: enum u8 {
	Reader, //= 0b0_0001,
	Writer, //= 0b0_0010,
	AIO, //= 0b0_0100,
	LIO, //= 0b0_1000,
	Priority, //= 0b1_0000,
}
