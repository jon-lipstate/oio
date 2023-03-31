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
	SetFileCompletionNotificationModes :: proc(FileHandle: HANDLE, Flags: u8) -> BOOL ---
	CreateIoCompletionPort :: proc(file_handle: HANDLE, existing_completion_port: HANDLE, completion_key: ^c.ulong, n_of_concurrent_threads: DWORD) -> HANDLE ---
	// <https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getqueuedcompletionstatusex>
	GetQueuedCompletionStatusEx :: proc(CompletionPort: HANDLE, lpCompletionPortEntries: ^OVERLAPPED_ENTRY, ulCount: c.ulong, ulNumEntriesRemoved: ^c.ulong, dwMilliseconds: DWORD, fAlertable: BOOL) -> BOOL ---
	// <https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-postqueuedcompletionstatus>
	PostQueuedCompletionStatus :: proc(CompletionPort: HANDLE, dwNumberOfBytesTransferred: DWORD, dwCompletionKey: c.ulong, lpOverlapped: ^OVERLAPPED) -> BOOL ---
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
STATUS_SUCCESS :: i32(0x00000000)
STATUS_PENDING :: i32(0x00000103)
STATUS_NOT_FOUND :: transmute(i32)u32(0xC0000225)

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
		Status:  NTSTATUS,
		Pointer: rawptr,
	},
	Information: uintptr, // ulongptr
}
IO_APC_ROUTINE :: proc(ApcContext: rawptr, IoStatusBlock: ^IO_STATUS_BLOCK, Reserved: c.ulong)

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

SIO_BASE_HANDLE: i32 = 0x48000022
SIO_BSP_HANDLE: i32 = 0x48000023
SIO_BSP_HANDLE_POLL: i32 = 0x48000024
SIO_BSP_HANDLE_SELECT: i32 = 0x48000025
SOCKET_ERROR: i32 = -1