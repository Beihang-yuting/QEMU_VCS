#include "test_check.h"
#include <stdint.h>
#include <string.h>

#include "cosim_pcie_request.h"

static void test_bdf_keeps_full_devfn(void)
{
    uint16_t pf0 = cosim_pcie_bdf(1, 0);
    uint16_t pf8 = cosim_pcie_bdf(1, 8);

    CHECK(pf0 == 0x0100);
    CHECK(pf8 == 0x0108);
    CHECK(pf8 != pf0);
}

static void test_host_route_sets_rc_requester_and_target_only(void)
{
    tlp_entry_t req;

    memset(&req, 0xff, sizeof(req));
    req.type = TLP_MRD;
    req.addr = UINT64_C(0x123456789abcdef0);
    req.len = 8;
    req.first_be = 0x3;
    req.last_be = 0xc;

    cosim_route_host_to_device(&req, 0x0108);

    CHECK(req.requester_id == 0x0000);
    CHECK(req.target_bdf == 0x0108);
    CHECK(req.type == TLP_MRD);
    CHECK(req.addr == UINT64_C(0x123456789abcdef0));
    CHECK(req.len == 8);
    CHECK(req.first_be == 0x3);
    CHECK(req.last_be == 0xc);
    CHECK(req.data[0] == 0xff);
}

static void test_sc_completion_decodes_little_endian_by_size(void)
{
    static const uint8_t payload[8] = {
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    };
    static const unsigned sizes[] = { 1, 2, 4, 8 };
    static const uint64_t expected[] = {
        UINT64_C(0x08),
        UINT64_C(0x0708),
        UINT64_C(0x05060708),
        UINT64_C(0x0102030405060708),
    };

    for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        uint64_t value = UINT64_MAX;

        CHECK(cosim_cpl_value_decode(COSIM_CPL_STATUS_SC, payload,
                                      sizes[i], &value));
        CHECK(value == expected[i]);
    }
}

static void test_non_sc_completion_does_not_read_poisoned_payload(void)
{
    static const uint8_t statuses[] = {
        COSIM_CPL_STATUS_UR,
        COSIM_CPL_STATUS_CRS,
        COSIM_CPL_STATUS_CA,
        3,
        UINT8_MAX,
    };
    const uint8_t *poisoned_payload = (const uint8_t *)(uintptr_t)1;

    for (unsigned i = 0; i < sizeof(statuses) / sizeof(statuses[0]); i++) {
        uint64_t value = 0;

        CHECK(!cosim_cpl_value_decode(statuses[i], poisoned_payload, 8,
                                       &value));
        CHECK(value == UINT64_MAX);
    }
}

int main(void)
{
    test_bdf_keeps_full_devfn();
    test_host_route_sets_rc_requester_and_target_only();
    test_sc_completion_decodes_little_endian_by_size();
    test_non_sc_completion_does_not_read_poisoned_payload();
    return 0;
}
