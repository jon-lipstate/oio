package oio
import "core:sys/windows"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:unicode/utf16"
import "core:container/queue"
import "core:runtime"
import "./sys/win"
// External API:
// epoll_create, epoll_create1, epoll_close, epoll_ctl, epoll_wait
//
INVALID_HANDLE_VALUE :: windows.INVALID_HANDLE_VALUE
ERROR_INVALID_HANDLE :: windows.ERROR_INVALID_HANDLE
ERROR_ALREADY_EXISTS :: windows.ERROR_ALREADY_EXISTS
INVALID_SOCKET :: windows.INVALID_SOCKET
GetLastError :: windows.GetLastError
SetLastError :: windows.SetLastError
WSAENOTSOCK :: windows.WSAENOTSOCK
SOCKET_ERROR :: windows.SOCKET_ERROR
HANDLE :: windows.HANDLE
SOCKET :: windows.SOCKET
INFINITE :: win.INFINITE
Allocator_Error :: runtime.Allocator_Error
//
CreateIoCompletionPort :: win.CreateIoCompletionPort
//////////////////////////////////////////////////////////////////////////////////////
Result :: union($Value: typeid, $Error: typeid) {
	Value,
	Error,
}
try_set :: #force_inline proc(the_map: $T/map[$K]$V, key: K, value: V) -> bool {
	if key in the_map {
		return false
	} else {
		the_map[key] = value
	}
}
unreachable :: proc(s := "") -> ! {
	panic(s)
}
//////////////////////////////////////////////////////////////////////////////////////
Queue :: queue.Queue
//Early return if already at back
queue_move_to_end :: proc(q: Queue($T), v: T) {
	if queue.peek_back(q) != v {return}

	i := 0
	for i = 0; i < len(q.data); i += 1 {
		if v == q.data[i] {break}
	}
	ordered_remove(q.data, i)
	queue.push_back(q, v)
}
///
OVERLAPPED_ENTRY :: win.OVERLAPPED_ENTRY
Errno :: win.Errno
NtDeviceIoControlFile :: win.NtDeviceIoControlFile
NtCreateFile :: win.NtCreateFile
STATUS_SUCCESS :: win.STATUS_SUCCESS
STATUS_PENDING :: win.STATUS_PENDING
ERROR_IO_PENDING :: win.ERROR_IO_PENDING
ERROR_INVALID_PARAMETER :: windows.ERROR_INVALID_PARAMETER
IO_STATUS_BLOCK :: win.IO_STATUS_BLOCK
//

UNICODE_STRING :: struct {
	Length:        u16, // USHORT
	MaximumLength: u16, // USHORT
	Buffer:        ^u16, // PWSTR
}
OBJECT_ATTRIBUTES :: struct {
	Length:                   u32,
	RootDirectory:            HANDLE,
	ObjectName:               ^UNICODE_STRING,
	Attributes:               u32,
	SecurityDescriptor:       rawptr,
	SecurityQualityOfService: rawptr,
}

FILE_OPEN: u32 : 0x00000001
STANDARD_RIGHTS_REQUIRED: i32 : 0x000F0000 // windows
KEYEDEVENT_WAIT: u32 : 0x00000001
KEYEDEVENT_WAKE: u32 : 0x00000002
KEYEDEVENT_ALL_ACCESS :: u32(STANDARD_RIGHTS_REQUIRED) | KEYEDEVENT_WAIT | KEYEDEVENT_WAKE

//https://github.com/DeDf/afd/blob/master/afd.h
AFD_POLL_RECEIVE: u32 : 1 << 0
AFD_POLL_RECEIVE_EXPEDITED: u32 : 1 << 1
AFD_POLL_SEND: u32 : 1 << 2
AFD_POLL_DISCONNECT: u32 : 1 << 3
AFD_POLL_ABORT: u32 : 1 << 4
AFD_POLL_LOCAL_CLOSE: u32 : 1 << 5
AFD_POLL_CONNECT: u32 : 1 << 6
AFD_POLL_ACCEPT: u32 : 1 << 7
AFD_POLL_CONNECT_FAIL: u32 : 1 << 8

AFD_POLL_HANDLE_INFO :: struct {
	Handle:     HANDLE,
	PollEvents: u32, // ULONG
	Status:     i32, // NTSTATUS
}

AFD_POLL_INFO :: struct {
	Timeout:         i64, // LARGE_INTEGER,
	NumberOfHandles: u32, // ulong
	Unique:          bool, //BOOLEAN
	Handles:         [1]AFD_POLL_HANDLE_INFO, //AFD_POLL_HANDLE_INFO Handles[1]
}

//https://stackoverflow.com/questions/73666936/data-transfer-manipulation-winsock2-ntdeviceiocontrolfile
IOCTL_AFD_POLL :: 0x00012024

//
EPOLL_IN := 1 << 0
EPOLL_PRI := 1 << 1
EPOLL_OUT := 1 << 2
EPOLL_ERR := 1 << 3
EPOLL_HUP := 1 << 4
EPOLL_RDNORM := 1 << 6
EPOLL_RDBAND := 1 << 7
EPOLL_WRNORM := 1 << 8
EPOLL_WRBAND := 1 << 9
EPOLL_MSG := 1 << 10
EPOLL_RDHUP := 1 << 13
EPOLL_ONESHOT := 1 << 31
EPOLL_KNOWN_EVENTS :=
	EPOLL_IN |
	EPOLL_PRI |
	EPOLL_OUT |
	EPOLL_ERR |
	EPOLL_HUP |
	EPOLL_RDNORM |
	EPOLL_RDBAND |
	EPOLL_WRNORM |
	EPOLL_WRBAND |
	EPOLL_MSG |
	EPOLL_RDHUP
CTL_Action :: enum {
	Add = 1,
	Mod = 2,
	Del = 3,
}

Epoll_Data :: struct #raw_union {
	ptr:  rawptr,
	fd:   int,
	u32:  u32,
	u64:  u64,
	sock: SOCKET,
	hnd:  HANDLE,
}

Epoll_Event :: struct {
	events: u32,
	data:   Epoll_Data,
}

POLL_GROUP_MAX_GROUP_SIZE :: 32
Poll_Group :: struct {
	port_state:        ^Port_State,
	afd_device_handle: HANDLE,
	// Number of subscribers to this group, keep below max_size for perf
	group_size:        int,
}

PORT_MAX_ON_STACK_COMPLETIONS :: 256
Port_State :: struct {
	iocp:               IOCP,
	sockets:            map[SOCKET]^Sock_State, // sock_tree
	update_queue:       map[^Sock_State]struct {}, // this really wants to be a Set[T]
	sock_deleted_queue: Queue(^Sock_State),
	poll_group_queue:   Queue(^Poll_Group),
	//
	lock:               sync.Mutex,
	active_poll_count:  int,
	//

	// handle_tree_node:   Ts_Tree_Node,
}
Sock_Poll_Status :: enum {
	Idle = 0,
	Pending,
	Cancelled,
}
Sock_State :: struct {
	io_status_block: IO_STATUS_BLOCK, // Do NOT move from first position, used for casting upwards to Sock_State
	poll_info:       AFD_POLL_INFO,
	// queue_node:      Queue_Node,
	// tree_node:       Tree_Node,
	// parent:          ^Port_State, // new from me
	poll_group:      ^Poll_Group,
	base_socket:     SOCKET,
	user_data:       Epoll_Data,
	user_events:     u32,
	pending_events:  u32,
	poll_status:     Sock_Poll_Status,
	delete_pending:  bool,
}
SIO_BSP_HANDLE_POLL :: 0x4800001D
SIO_BASE_HANDLE :: 0x48000022

/////////// GLOBAL \\\\\\\\\\\\\\
// Must be in this order:
@(init, private)
ws_global_init :: proc() {
	using windows
	unused_info: WSADATA
	version_requested := WORD(2) << 8 | 2
	res := WSAStartup(version_requested, &unused_info)
	assert(res == STATUS_SUCCESS)
}
// @(init, private)
// nt_global_init :: proc() {
// 	// ntdll = GetModuleHandleW(L"ntdll.dll")
// }
reflock__keyed_event: HANDLE
@(init, private)
reflock_global_init :: proc() {
	using win
	status := NtCreateKeyedEvent(&reflock__keyed_event, KEYEDEVENT_ALL_ACCESS, nil, 0)
	assert(status != STATUS_SUCCESS)
	err := Errno(RtlNtStatusToDosError(status))
}
// epoll__handle_tree: Ts_Tree
// @(init, private)
// epoll_global_init :: proc() {
// 	ts_tree_init(&epoll__handle_tree)
// }
AFD_HELPER_NAME: [15]u16
@(init, private)
get_obj_name :: proc() {
	// todo: revert to static u16 string
	utf16.encode_string(AFD_HELPER_NAME[:], "\\Device\\Afd\\Oio")
}
///////// END GLOBAL \\\\\\\\\\\\
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
//////////////////////////////////////////////////////////////////

import "core:os"

// ERRNO_MAPPINGS := map[u32]Errno {
// 	windows.ERROR_ACCESS_DENIED             = os.EACCES,
// 	windows.ERROR_ALREADY_EXISTS            = os.EEXIST,
// 	windows.ERROR_BAD_COMMAND               = os.EACCES,
// 	windows.ERROR_BAD_EXE_FORMAT            = os.ENOEXEC,
// 	windows.ERROR_BAD_LENGTH                = os.EACCES,
// 	windows.ERROR_BAD_NETPATH               = os.ENOENT,
// 	windows.ERROR_BAD_NET_NAME              = os.ENOENT,
// 	windows.ERROR_BAD_NET_RESP              = os.ENETDOWN,
// 	windows.ERROR_BAD_PATHNAME              = os.ENOENT,
// 	windows.ERROR_BROKEN_PIPE               = os.EPIPE,
// 	windows.ERROR_CANNOT_MAKE               = os.EACCES,
// 	windows.ERROR_COMMITMENT_LIMIT          = os.ENOMEM,
// 	windows.ERROR_CONNECTION_ABORTED        = os.ECONNABORTED,
// 	windows.ERROR_CONNECTION_ACTIVE         = os.EISCONN,
// 	windows.ERROR_CONNECTION_REFUSED        = os.ECONNREFUSED,
// 	windows.ERROR_CRC                       = os.EACCES,
// 	windows.ERROR_DIR_NOT_EMPTY             = os.ENOTEMPTY,
// 	windows.ERROR_DISK_FULL                 = os.ENOSPC,
// 	windows.ERROR_DUP_NAME                  = os.EADDRINUSE,
// 	windows.ERROR_FILENAME_EXCED_RANGE      = os.ENOENT,
// 	windows.ERROR_FILE_NOT_FOUND            = os.ENOENT,
// 	windows.ERROR_GEN_FAILURE               = os.EACCES,
// 	windows.ERROR_GRACEFUL_DISCONNECT       = os.EPIPE,
// 	windows.ERROR_HOST_DOWN                 = os.EHOSTUNREACH,
// 	windows.ERROR_HOST_UNREACHABLE          = os.EHOSTUNREACH,
// 	windows.ERROR_INSUFFICIENT_BUFFER       = os.EFAULT,
// 	windows.ERROR_INVALID_ADDRESS           = os.EADDRNOTAVAIL,
// 	windows.ERROR_INVALID_FUNCTION          = os.EINVAL,
// 	windows.ERROR_INVALID_HANDLE            = os.EBADF,
// 	windows.ERROR_INVALID_NETNAME           = os.EADDRNOTAVAIL,
// 	windows.ERROR_INVALID_PARAMETER         = os.EINVAL,
// 	windows.ERROR_INVALID_USER_BUFFER       = os.EMSGSIZE,
// 	windows.ERROR_IO_PENDING                = os.EINPROGRESS,
// 	windows.ERROR_LOCK_VIOLATION            = os.EACCES,
// 	windows.ERROR_MORE_DATA                 = os.EMSGSIZE,
// 	windows.ERROR_NETNAME_DELETED           = os.ECONNABORTED,
// 	windows.ERROR_NETWORK_ACCESS_DENIED     = os.EACCES,
// 	windows.ERROR_NETWORK_BUSY              = os.ENETDOWN,
// 	windows.ERROR_NETWORK_UNREACHABLE       = os.ENETUNREACH,
// 	windows.ERROR_NOACCESS                  = os.EFAULT,
// 	windows.ERROR_NONPAGED_SYSTEM_RESOURCES = os.ENOMEM,
// 	windows.ERROR_NOT_ENOUGH_MEMORY         = os.ENOMEM,
// 	windows.ERROR_NOT_ENOUGH_QUOTA          = os.ENOMEM,
// 	windows.ERROR_NOT_FOUND                 = os.ENOENT,
// 	windows.ERROR_NOT_LOCKED                = os.EACCES,
// 	windows.ERROR_NOT_READY                 = os.EACCES,
// 	windows.ERROR_NOT_SAME_DEVICE           = os.EXDEV,
// 	windows.ERROR_NOT_SUPPORTED             = os.ENOTSUP,
// 	windows.ERROR_NO_MORE_FILES             = os.ENOENT,
// 	windows.ERROR_NO_SYSTEM_RESOURCES       = os.ENOMEM,
// 	windows.ERROR_OPERATION_ABORTED         = os.EINTR,
// 	windows.ERROR_OUT_OF_PAPER              = os.EACCES,
// 	windows.ERROR_PAGED_SYSTEM_RESOURCES    = os.ENOMEM,
// 	windows.ERROR_PAGEFILE_QUOTA            = os.ENOMEM,
// 	windows.ERROR_PATH_NOT_FOUND            = os.ENOENT,
// 	windows.ERROR_PIPE_NOT_CONNECTED        = os.EPIPE,
// 	windows.ERROR_PORT_UNREACHABLE          = os.ECONNRESET,
// 	windows.ERROR_PROTOCOL_UNREACHABLE      = os.ENETUNREACH,
// 	windows.ERROR_REM_NOT_LIST              = os.ECONNREFUSED,
// 	windows.ERROR_REQUEST_ABORTED           = os.EINTR,
// 	windows.ERROR_REQ_NOT_ACCEP             = os.EWOULDBLOCK,
// 	windows.ERROR_SECTOR_NOT_FOUND          = os.EACCES,
// 	windows.ERROR_SEM_TIMEOUT               = os.ETIMEDOUT,
// 	windows.ERROR_SHARING_VIOLATION         = os.EACCES,
// 	windows.ERROR_TOO_MANY_NAMES            = os.ENOMEM,
// 	windows.ERROR_TOO_MANY_OPEN_FILES       = os.EMFILE,
// 	windows.ERROR_UNEXP_NET_ERR             = os.ECONNABORTED,
// 	windows.ERROR_WAIT_NO_CHILDREN          = os.ECHILD,
// 	windows.ERROR_WORKING_SET_QUOTA         = os.ENOMEM,
// 	windows.ERROR_WRITE_PROTECT             = os.EACCES,
// 	windows.ERROR_WRONG_DISK                = os.EACCES,
// 	windows.WSAEACCES                       = os.EACCES,
// 	windows.WSAEADDRINUSE                   = os.EADDRINUSE,
// 	windows.WSAEADDRNOTAVAIL                = os.EADDRNOTAVAIL,
// 	windows.WSAEAFNOSUPPORT                 = os.EAFNOSUPPORT,
// 	windows.WSAECONNABORTED                 = os.ECONNABORTED,
// 	windows.WSAECONNREFUSED                 = os.ECONNREFUSED,
// 	windows.WSAECONNRESET                   = os.ECONNRESET,
// 	windows.WSAEDISCON                      = os.EPIPE,
// 	windows.WSAEFAULT                       = os.EFAULT,
// 	windows.WSAEHOSTDOWN                    = os.EHOSTUNREACH,
// 	windows.WSAEHOSTUNREACH                 = os.EHOSTUNREACH,
// 	windows.WSAEINPROGRESS                  = os.EBUSY,
// 	windows.WSAEINTR                        = os.EINTR,
// 	windows.WSAEINVAL                       = os.EINVAL,
// 	windows.WSAEISCONN                      = os.EISCONN,
// 	windows.WSAEMSGSIZE                     = os.EMSGSIZE,
// 	windows.WSAENETDOWN                     = os.ENETDOWN,
// 	windows.WSAENETRESET                    = os.EHOSTUNREACH,
// 	windows.WSAENETUNREACH                  = os.ENETUNREACH,
// 	windows.WSAENOBUFS                      = os.ENOMEM,
// 	windows.WSAENOTCONN                     = os.ENOTCONN,
// 	windows.WSAENOTSOCK                     = os.ENOTSOCK,
// 	windows.WSAEOPNOTSUPP                   = os.EOPNOTSUPP,
// 	windows.WSAEPROCLIM                     = os.ENOMEM,
// 	windows.WSAESHUTDOWN                    = os.EPIPE,
// 	windows.WSAETIMEDOUT                    = os.ETIMEDOUT,
// 	windows.WSAEWOULDBLOCK                  = os.EWOULDBLOCK,
// 	windows.WSANOTINITIALISED               = os.ENETDOWN,
// 	windows.WSASYSNOTREADY                  = os.ENETDOWN,
// 	windows.WSAVERNOTSUPPORTED              = os.ENOSYS,
// }
