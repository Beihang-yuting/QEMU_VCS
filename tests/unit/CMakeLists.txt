add_executable(test_ring_buffer test_ring_buffer.c)
target_link_libraries(test_ring_buffer cosim_bridge_common)
add_test(NAME test_ring_buffer COMMAND test_ring_buffer)

add_executable(test_shm_layout test_shm_layout.c)
target_link_libraries(test_shm_layout cosim_bridge_common)
add_test(NAME test_shm_layout COMMAND test_shm_layout)

add_executable(test_dma_manager test_dma_manager.c)
target_link_libraries(test_dma_manager cosim_bridge_common)
add_test(NAME test_dma_manager COMMAND test_dma_manager)

add_executable(test_trace_log test_trace_log.c)
target_link_libraries(test_trace_log cosim_bridge_common)
add_test(NAME test_trace_log COMMAND test_trace_log)

add_executable(test_eth_shm test_eth_shm.c)
target_link_libraries(test_eth_shm cosim_bridge_common)
add_test(NAME test_eth_shm COMMAND test_eth_shm)

add_executable(test_link_model test_link_model.c)
target_link_libraries(test_link_model cosim_bridge_common)
add_test(NAME test_link_model COMMAND test_link_model)

add_executable(test_transport_tcp test_transport_tcp.c)
target_link_libraries(test_transport_tcp cosim_bridge_common cosim_bridge pthread)
add_test(NAME test_transport_tcp COMMAND test_transport_tcp)
set_tests_properties(test_transport_tcp PROPERTIES TIMEOUT 30)

add_executable(test_table_protocol test_table_protocol.c)
target_include_directories(test_table_protocol PRIVATE ${CMAKE_SOURCE_DIR}/bridge/table)
add_test(NAME test_table_protocol COMMAND test_table_protocol)

add_executable(test_table_target test_table_target.c)
target_include_directories(test_table_target PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/qemu
    ${CMAKE_SOURCE_DIR}/bridge/table
)
target_link_libraries(test_table_target cosim_bridge_common)
add_test(NAME test_table_target COMMAND test_table_target)

add_executable(test_table_route test_table_route.c)
target_include_directories(test_table_route PRIVATE ${CMAKE_SOURCE_DIR}/bridge/table)
target_compile_definitions(test_table_route PRIVATE
    TABLE_ROUTE_FIXTURE_DIR="${CMAKE_SOURCE_DIR}/tests/fixtures"
)
target_link_libraries(test_table_route cosim_bridge_common)
add_test(NAME test_table_route COMMAND test_table_route)

add_executable(test_table_transport_tcp test_table_transport_tcp.c)
target_include_directories(test_table_transport_tcp PRIVATE ${CMAKE_SOURCE_DIR}/bridge/table)
target_link_libraries(test_table_transport_tcp cosim_bridge_common pthread)
add_test(NAME test_table_transport_tcp COMMAND test_table_transport_tcp)
set_tests_properties(test_table_transport_tcp PROPERTIES TIMEOUT 15)

add_executable(test_table_ctrl_core test_table_ctrl_core.c)
target_include_directories(test_table_ctrl_core PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/qemu
    ${CMAKE_SOURCE_DIR}/bridge/table
)
target_link_libraries(test_table_ctrl_core cosim_bridge_common pthread)
add_test(NAME test_table_ctrl_core COMMAND test_table_ctrl_core)
set_tests_properties(test_table_ctrl_core PROPERTIES TIMEOUT 10)

add_executable(test_table_read_decode test_table_read_decode.c)
target_include_directories(test_table_read_decode PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/qemu
    ${CMAKE_SOURCE_DIR}/bridge/table
)
target_link_libraries(test_table_read_decode cosim_bridge_common pthread)
add_test(NAME test_table_read_decode COMMAND test_table_read_decode)
set_tests_properties(test_table_read_decode PROPERTIES TIMEOUT 10)

add_executable(test_table_lifecycle test_table_lifecycle.c)
target_include_directories(test_table_lifecycle PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/qemu
    ${CMAKE_SOURCE_DIR}/bridge/table
)
target_link_libraries(test_table_lifecycle pthread)
add_test(NAME test_table_lifecycle COMMAND test_table_lifecycle)
set_tests_properties(test_table_lifecycle PROPERTIES TIMEOUT 10)

add_executable(test_table_vcs_core test_table_vcs_core.c)
target_include_directories(test_table_vcs_core PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/table
    ${CMAKE_SOURCE_DIR}/bridge/vcs
)
target_compile_definitions(test_table_vcs_core PRIVATE
    TABLE_ROUTE_FIXTURE="${CMAKE_SOURCE_DIR}/tests/fixtures/table_routes_valid.ini"
)
target_link_libraries(test_table_vcs_core
    cosim_bridge_vcs cosim_bridge_common pthread
)
set_target_properties(test_table_vcs_core PROPERTIES ENABLE_EXPORTS ON)
add_test(NAME test_table_vcs_core COMMAND test_table_vcs_core)
set_tests_properties(test_table_vcs_core PROPERTIES TIMEOUT 20)

add_executable(test_table_vcs_alloc
    test_table_vcs_alloc.c
    ${CMAKE_SOURCE_DIR}/bridge/vcs/table_vcs_core.c
)
target_include_directories(test_table_vcs_alloc PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/table
    ${CMAKE_SOURCE_DIR}/bridge/vcs
)
target_compile_definitions(test_table_vcs_alloc PRIVATE TABLE_VCS_TESTING=1)
target_link_libraries(test_table_vcs_alloc cosim_bridge_common pthread)
add_test(NAME test_table_vcs_alloc COMMAND test_table_vcs_alloc)

add_executable(test_bridge_wait_hooks test_bridge_wait_hooks.c)
target_link_libraries(test_bridge_wait_hooks cosim_bridge pthread)
add_test(NAME test_bridge_wait_hooks COMMAND test_bridge_wait_hooks)
set_tests_properties(test_bridge_wait_hooks PROPERTIES TIMEOUT 10)

add_executable(test_bridge_tag_bits test_bridge_tag_bits.c)
target_link_libraries(test_bridge_tag_bits cosim_bridge)
add_test(NAME test_bridge_tag_bits COMMAND test_bridge_tag_bits)

add_executable(test_cosim_topology test_cosim_topology.c)
target_link_libraries(test_cosim_topology cosim_bridge_common)
add_test(NAME test_cosim_topology COMMAND test_cosim_topology)

add_executable(test_cosim_mmio_be test_cosim_mmio_be.c)
target_include_directories(test_cosim_mmio_be PRIVATE ${CMAKE_SOURCE_DIR}/qemu-plugin)
add_test(NAME test_cosim_mmio_be COMMAND test_cosim_mmio_be)

add_executable(test_cosim_pcie_request test_cosim_pcie_request.c)
target_include_directories(test_cosim_pcie_request PRIVATE ${CMAKE_SOURCE_DIR}/qemu-plugin)
target_link_libraries(test_cosim_pcie_request cosim_bridge_common)
add_test(NAME test_cosim_pcie_request COMMAND test_cosim_pcie_request)
