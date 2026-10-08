#include "PortlessSystem.h"
#include <sys/sysctl.h>
#include <unistd.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <libproc.h>

int pb_arguments(int pid, char *buffer, size_t *size) {
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    return sysctl(mib, 3, buffer, size, NULL, 0);
}
int pb_executable(int pid, char *buffer, size_t size) {
    return proc_pidpath(pid, buffer, (uint32_t)size);
}
static int check_port(int port, int family) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_storage storage = {0};
    socklen_t length;
    if (family == AF_INET) {
        struct sockaddr_in *addr = (struct sockaddr_in *)&storage;
        addr->sin_family = AF_INET;
        addr->sin_port = htons(port);
        addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        length = sizeof(*addr);
    } else {
        struct sockaddr_in6 *addr = (struct sockaddr_in6 *)&storage;
        addr->sin6_family = AF_INET6;
        addr->sin6_port = htons(port);
        addr->sin6_addr = in6addr_loopback;
        length = sizeof(*addr);
    }
    int result = connect(fd, (struct sockaddr *)&storage, length);
    if (result != 0 && errno == EINPROGRESS) {
        struct pollfd poller = { .fd = fd, .events = POLLOUT };
        if (poll(&poller, 1, 180) > 0) {
            int error = 0;
            socklen_t size = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0) result = 0;
        }
    }
    close(fd);
    return result == 0;
}
int pb_listening(int port) {
    if (port < 1 || port > 65535) return 0;
    return check_port(port, AF_INET) || check_port(port, AF_INET6);
}
