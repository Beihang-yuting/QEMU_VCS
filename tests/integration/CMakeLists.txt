add_executable(test_sock_sync test_sock_sync.c)
target_link_libraries(test_sock_sync cosim_bridge)
add_test(NAME test_sock_sync COMMAND test_sock_sync)

add_executable(test_bridge_loopback test_bridge_loopback.c)
target_link_libraries(test_bridge_loopback cosim_bridge)
add_test(NAME test_bridge_loopback COMMAND test_bridge_loopback)

add_executable(test_bridge_completion_status test_bridge_completion_status.c)
target_link_libraries(test_bridge_completion_status
                      cosim_bridge cosim_bridge_vcs pthread)
add_test(NAME test_bridge_completion_status COMMAND test_bridge_completion_status)
set_tests_properties(test_bridge_completion_status PROPERTIES TIMEOUT 20)

add_executable(test_dma_roundtrip test_dma_roundtrip.c)
target_link_libraries(test_dma_roundtrip cosim_bridge cosim_bridge_common)
add_test(NAME test_dma_roundtrip COMMAND test_dma_roundtrip)

add_executable(test_msi_roundtrip test_msi_roundtrip.c)
target_link_libraries(test_msi_roundtrip cosim_bridge)
add_test(NAME test_msi_roundtrip COMMAND test_msi_roundtrip)

add_executable(test_precise_mode test_precise_mode.c)
target_link_libraries(test_precise_mode cosim_bridge)
add_test(NAME test_precise_mode COMMAND test_precise_mode)

add_test(NAME test_offline_qemu_archive
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_offline_qemu_archive.sh)
set_tests_properties(test_offline_qemu_archive PROPERTIES TIMEOUT 30)

add_test(NAME test_offline_ubuntu_server
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_offline_ubuntu_server.sh)
set_tests_properties(test_offline_ubuntu_server PROPERTIES TIMEOUT 60)

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

add_test(NAME test_qemu_time_mode
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_time_mode.sh)
set_tests_properties(test_qemu_time_mode PROPERTIES TIMEOUT 10)

add_test(NAME test_qemu_wait_gate_source
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_wait_gate_source.sh)
set_tests_properties(test_qemu_wait_gate_source PROPERTIES TIMEOUT 10)

add_test(NAME test_qemu_management_nic
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_management_nic.sh)
set_tests_properties(test_qemu_management_nic PROPERTIES TIMEOUT 10)

add_test(NAME test_guest_ssh_provisioning
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_guest_ssh_provisioning.sh)
set_tests_properties(test_guest_ssh_provisioning PROPERTIES TIMEOUT 10)

add_test(NAME test_ubuntu_server_profile
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_ubuntu_server_profile.sh)
set_tests_properties(test_ubuntu_server_profile PROPERTIES TIMEOUT 30)

add_test(NAME test_workflow_command_contracts
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_workflow_command_contracts.sh)
set_tests_properties(test_workflow_command_contracts PROPERTIES TIMEOUT 10)

add_test(NAME test_inject_modules_debugfs_paths
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_inject_modules_debugfs_paths.sh)
set_tests_properties(test_inject_modules_debugfs_paths PROPERTIES TIMEOUT 30)

# QEMU PCIe topology and REAL_DUT config-bypass source policy.
add_test(NAME test_pcie_launch_topology
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_pcie_launch_topology.sh)
set_tests_properties(test_pcie_launch_topology PROPERTIES TIMEOUT 10)

add_test(NAME test_qemu_request_routing_source
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_request_routing_source.sh)
set_tests_properties(test_qemu_request_routing_source PROPERTIES TIMEOUT 10)

add_test(NAME test_runtime_bdf_utils
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_runtime_bdf_utils.sh)
set_tests_properties(test_runtime_bdf_utils PROPERTIES TIMEOUT 120)

add_test(NAME test_dpu_501x_profile
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_dpu_501x_profile.sh)
set_tests_properties(test_dpu_501x_profile PROPERTIES TIMEOUT 120)

add_test(NAME test_cosim_cpl_payload_codec
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_cosim_cpl_payload_codec.sh)
set_tests_properties(test_cosim_cpl_payload_codec PROPERTIES TIMEOUT 120)

add_test(NAME test_cosim_tag_map_order
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_cosim_tag_map_order.sh)
set_tests_properties(test_cosim_tag_map_order PROPERTIES TIMEOUT 10)

add_test(NAME test_cosim_completion_ownership
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_cosim_completion_ownership.sh)
set_tests_properties(test_cosim_completion_ownership PROPERTIES TIMEOUT 10)

add_test(NAME test_pcie_tl_env_fork_capture
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_pcie_tl_env_fork_capture.sh)
set_tests_properties(test_pcie_tl_env_fork_capture PROPERTIES TIMEOUT 10)

# TCP transport roundtrip integration test
add_executable(test_tcp_roundtrip test_tcp_roundtrip.c)
target_link_libraries(test_tcp_roundtrip cosim_bridge_common cosim_bridge pthread)
add_test(NAME test_tcp_roundtrip COMMAND test_tcp_roundtrip)
set_tests_properties(test_tcp_roundtrip PROPERTIES TIMEOUT 30)

add_test(NAME test_dpu_debugutils_build
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_debugutils_build.sh)
set_tests_properties(test_dpu_debugutils_build PROPERTIES TIMEOUT 60)

add_test(NAME test_stage_guest_debugutils
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_stage_guest_debugutils.sh)
set_tests_properties(test_stage_guest_debugutils PROPERTIES TIMEOUT 30)

add_test(NAME test_stage_guest_debugutils_hardening
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_stage_guest_debugutils_hardening.sh)
set_tests_properties(test_stage_guest_debugutils_hardening PROPERTIES TIMEOUT 60)
