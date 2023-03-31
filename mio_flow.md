- make_poll()
  - new_selector()
    - new_completion_port()
      - CreateIoCompletionPort() <-- CompletionPort
    - make_afd_group()
- make_events_with_cap()
(setup listener)
- register(listener,token,reader)
  - register_inner()
    - new_sock_state()
      - acquire_afd()
        - afd_from_cp()
          - NtCreateFile(port)->afd
- poll()
  - select()
    - select2()
      - update_sockets_events()
        - update_sock_state()
          - afd_poll()
            - NtDeviceIoControlFile()
      - get_many()
        - GetQueuedCompletionStatusEx()
      - **(on trigger) feed_events
        - feed_event
        - update_queue
        - release_unused_afd




- Registry
  - Selector<OS>
    - CompletionPort
    - 




- Poll<T> 
  - Registry<T>
    - Selector<OS>
      - Token
      - Inner<OS>
        - CompletionPort
        - AfdGroup
          - port
          - []afd
        - Queue []SockState
          - iosb
          - ^afd
          - socket
          - status-stuff
          - info
            - HANDLE
            - events
            - ntstatus

