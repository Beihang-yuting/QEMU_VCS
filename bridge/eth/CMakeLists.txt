# eth_mac_dpi.c 需要 VCS 的 svdpi.h，仅在 VCS 环境中通过 vcs 命令编译
# cmake 中只编译不依赖 VCS 的部分
add_library(cosim_eth STATIC
    eth_port.c
    mac_stub.c
)
target_include_directories(cosim_eth PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../common
)
target_link_libraries(cosim_eth PRIVATE cosim_bridge_common rt pthread)
