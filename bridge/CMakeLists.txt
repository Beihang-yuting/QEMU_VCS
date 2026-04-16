add_library(cosim_bridge_common STATIC
    common/shm_layout.c
    common/ring_buffer.c
    common/dma_manager.c
    common/trace_log.c
)
target_include_directories(cosim_bridge_common PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/common
)
target_link_libraries(cosim_bridge_common PRIVATE rt pthread)

add_library(cosim_bridge SHARED
    qemu/bridge_qemu.c
    qemu/sock_sync.c
    qemu/irq_poller.c
)
target_include_directories(cosim_bridge PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/common
    ${CMAKE_CURRENT_SOURCE_DIR}/qemu
)
target_link_libraries(cosim_bridge PRIVATE cosim_bridge_common rt pthread)

add_library(cosim_bridge_vcs SHARED
    vcs/bridge_vcs.c
    vcs/sock_sync_vcs.c
)
target_include_directories(cosim_bridge_vcs PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/common
    ${CMAKE_CURRENT_SOURCE_DIR}/vcs
)
target_link_libraries(cosim_bridge_vcs PRIVATE cosim_bridge_common rt pthread)
