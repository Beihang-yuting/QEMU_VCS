add_library(cosim_eth STATIC
    eth_port.c
    mac_stub.c
)
target_include_directories(cosim_eth PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../common
)
target_link_libraries(cosim_eth PRIVATE cosim_bridge_common rt pthread)
