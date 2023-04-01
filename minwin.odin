package oio

import "core:sys/windows"
import "./sys/win" //ffi bindings that are missing in core:sys/windows

import "core:fmt"
import "core:strings"
import "core:c"
import "core:net"
import "core:math/bits"
HANDLE :: windows.HANDLE
Errno :: win.Errno
Result :: union($Value: typeid, $Error: typeid) {
	Value,
	Error,
}
AsyncFd :: HANDLE
OVERLAPPED_ENTRY :: win.OVERLAPPED_ENTRY

create_completion_port :: proc() -> Result(HANDLE, Errno) {
	using win
	port := CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 0)
	if port == nil {
		err := GetLastError()
		fmt.println("Failed to create IOCP", err)
		return Errno(err)
	}
	return port
}
associate_to_port :: proc(port: HANDLE, file_handle: HANDLE, ident: u32) -> Result(HANDLE, Errno) {
	using win
	handle := CreateIoCompletionPort(file_handle, port, ident, 0)
	if handle == nil {
		err := GetLastError()
		fmt.println("Failed to associate listener socket with IOCP", err)
		return Errno(err)
	}
	return handle
}

main :: proc() {
	// using win
	addr := "127.0.0.1:3000"
	ep, epok := net.parse_endpoint(addr)
	assert(epok)
	listener, serr := net.listen_tcp(ep, 5)
	defer net.close(listener)

	// 1. Create a Completion Port
	port := create_completion_port().(windows.HANDLE)
	defer windows.CloseHandle(port)
	// 2. Associate to the Port
	associate_to_port(port, transmute(HANDLE)listener, 7)
	// 3. Create AsyncFd
	afd := afd_from_completion_port(port).(AsyncFd)
	// 4. Try Polling
	events := AFD_POLL_HANDLE_INFO {
		Handle     = transmute(HANDLE)listener,
		Status     = 0,
		PollEvents = READER_FLAGS,
	}
	poll_info := AFD_POLL_INFO {
		NumberOfHandles = 1,
		Timeout         = 1000, // 9223372036854775807,
		Handles         = &events,
	}
	iosb := win.IO_STATUS_BLOCK{}
	iosb.Status = win.STATUS_PENDING
	overlapped := win.OVERLAPPED{}
	fmt.println("overlapped", overlapped)
	fmt.println("IOCTL_AFD_POLL", IOCTL_AFD_POLL)
	fmt.println(poll_info)
	fmt.println(iosb.Status)
	status := win.NtDeviceIoControlFile(
		afd,
		nil,
		nil,
		&overlapped,
		&iosb,
		IOCTL_AFD_POLL,
		&poll_info,
		size_of(poll_info),
		&poll_info,
		size_of(poll_info),
	)
	fmt.printf("status: 0x%X \n", transmute(u32)status)

	if status != win.STATUS_PENDING {
		raw_err := win.RtlNtStatusToDosError(status)
		fmt.printf("Failed to poll AFD: 0x%X", u32(raw_err))
		return
	}
	fmt.println("call get_queued_completion_status_ex")
	completion_status: []OVERLAPPED_ENTRY
	switch cs in get_queued_completion_status_ex(port, 1) {
	case (Errno):
		fmt.printf("Error: %v", cs)
		return
	case ([]OVERLAPPED_ENTRY):
		completion_status = cs
	}
	fmt.println("Completion status: ", completion_status)
}
///
// AFD_POLL_EVENTS struct
AFD_POLL_HANDLE_INFO :: struct {
	Handle:     HANDLE,
	PollEvents: u32, // ULONG
	Status:     i32, // NTSTATUS
}
AFD_POLL_INFO :: struct {
	Timeout:         i64, // LARGE_INTEGER,
	NumberOfHandles: u32, // ulong
	Unique:          bool, //BOOLEAN 
	Handles:         ^AFD_POLL_HANDLE_INFO, //AFD_POLL_HANDLE_INFO Handles[1]
}
IOCTL_AFD_POLL :: 0x00012024
//0001 1011 1001
READER_FLAGS :: AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT | AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_ACCEPT | AFD_POLL_CONNECT_FAIL
READ_CLOSED_FLAGS :: AFD_POLL_DISCONNECT | AFD_POLL_ABORT | AFD_POLL_CONNECT_FAIL

//https://github.com/DeDf/afd/blob/master/afd.h
// 0
AFD_POLL_RECEIVE: u32 : 1 << 0
// 1
AFD_POLL_RECEIVE_EXPEDITED: u32 : 1 << 1
// 2
AFD_POLL_SEND: u32 : 1 << 2
// 3
AFD_POLL_DISCONNECT: u32 : 1 << 3
// 4
AFD_POLL_ABORT: u32 : 1 << 4
// 5
AFD_POLL_LOCAL_CLOSE: u32 : 1 << 5
// 6
AFD_POLL_CONNECT: u32 : 1 << 6
// 7
AFD_POLL_ACCEPT: u32 : 1 << 7
// 8
AFD_POLL_CONNECT_FAIL: u32 : 1 << 8
AFD_POLL_QOS: u32 : 1 << 9
AFD_POLL_GROUP_QOS: u32 : 1 << 10

get_queued_completion_status_ex :: proc(port: HANDLE, count: int) -> Result([]OVERLAPPED_ENTRY, Errno) {
	using win
	removed: u32 = 0
	items := make([]OVERLAPPED_ENTRY, count)
	entries := transmute([^]OVERLAPPED_ENTRY)raw_data(items)
	ret := GetQueuedCompletionStatusEx(port, entries, u32(len(items)), &removed, INFINITE, false)
	if ret == false {
		return Errno(GetLastError())
	}
	new_items := items[:removed]

	return new_items
}

afd_from_completion_port :: proc(port: HANDLE) -> Result(AsyncFd, Errno) {
	using win
	asyncFd: HANDLE = INVALID_HANDLE_VALUE
	iosb: IO_STATUS_BLOCK = {} // seems this is tossed

	status := NtCreateFile(
		&asyncFd,
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
		fmt.printf("Failed to open \\Device\\Afd\\OIO: %v", raw_err)
		return raw_err
	}

	self := associate_to_port(port, asyncFd, 42)
	h := self.(windows.HANDLE)
	assert(h == port)

	result := SetFileCompletionNotificationModes(asyncFd, FILE_SKIP_SET_EVENT_ON_HANDLE)
	if result == false {
		return Errno(GetLastError())
	}
	fmt.println("afd created")
	return asyncFd
}

UNICODE_STRING :: struct {
	Length:        u16, // USHORT
	MaximumLength: u16, // USHORT
	Buffer:        ^u16, // PWSTR
}
import "core:unicode/utf16"
AFD_HELPER_NAME: [15]u16
@(init)
get_obj_name :: proc() {
	// todo: revert to static u16 string
	utf16.encode_string(AFD_HELPER_NAME[:], "\\Device\\Afd\\OIO")
}
AFD_OBJ_NAME := UNICODE_STRING {
	Length        = u16(len(AFD_HELPER_NAME)) * size_of(u16),
	MaximumLength = len(AFD_HELPER_NAME) * size_of(u16),
	Buffer        = &AFD_HELPER_NAME[0],
}
OBJECT_ATTRIBUTES :: struct {
	Length:                   c.ulong,
	RootDirectory:            HANDLE,
	ObjectName:               ^UNICODE_STRING,
	Attributes:               c.ulong,
	SecurityDescriptor:       rawptr,
	SecurityQualityOfService: rawptr,
}

AFD_HELPER_ATTRIBUTES := OBJECT_ATTRIBUTES {
	Length                   = size_of(OBJECT_ATTRIBUTES),
	RootDirectory            = nil,
	ObjectName               = &AFD_OBJ_NAME,
	Attributes               = 0,
	SecurityDescriptor       = nil,
	SecurityQualityOfService = nil,
}
