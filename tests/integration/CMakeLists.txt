add_executable(test_sock_sync test_sock_sync.c)
target_link_libraries(test_sock_sync cosim_bridge)
add_test(NAME test_sock_sync COMMAND test_sock_sync)

add_executable(test_bridge_loopback test_bridge_loopback.c)
target_link_libraries(test_bridge_loopback cosim_bridge)
add_test(NAME test_bridge_loopback COMMAND test_bridge_loopback)

add_executable(test_dma_roundtrip test_dma_roundtrip.c)
target_link_libraries(test_dma_roundtrip cosim_bridge cosim_bridge_common)
add_test(NAME test_dma_roundtrip COMMAND test_dma_roundtrip)

add_executable(test_msi_roundtrip test_msi_roundtrip.c)
target_link_libraries(test_msi_roundtrip cosim_bridge)
add_test(NAME test_msi_roundtrip COMMAND test_msi_roundtrip)

add_executable(test_precise_mode test_precise_mode.c)
target_link_libraries(test_precise_mode cosim_bridge)
add_test(NAME test_precise_mode COMMAND test_precise_mode)

# cosim_cli ctypes-layer smoke test (P4-①)
add_test(NAME test_cli_smoke
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_cli_smoke.sh)
set_tests_properties(test_cli_smoke PROPERTIES TIMEOUT 10)

# P3 ETH integration tests
add_executable(test_eth_loopback test_eth_loopback.c)
target_link_libraries(test_eth_loopback cosim_eth)
add_test(NAME test_eth_loopback COMMAND test_eth_loopback)

add_executable(test_link_drop test_link_drop.c)
target_link_libraries(test_link_drop cosim_eth)
add_test(NAME test_link_drop COMMAND test_link_drop)

add_executable(test_mac_stub_e2e test_mac_stub_e2e.c)
target_link_libraries(test_mac_stub_e2e cosim_eth pthread)
add_test(NAME test_mac_stub_e2e COMMAND test_mac_stub_e2e)
set_tests_properties(test_mac_stub_e2e PROPERTIES TIMEOUT 5)

add_executable(test_time_sync_loose test_time_sync_loose.c)
target_link_libraries(test_time_sync_loose cosim_eth)
add_test(NAME test_time_sync_loose COMMAND test_time_sync_loose)

# QEMU 侧综合集成测试 (Fast/Precise 模式、时间同步、DMA/MSI)
add_executable(test_qemu_integration test_qemu_integration.c)
target_link_libraries(test_qemu_integration cosim_bridge cosim_bridge_common pthread)
add_test(NAME test_qemu_integration COMMAND test_qemu_integration)
set_tests_properties(test_qemu_integration PROPERTIES TIMEOUT 60)

# launch_dual.py smoke test (P3-T7)
add_test(NAME test_launch_smoke
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_launch_smoke.sh)
set_tests_properties(test_launch_smoke PROPERTIES TIMEOUT 15)

# TCP transport roundtrip integration test
add_executable(test_tcp_roundtrip test_tcp_roundtrip.c)
target_link_libraries(test_tcp_roundtrip cosim_bridge_common cosim_bridge pthread)
add_test(NAME test_tcp_roundtrip COMMAND test_tcp_roundtrip)
set_tests_properties(test_tcp_roundtrip PROPERTIES TIMEOUT 30)
