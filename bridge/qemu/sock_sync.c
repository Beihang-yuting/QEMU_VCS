/* cosim-platform/bridge/qemu/sock_sync.c */
#include "sock_sync.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <poll.h>

int sock_sync_listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(fd); return -1;
    }
    if (listen(fd, 1) < 0) {
        perror("listen"); close(fd); return -1;
    }
    return fd;
}

int sock_sync_accept(int listen_fd) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) perror("accept");
    return fd;
}

int sock_sync_connect(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect"); close(fd); return -1;
    }
    return fd;
}

int sock_sync_send(int fd, const sync_msg_t *msg) {
    ssize_t n = write(fd, msg, sizeof(*msg));
    if (n != (ssize_t)sizeof(*msg)) {
        perror("sock_sync_send");
        return -1;
    }
    return 0;
}

int sock_sync_recv(int fd, sync_msg_t *msg) {
    ssize_t n = read(fd, msg, sizeof(*msg));
    if (n != (ssize_t)sizeof(*msg)) {
        if (n == 0) fprintf(stderr, "sock_sync_recv: connection closed\n");
        else perror("sock_sync_recv");
        return -1;
    }
    return 0;
}

/* Non-blocking recv with timeout (milliseconds).
 * Returns: 0=success, 1=timeout (no data), -1=error */
int sock_sync_recv_timed(int fd, sync_msg_t *msg, int timeout_ms) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) {
        perror("sock_sync_recv_timed: poll");
        return -1;
    }
    if (ret == 0) return 1;  /* timeout */
    return sock_sync_recv(fd, msg);
}

void sock_sync_close(int fd) {
    if (fd >= 0) close(fd);
}
