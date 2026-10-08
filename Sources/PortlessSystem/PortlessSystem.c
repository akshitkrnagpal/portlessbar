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
#include <stdlib.h>

int pb_arguments(int pid, char *buffer, size_t *size) {
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    return sysctl(mib, 3, buffer, size, NULL, 0);
}
int pb_executable(int pid, char *buffer, size_t size) {
    return proc_pidpath(pid, buffer, (uint32_t)size);
}
// Return the generation of the TCP listener serving the requested loopback
// address. Comparing it across a probe detects a replaced socket or reused PID.
uint64_t pb_listener(int pid, int port, int ipv6) {
    if (pid <= 1 || port < 1 || port > 65535) return 0;
    int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required <= 0 || required > 16 * 1024 * 1024) return 0;
    int capacity = required + 32 * sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc(capacity);
    if (!fds) return 0;
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, capacity);
    uint64_t generation = 0;
    for (int i = 0; i < bytes / (int)sizeof(*fds); i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo socket = {0};
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)
            || socket.psi.soi_kind != SOCKINFO_TCP) continue;
        struct tcp_sockinfo *tcp = &socket.psi.soi_proto.pri_tcp;
        struct in_sockinfo *address = &tcp->tcpsi_ini;
        if (tcp->tcpsi_state != TSI_S_LISTEN || ntohs((uint16_t)address->insi_lport) != port) continue;
        if (ipv6) {
            if (!(address->insi_vflag & INI_IPV6)
                || !(IN6_IS_ADDR_UNSPECIFIED(&address->insi_laddr.ina_6)
                     || IN6_IS_ADDR_LOOPBACK(&address->insi_laddr.ina_6))) continue;
        } else {
            uint32_t local = address->insi_laddr.ina_46.i46a_addr4.s_addr;
            if (!(address->insi_vflag & INI_IPV4)
                || (local != htonl(INADDR_ANY) && local != htonl(INADDR_LOOPBACK))) continue;
        }
        generation = address->insi_gencnt;
        break;
    }
    free(fds);
    return generation;
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
