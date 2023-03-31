package sys_win
import "core:fmt"
import "core:sync"
import "core:sys/windows"

NEXT_AFD_TOKEN: Token = 0
get_next_afd_token :: proc() -> Token {
	return sync.atomic_add(&NEXT_AFD_TOKEN, 2)
}

IOCTL_AFD_POLL :: 0x00012024

Afd :: struct {
	fd:        HANDLE,
	ref_count: u32, // selector wants...?
}
AfdPollHandleInfo :: struct {
	handle: HANDLE,
	events: u32,
	status: NTSTATUS,
}
AfdPollInfo :: struct {
	timeout:           i64,
	// Can have only value 1.
	number_of_handles: u32,
	exclusive:         u32,
	handles:           [1]AfdPollHandleInfo,
}
afd_poll :: proc(afd: ^Afd, info: ^AfdPollInfo, iosb: ^IO_STATUS_BLOCK, overlapped: rawptr) -> bool {
	status := NtDeviceIoControlFile(
		afd.fd,
		nil,
		nil,
		overlapped,
		iosb,
		IOCTL_AFD_POLL,
		info,
		size_of(AfdPollInfo),
		info,
		size_of(AfdPollInfo),
	)

	if status == STATUS_PENDING {
		return false
	} else if status == STATUS_SUCCESS {
		return true
	} else {
		// Handle error cases
		return false
	}
}

afd_cancel :: proc(afd: ^Afd, iosb: ^IO_STATUS_BLOCK) {
	if iosb.Status != STATUS_PENDING {
		return
	}

	cancel_iosb: IO_STATUS_BLOCK = {}

	status := NtCancelIoFileEx(afd.fd, iosb, &cancel_iosb)

	if status == STATUS_SUCCESS || status == STATUS_NOT_FOUND {
		return
	} else {
		// Handle error cases
	}
}

READABLE_FLAGS :: PollFlags{.POLL_RECEIVE, .POLL_DISCONNECT, .POLL_ACCEPT, .POLL_ABORT, .POLL_CONNECT_FAIL}
READ_CLOSED_FLAGS :: PollFlags{.POLL_DISCONNECT, .POLL_ABORT, .POLL_CONNECT_FAIL}
WRITABLE_FLAGS :: PollFlags{.POLL_SEND, .POLL_ABORT, .POLL_CONNECT_FAIL}
WRITE_CLOSED_FLAGS :: PollFlags{.POLL_ABORT, .POLL_CONNECT_FAIL}
ERROR_FLAGS :: PollFlags{.POLL_CONNECT_FAIL}

interests_to_afd_flags :: proc(interests: Interests) -> PollFlags {
	flags: PollFlags
	if .Reader in interests {
		flags += READABLE_FLAGS
		flags += ERROR_FLAGS
	}
	if .Writer in interests {
		flags += WRITABLE_FLAGS
		flags += ERROR_FLAGS
	}
	return flags
}

PollFlags :: bit_set[PollFlag;u32]
// PollFlag :: enum {
// 	POLL_RECEIVE           = 0b0_0000_0001,
// 	POLL_RECEIVE_EXPEDITED = 0b0_0000_0010,
// 	POLL_SEND              = 0b0_0000_0100,
// 	POLL_DISCONNECT        = 0b0_0000_1000,
// 	POLL_ABORT             = 0b0_0001_0000,
// 	POLL_LOCAL_CLOSE       = 0b0_0010_0000,
// 	// // Not used as it indicated in each event where a connection is connected, not just the first time a connection is established.
// 	// // Also see https://github.com/piscisaureus/wepoll/commit/8b7b340610f88af3d83f40fb728e7b850b090ece.
// 	POLL_CONNECT           = 0b0_0100_0000,
// 	POLL_ACCEPT            = 0b0_1000_0000,
// 	POLL_CONNECT_FAIL      = 0b1_0000_0000,
// }

// Do NOT Reorder
PollFlag :: enum {
	POLL_RECEIVE,
	POLL_RECEIVE_EXPEDITED,
	POLL_SEND,
	POLL_DISCONNECT,
	POLL_ABORT,
	POLL_LOCAL_CLOSE,
	POLL_CONNECT,
	POLL_ACCEPT,
	POLL_CONNECT_FAIL,
}
KNOWN_EVENTS := PollFlags{
	.POLL_RECEIVE,
	.POLL_RECEIVE_EXPEDITED,
	.POLL_SEND,
	.POLL_DISCONNECT,
	.POLL_ABORT,
	.POLL_LOCAL_CLOSE,
	.POLL_ACCEPT,
	.POLL_CONNECT_FAIL,
}

// sAFD_OBJ_NAME := utf16.encode_string()

UNICODE_STRING :: struct {
	Length:        u16, // USHORT
	MaximumLength: u16, // USHORT
	Buffer:        ^u16, // PWSTR
}

AFD_HELPER_NAME: [15]u16 = {
	u16('\\'),
	u16('D'),
	u16('e'),
	u16('v'),
	u16('i'),
	u16('c'),
	u16('e'),
	u16('\\'),
	u16('A'),
	u16('f'),
	u16('d'),
	u16('\\'),
	u16('M'),
	u16('i'),
	u16('o'),
}
AFD_OBJ_NAME := UNICODE_STRING {
	Length        = u16(len(AFD_HELPER_NAME)) * size_of(u16),
	MaximumLength = len(AFD_HELPER_NAME) * size_of(u16),
	Buffer        = &AFD_HELPER_NAME[0],
}
AFD_HELPER_ATTRIBUTES := OBJECT_ATTRIBUTES {
	Length                   = size_of(OBJECT_ATTRIBUTES),
	RootDirectory            = nil,
	ObjectName               = &AFD_OBJ_NAME,
	Attributes               = 0,
	SecurityDescriptor       = nil,
	SecurityQualityOfService = nil,
}

afd_from_cp :: proc(cp: ^CompletionPort) -> (Afd, Errno) {
	afd_helper_handle: HANDLE = INVALID_HANDLE_VALUE
	iosb: IO_STATUS_BLOCK = {}

	status := NtCreateFile(
		&afd_helper_handle,
		SYNCHRONIZE,
		&AFD_HELPER_ATTRIBUTES,
		&iosb,
		nil,
		0,
		FILE_SHARE_READ | FILE_SHARE_WRITE,
		FILE_OPEN,
		0,
		nil,
		0,
	)

	if status != STATUS_SUCCESS {
		raw_err := Errno(RtlNtStatusToDosError(status))
		fmt.printf("Failed to open \\Device\\Afd\\Mio: %v", raw_err)
		return {}, raw_err
	}
	token := get_next_afd_token()
	afd := Afd{afd_helper_handle, 1} // todo: should init with RC=1?
	add_handle(cp, &token, afd.fd)

	result := SetFileCompletionNotificationModes(afd_helper_handle, FILE_SKIP_SET_EVENT_ON_HANDLE)
	if result == false {
		return {}, Errno(GetLastError())
	}
	return afd, Errno(0)
}
