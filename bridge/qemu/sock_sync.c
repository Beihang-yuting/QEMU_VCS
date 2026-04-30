/* cosim-platform/bridge/qemu/sock_sync.c */
#include "sock_sync.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>

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
    /* Non-blocking accept loop: avoids poll()/select() for VCS Q-2020
     * compatibility on Linux 6.17+ kernels. */
    int printed = 0;
    /* Set listen socket to non-blocking */
    int flags = fcntl(listen_fd, F_GETFL, 0);
    fcntl(listen_fd, F_SETFL, flags | O_NONBLOCK);

    while (1) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd >= 0) {
            /* Restore blocking mode on listen socket */
            fcntl(listen_fd, F_SETFL, flags);
            fprintf(stderr, "[bridge] VCS connected.\n");
            return fd;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (!printed) {
                fprintf(stderr,
                    "[bridge] Waiting for VCS connection...\n"
                    "  Please start VCS in another terminal: make run-vcs\n");
                printed = 1;
            }
            usleep(500000);  /* 0.5s between retries */
            continue;
        }
        if (errno == EINTR) {
            fcntl(listen_fd, F_SETFL, flags);
            return -1;
        }
        perror("accept");
        fcntl(listen_fd, F_SETFL, flags);
        return -1;
    }
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
 * Returns: 0=success, 1=timeout (no data), -1=error
 *
 * NOTE: Avoids poll()/select() — VCS Q-2020 runtime segfaults when
 * these syscalls are active on Linux 6.17+ kernels. Uses non-blocking
 * recv() with MSG_DONTWAIT + usleep spin instead. */
int sock_sync_recv_timed(int fd, sync_msg_t *msg, int timeout_ms) {
    int elapsed_us = 0;
    int limit_us = timeout_ms * 1000;
    int spin_us = (timeout_ms == 0) ? 0 : 500;  /* 0.5ms spin interval */

    for (;;) {
        ssize_t n = recv(fd, msg, sizeof(*msg), MSG_DONTWAIT);
        if (n == (ssize_t)sizeof(*msg)) return 0;  /* success */
        if (n == 0) {
            fprintf(stderr, "sock_sync_recv_timed: connection closed\n");
            return -1;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                /* No data available */
                if (elapsed_us >= limit_us) return 1;  /* timeout */
                if (spin_us > 0) {
                    usleep(spin_us);
                    elapsed_us += spin_us;
                } else {
                    return 1;  /* timeout_ms == 0, immediate return */
                }
                continue;
            }
            perror("sock_sync_recv_timed: recv");
            return -1;
        }
        /* Partial read — shouldn't happen with SOCK_STREAM + small msg */
        fprintf(stderr, "sock_sync_recv_timed: partial read %zd/%zu\n",
                n, sizeof(*msg));
        return -1;
    }
}

void sock_sync_close(int fd) {
    if (fd >= 0) close(fd);
}
