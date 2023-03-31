package oio

import "core:sys/windows"
import "core:fmt"
import "core:strings"
import "core:c"
import "core:net"
import "./sys/win"

main :: proc() {
	using win
	addr := "127.0.0.1:3000"
	fmt.println("Making poll")
	p, ok := make_poll()
	ep, epok := net.parse_endpoint(addr)
	assert(epok)
	listener, serr := net.listen_tcp(ep, 5)
	defer net.close(listener)

	// Initialize IOCP
	completion_port := CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 0)
	if completion_port == nil {
		fmt.println("Failed to create IOCP")
		return
	}

	// Associate the listener socket with IOCP
	if CreateIoCompletionPort(transmute(HANDLE)listener, completion_port, 0, 0) == nil {
		fmt.println("Failed to associate listener socket with IOCP")
		return
	}

	client_addr: windows.SOCKADDR_STORAGE_LH
	client_addr_len: i32 = size_of(client_addr)

	// Use AcceptEx to accept connections asynchronously
	client_socket := windows.socket(windows.AF_INET, windows.SOCK_STREAM, windows.IPPROTO_TCP)
	if client_socket == windows.INVALID_SOCKET {
		fmt.printf("Failed to create client socket: %d\n", win.WSAGetLastError())
		return
	}

	overlapped := windows.OVERLAPPED{}
	accept_buffers_size := windows.DWORD((size_of(client_addr) + 16) * 2)
	accept_buffers := make([]u8, accept_buffers_size)
	bytes_received := windows.DWORD(0)

	// Start asynchronous accept
	call_accept := win.AcceptEx(
		transmute(SOCKET)listener,
		client_socket,
		&accept_buffers[0],
		0,
		size_of(windows.SOCKADDR_STORAGE_LH) + 16,
		size_of(windows.SOCKADDR_STORAGE_LH) + 16,
		&bytes_received,
		&overlapped,
	)
	if call_accept == false {
		errno := u32(win.WSAGetLastError())
		if errno != WSA_IO_PENDING {
			fmt.printf("AcceptEx failed: %d\n", errno)
			return
		}
	}
	removed: u32 = 0
	items := make([]OVERLAPPED_ENTRY, 2)
	entries := transmute([^]OVERLAPPED_ENTRY)raw_data(items)
	ret := GetQueuedCompletionStatusEx(completion_port, entries, u32(len(items)), &removed, INFINITE, false)
	if ret == false {
		fmt.println("QUEUE ERROR", Errno(GetLastError()))
	}
	new_items := items[:removed]

	fmt.println(removed, new_items)
	fmt.println("Connection accepted")

	// Process the accepted connection
	received_len: i32
	received_data: [256]u8

	// Read the request
	received_len = windows.recv(client_socket, &received_data[0], i32(len(received_data)), 0)
	if received_len > 0 {
		fmt.printf("Received from client: %.*s\n", received_len, received_data)

		// Prepare and send the response
		response_body := "Hello, Nonblocking!"
		sb := strings.builder_make()
		strings.write_string(&sb, "HTTP/1.1 200 OK\r\n")
		strings.write_string(&sb, "Content-Type: text/plain\r\n")
		strings.write_string(&sb, fmt.tprintf("Content-Length: %v\r\n", len(response_body)))
		strings.write_string(&sb, "\r\n")
		strings.write_string(&sb, response_body)
		response := strings.to_string(sb)
		sent_len, err := net.send_tcp(net.TCP_Socket(client_socket), transmute([]byte)strings.to_string(sb))

		fmt.println("Sent response to client")
	} else {
		fmt.printf("Error receiving from client: %d\n", win.WSAGetLastError())
	}

	// Clean up
	windows.CloseHandle(completion_port)
}
