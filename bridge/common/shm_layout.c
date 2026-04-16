#include "shm_layout.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

int cosim_shm_create(cosim_shm_t *shm, const char *name) {
    shm_unlink(name);

    int fd = shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0666);
    if (fd < 0) { perror("shm_open create"); return -1; }

    if (ftruncate(fd, COSIM_SHM_TOTAL_SIZE) < 0) {
        perror("ftruncate"); close(fd); shm_unlink(name); return -1;
    }

    void *base = mmap(NULL, COSIM_SHM_TOTAL_SIZE, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        perror("mmap"); close(fd); shm_unlink(name); return -1;
    }

    memset(base, 0, COSIM_SHM_TOTAL_SIZE);

    shm->base = base;
    shm->fd = fd;

    shm->ctrl = (cosim_ctrl_t *)((uint8_t *)base + COSIM_SHM_CTRL_OFFSET);
    shm->ctrl->magic = COSIM_SHM_MAGIC;
    shm->ctrl->version = COSIM_PROTOCOL_VER;
    shm->ctrl->mode = COSIM_MODE_FAST;
    atomic_store(&shm->ctrl->qemu_ready, 0);
    atomic_store(&shm->ctrl->vcs_ready, 0);
    atomic_store(&shm->ctrl->sim_time_ns, 0);

    void *req_buf = (uint8_t *)base + COSIM_SHM_REQ_OFFSET;
    ring_buf_init(&shm->req_ring, req_buf, COSIM_SHM_REQ_SIZE, sizeof(tlp_entry_t));

    void *cpl_buf = (uint8_t *)base + COSIM_SHM_CPL_OFFSET;
    ring_buf_init(&shm->cpl_ring, cpl_buf, COSIM_SHM_CPL_SIZE, sizeof(cpl_entry_t));

    return 0;
}

int cosim_shm_open(cosim_shm_t *shm, const char *name) {
    int fd = shm_open(name, O_RDWR, 0666);
    if (fd < 0) { perror("shm_open open"); return -1; }

    void *base = mmap(NULL, COSIM_SHM_TOTAL_SIZE, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        perror("mmap"); close(fd); return -1;
    }

    shm->base = base;
    shm->fd = fd;
    shm->ctrl = (cosim_ctrl_t *)((uint8_t *)base + COSIM_SHM_CTRL_OFFSET);

    if (shm->ctrl->magic != COSIM_SHM_MAGIC) {
        fprintf(stderr, "SHM magic mismatch: expected 0x%X, got 0x%X\n",
                COSIM_SHM_MAGIC, shm->ctrl->magic);
        munmap(base, COSIM_SHM_TOTAL_SIZE);
        close(fd);
        return -1;
    }

    void *req_buf = (uint8_t *)base + COSIM_SHM_REQ_OFFSET;
    ring_buf_attach(&shm->req_ring, req_buf, COSIM_SHM_REQ_SIZE, sizeof(tlp_entry_t));

    void *cpl_buf = (uint8_t *)base + COSIM_SHM_CPL_OFFSET;
    ring_buf_attach(&shm->cpl_ring, cpl_buf, COSIM_SHM_CPL_SIZE, sizeof(cpl_entry_t));

    return 0;
}

void cosim_shm_close(cosim_shm_t *shm) {
    if (shm->base) {
        munmap(shm->base, COSIM_SHM_TOTAL_SIZE);
        shm->base = NULL;
    }
    if (shm->fd >= 0) {
        close(shm->fd);
        shm->fd = -1;
    }
}

void cosim_shm_destroy(cosim_shm_t *shm, const char *name) {
    cosim_shm_close(shm);
    shm_unlink(name);
}
