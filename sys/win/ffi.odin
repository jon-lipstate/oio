package sys_win
import "core:sys/windows"
import "core:c"
import "core:unicode/utf16"
import "core:os"
//
INVALID_HANDLE_VALUE :: windows.INVALID_HANDLE_VALUE
HANDLE :: windows.HANDLE
NTSTATUS :: windows.NTSTATUS
LARGE_INTEGER :: windows.LARGE_INTEGER
BOOLEAN :: windows.BOOLEAN
BOOL :: windows.BOOL
DWORD :: windows.DWORD
OVERLAPPED :: windows.OVERLAPPED
GetLastError :: windows.GetLastError
ERROR_IO_PENDING :: windows.ERROR_IO_PENDING
WAIT_TIMEOUT :: windows.WAIT_TIMEOUT
ERROR_NONE :: os.ERROR_NONE
SOCKET :: windows.SOCKET
WSAGetLastError :: windows.WSAGetLastError
//
foreign import ws2_32 "system:Ws2_32.lib"
@(default_calling_convention = "stdcall")
foreign ws2_32 {
	WSAIoctl :: proc(s: SOCKET, dwIoControlCode: DWORD, lpvInBuffer: rawptr, cbInBuffer: DWORD, lpvOutBuffer: rawptr, cbOutBuffer: DWORD, lpcbBytesReturned: ^DWORD, lpOverlapped: ^WSAOVERLAPPED, lpCompletionRoutine: ^WSAOVERLAPPED_COMPLETION_ROUTINE) -> c.int ---
}

//
foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "stdcall")
foreign kernel32 {
	// [MS-Docs](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfilecompletionnotificationmodes)
	SetFileCompletionNotificationModes :: proc(FileHandle: HANDLE, Flags: u8) -> BOOL ---
	// [MS-Docs](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-createiocompletionport)
	CreateIoCompletionPort :: proc(file_handle: HANDLE, existing_completion_port: HANDLE, completion_key: c.ulong, n_of_concurrent_threads: DWORD) -> HANDLE ---
	// [MS-Docs](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getqueuedcompletionstatusex)
	GetQueuedCompletionStatusEx :: proc(CompletionPort: HANDLE, lpCompletionPortEntries: ^OVERLAPPED_ENTRY, ulCount: c.ulong, ulNumEntriesRemoved: ^c.ulong, dwMilliseconds: DWORD, fAlertable: BOOL) -> BOOL ---
	// [MS-Docs](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-postqueuedcompletionstatus)
	PostQueuedCompletionStatus :: proc(CompletionPort: HANDLE, dwNumberOfBytesTransferred: DWORD, dwCompletionKey: c.ulong, lpOverlapped: ^OVERLAPPED) -> BOOL ---
	//
	CreateEventA :: proc(lpEventAttributes: rawptr, bManualReset: BOOL, bInitialState: BOOL, lpName: ^cstring) -> HANDLE --- //LPSECURITY_ATTRIBUTES//LPCSTR
	//
	GetTickCount64 :: proc() -> u64 ---
	// [MS-Docs](https://github.com/mic101/windows/blob/master/WRK-v1.2/base/ntos/ex/keyedevent.c)
	NtCreateKeyedEvent :: proc(KeyedEventHandle: ^HANDLE, DesiredAccess: ACCESS_MASK, ObjectAttributes: OBJECT_ATTRIBUTES, Flags: u32) -> NTSTATUS ---
	// [MS-Docs](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-gethandleinformation)
	GetHandleInformation :: proc(hObject: HANDLE, lpdwFlags: ^DWORD) -> BOOL ---
}
SECURITY_QUALITY_OF_SERVICE :: struct {
	Length:              DWORD,
	ImpersonationLevel:  SECURITY_IMPERSONATION_LEVEL,
	ContextTrackingMode: BOOLEAN, // typedef BOOLEAN SECURITY_CONTEXT_TRACKING_MODE
	EffectiveOnly:       BOOLEAN,
}
SECURITY_IMPERSONATION_LEVEL :: enum {
	SecurityAnonymous,
	SecurityIdentification,
	SecurityImpersonation,
	SecurityDelegation,
}
//
Errno :: os.Errno
//
STATUS_CANCELLED :: u32(0xC0000120)
//
ACCESS_MASK :: u32 // From "ntdef.h" or "winnt.h"
SYNCHRONIZE :: u32(0x00100000)
FILE_SHARE_READ :: u32(0x00000001)
FILE_SHARE_WRITE :: u32(0x00000002)
FILE_OPEN :: u32(0x00000001)
//winbase.h
FILE_SKIP_SET_EVENT_ON_HANDLE :: 0x2
// From ntdef.h | winnt.h
OBJECT_ATTRIBUTES :: struct {
	Length:                   c.ulong,
	RootDirectory:            HANDLE,
	ObjectName:               ^UNICODE_STRING,
	Attributes:               c.ulong,
	SecurityDescriptor:       rawptr, // PSECURITY_DESCRIPTOR :: typedef PVOID PSECURITY_DESCRIPTOR
	SecurityQualityOfService: rawptr, // PSECURITY_QUALITY_OF_SERVICE
}

//ntstatus.h
STATUS_SUCCESS :: 0x00000000
STATUS_PENDING :: 0x00000103
STATUS_NOT_FOUND :: transmute(i32)u32(0xC0000225) // TODO: better way?

foreign import ntdll_lib "system:ntdll.lib"
@(default_calling_convention = "stdcall")
foreign ntdll_lib {
	// See <https://processhacker.sourceforge.io/doc/ntioapi_8h.html#a0d4d550cad4d62d75b76961e25f6550c>
	NtCancelIoFileEx :: proc(FileHandle: HANDLE, IoRequestToCancel: ^IO_STATUS_BLOCK, IoStatusBlock: ^IO_STATUS_BLOCK) -> NTSTATUS ---
	NtDeviceIoControlFile :: proc(FileHandle: HANDLE, Event: HANDLE, ApcRoutine: ^IO_APC_ROUTINE, ApcContext: rawptr, IoStatusBlock: ^IO_STATUS_BLOCK, IoControlCode: c.ulong, InputBuffer: rawptr, InputBufferLength: c.ulong, OutputBuffer: rawptr, OutputBufferLength: c.ulong) -> NTSTATUS ---
	RtlNtStatusToDosError :: proc(Status: NTSTATUS) -> c.ulong ---
	// See <https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile>
	NtCreateFile :: proc(FileHandle: ^HANDLE, DesiredAccess: ACCESS_MASK, ObjectAttributes: ^OBJECT_ATTRIBUTES, IoStatusBlock: ^IO_STATUS_BLOCK, AllocationSize: ^LARGE_INTEGER, FileAttributes: c.ulong, ShareAccess: c.ulong, CreateDisposition: c.ulong, CreateOptions: c.ulong, EaBuffer: rawptr, EaLength: c.ulong) -> NTSTATUS ---
}

IO_STATUS_BLOCK :: struct #packed {
	using _:     struct #raw_union {
		Status:  NTSTATUS, // i32?
		Pointer: rawptr, // padding
	},
	Information: uint, // ULONG_PTR
}
IO_APC_ROUTINE :: proc(ApcContext: rawptr, IoStatusBlock: ^IO_STATUS_BLOCK, Reserved: c.ulong)
// //The OVERLAPPED instance must survive as long as the I/O operation is in progress
// sOVERLAPPED :: struct {
// 	Internal:     ^c_ulong, // holds status: STATUS_PENDING (0x103)
// 	InternalHigh: ^c_ulong, // #bytes xfer once op finish
// 	Offset:       DWORD,
// 	OffsetHigh:   DWORD,
// 	hEvent:       HANDLE,
// }
///minwinbase.h
OVERLAPPED_ENTRY :: struct {
	lpCompletionKey:            c.ulong,
	lpOverlapped:               ^OVERLAPPED,
	Internal:                   c.ulong,
	dwNumberOfBytesTransferred: DWORD,
}
WSAOVERLAPPED :: struct {
	Internal:     DWORD,
	InternalHigh: DWORD,
	Offset:       DWORD,
	OffsetHigh:   DWORD,
	hEvent:       HANDLE,
}
WSAOVERLAPPED_COMPLETION_ROUTINE :: proc(dwError: DWORD, cbTransferred: DWORD, lpOverlapped: ^WSAOVERLAPPED, dwFlags: DWORD)

SIO_BASE_HANDLE :: 0x48000022
SIO_BSP_HANDLE :: 0x48000023
SIO_BSP_HANDLE_POLL :: 0x48000024
SIO_BSP_HANDLE_SELECT :: 0x48000025
SOCKET_ERROR :: -1
WSA_IO_PENDING :: windows.ERROR_IO_PENDING
// #define WSA_IO_PENDING          (ERROR_IO_PENDING)
// #define WSA_IO_INCOMPLETE       (ERROR_IO_INCOMPLETE)
// #define WSA_INVALID_HANDLE      (ERROR_INVALID_HANDLE)
// #define WSA_INVALID_PARAMETER   (ERROR_INVALID_PARAMETER)
// #define WSA_NOT_ENOUGH_MEMORY   (ERROR_NOT_ENOUGH_MEMORY)
// #define WSA_OPERATION_ABORTED   (ERROR_OPERATION_ABORTED)
foreign import mswsock_lib "system:Mswsock.lib"
@(default_calling_convention = "stdcall")
foreign mswsock_lib {
	//<https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nf-mswsock-acceptex>
	AcceptEx :: proc(sListenSocket: SOCKET, sAcceptSocket: SOCKET, lpOutputBuffer: rawptr, dwReceiveDataLength: DWORD, dwLocalAddressLength: DWORD, dwRemoteAddressLength: DWORD, lpdwBytesReceived: ^DWORD, lpOverlapped: ^OVERLAPPED) -> BOOL ---
}
