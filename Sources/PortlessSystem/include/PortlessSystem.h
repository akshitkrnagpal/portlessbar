#include <stddef.h>
#include <stdint.h>
int pb_arguments(int pid, char *buffer, size_t *size);
int pb_executable(int pid, char *buffer, size_t size);
int pb_listening(int port);
uint64_t pb_listener(int pid, int port, int ipv6);
