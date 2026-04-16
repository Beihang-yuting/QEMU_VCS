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
