#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <sys/wait.h>
#include "sock_sync.h"
#include "cosim_types.h"

static const char *SOCK_PATH = "/tmp/cosim_test_sync.sock";

static void test_send_recv(void) {
    unlink(SOCK_PATH);
    pid_t pid = fork();

    if (pid == 0) {
        /* Child: client */
        usleep(100000);
        int fd = sock_sync_connect(SOCK_PATH);
        assert(fd >= 0);

        sync_msg_t msg;
        int ret = sock_sync_recv(fd, &msg);
        assert(ret == 0);
        assert(msg.type == SYNC_MSG_TLP_READY);

        sync_msg_t reply = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        ret = sock_sync_send(fd, &reply);
        assert(ret == 0);

        sock_sync_close(fd);
        _exit(0);
    }

    /* Parent: server */
    int listen_fd = sock_sync_listen(SOCK_PATH);
    assert(listen_fd >= 0);
    int client_fd = sock_sync_accept(listen_fd);
    assert(client_fd >= 0);

    sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
    int ret = sock_sync_send(client_fd, &msg);
    assert(ret == 0);

    sync_msg_t reply;
    ret = sock_sync_recv(client_fd, &reply);
    assert(ret == 0);
    assert(reply.type == SYNC_MSG_CPL_READY);

    sock_sync_close(client_fd);
    sock_sync_close(listen_fd);

    int status;
    waitpid(pid, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    unlink(SOCK_PATH);
    printf("  PASS: test_send_recv\n");
}

int main(void) {
    printf("=== sock_sync tests ===\n");
    test_send_recv();
    printf("=== ALL PASSED ===\n");
    return 0;
}
