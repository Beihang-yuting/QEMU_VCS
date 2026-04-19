/* cosim-platform/bridge/qemu/sock_sync.h */
#ifndef SOCK_SYNC_H
#define SOCK_SYNC_H

#include "cosim_types.h"

int sock_sync_listen(const char *path);
int sock_sync_accept(int listen_fd);
int sock_sync_connect(const char *path);
int sock_sync_send(int fd, const sync_msg_t *msg);
int sock_sync_recv(int fd, sync_msg_t *msg);
int sock_sync_recv_timed(int fd, sync_msg_t *msg, int timeout_ms);
void sock_sync_close(int fd);

#endif
