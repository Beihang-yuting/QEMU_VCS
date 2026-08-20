add_executable(test_sock_sync test_sock_sync.c)
target_link_libraries(test_sock_sync cosim_bridge)
add_test(NAME test_sock_sync COMMAND test_sock_sync)

add_executable(test_cosim_bridge_public_table_header
               test_cosim_bridge_public_table_header.c)
target_link_libraries(test_cosim_bridge_public_table_header cosim_bridge)
add_test(NAME test_cosim_bridge_public_table_header
         COMMAND test_cosim_bridge_public_table_header)

add_executable(test_table_roundtrip test_table_roundtrip.c)
target_include_directories(test_table_roundtrip PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/qemu
    ${CMAKE_SOURCE_DIR}/bridge/table
)
target_link_libraries(test_table_roundtrip cosim_bridge_common pthread)
add_test(NAME test_table_roundtrip COMMAND test_table_roundtrip)
set_tests_properties(test_table_roundtrip PROPERTIES TIMEOUT 15)

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

add_test(NAME test_table_launch_switch
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_table_launch_switch.sh)
set_tests_properties(test_table_launch_switch PROPERTIES TIMEOUT 20)

add_test(NAME test_dpu_table_overlay_apply
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_table_overlay_apply.sh)
set_tests_properties(test_dpu_table_overlay_apply PROPERTIES TIMEOUT 30)

add_test(NAME test_dpu_complete_buffer_patch
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_complete_buffer_patch.sh)
set_tests_properties(test_dpu_complete_buffer_patch PROPERTIES TIMEOUT 10)

set(DPU_TABLE_REFERENCE_ARCHIVE "" CACHE FILEPATH
    "Clean host-driver-net archive used to validate DPU release call sites")
if(DPU_TABLE_REFERENCE_ARCHIVE)
    if(NOT EXISTS "${DPU_TABLE_REFERENCE_ARCHIVE}")
        message(FATAL_ERROR
                "DPU_TABLE_REFERENCE_ARCHIVE does not exist: ${DPU_TABLE_REFERENCE_ARCHIVE}")
    endif()
    add_test(NAME test_dpu_complete_buffer_release_patch
             COMMAND bash
                     ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_complete_buffer_patch.sh
                     ${DPU_TABLE_REFERENCE_ARCHIVE})
    set_tests_properties(test_dpu_complete_buffer_release_patch
                         PROPERTIES TIMEOUT 30)
else()
    message(STATUS
            "DPU release call-site CTest disabled: set DPU_TABLE_REFERENCE_ARCHIVE")
endif()

add_test(NAME test_dpu_qid_batch_patch
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_qid_batch_patch.sh)
set_tests_properties(test_dpu_qid_batch_patch PROPERTIES TIMEOUT 10)

add_test(NAME test_dpu_table_frontdoor_throttle_patch
         COMMAND bash
                 ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_table_frontdoor_throttle_patch.sh)
set_tests_properties(test_dpu_table_frontdoor_throttle_patch
                     PROPERTIES TIMEOUT 20)

add_test(NAME test_dpu_table_batch_source_contract
         COMMAND bash
                 ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_table_batch_source_contract.sh)
set_tests_properties(test_dpu_table_batch_source_contract PROPERTIES TIMEOUT 10)

add_test(NAME test_qemu_request_routing_source
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_request_routing_source.sh)
set_tests_properties(test_qemu_request_routing_source PROPERTIES TIMEOUT 10)

add_test(NAME test_table_read_source_contract
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_table_read_source_contract.sh)
set_tests_properties(test_table_read_source_contract PROPERTIES TIMEOUT 10)

add_test(NAME test_qemu_table_target_header_closure
         COMMAND bash
                 ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_table_target_build_closure.sh
                 headers)
set_tests_properties(test_qemu_table_target_header_closure PROPERTIES TIMEOUT 20)

add_test(NAME test_qemu_table_target_link_closure
         COMMAND bash
                 ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_table_target_build_closure.sh
                 link $<TARGET_FILE:cosim_bridge>)
set_tests_properties(test_qemu_table_target_link_closure PROPERTIES TIMEOUT 20)

add_test(NAME test_qemu_table_setup_smoke
         COMMAND bash
                 ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_table_setup_smoke.sh)
set_tests_properties(test_qemu_table_setup_smoke PROPERTIES TIMEOUT 20)

set(COSIM_QEMU_BUILD_DIR "" CACHE PATH
    "QEMU build tree used by the real QOM legacy-reset registration probe")
if(COSIM_QEMU_BUILD_DIR)
    add_test(NAME test_qemu_legacy_reset_registration
             COMMAND bash
                     ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_legacy_reset_registration.sh
                     ${COSIM_QEMU_BUILD_DIR})
    set_tests_properties(test_qemu_legacy_reset_registration
                         PROPERTIES TIMEOUT 120)
endif()

add_test(NAME test_cq_bar_routing_source
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_cq_bar_routing_source.sh)
set_tests_properties(test_cq_bar_routing_source PROPERTIES TIMEOUT 10)

add_test(NAME test_runtime_bdf_utils
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_runtime_bdf_utils.sh)
set_tests_properties(test_runtime_bdf_utils PROPERTIES TIMEOUT 120)

add_test(NAME test_dpu_501x_profile
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_dpu_501x_profile.sh)
set_tests_properties(test_dpu_501x_profile PROPERTIES TIMEOUT 120)

add_test(NAME test_cosim_cpl_payload_codec
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_cosim_cpl_payload_codec.sh)
set_tests_properties(test_cosim_cpl_payload_codec PROPERTIES TIMEOUT 120)

add_test(NAME test_cosim_table_unit
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_cosim_table_unit.sh)
set_tests_properties(test_cosim_table_unit PROPERTIES TIMEOUT 120)

add_test(NAME test_cosim_table_service
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_cosim_table_service.sh)
set_tests_properties(test_cosim_table_service PROPERTIES TIMEOUT 120)

add_test(NAME test_cosim_table_runtime
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_cosim_table_runtime.sh)
set_tests_properties(test_cosim_table_runtime PROPERTIES TIMEOUT 300)

add_test(NAME test_cosim_table_multiram
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/../sv/run_test_cosim_table_multiram.sh)
set_tests_properties(test_cosim_table_multiram PROPERTIES TIMEOUT 180)

add_test(NAME test_table_xrc_source_contract
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_table_xrc_source_contract.sh)
set_tests_properties(test_table_xrc_source_contract PROPERTIES TIMEOUT 10)

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
