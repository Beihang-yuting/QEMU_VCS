#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "cosim_pcie_request.h"

static void test_bdf_keeps_full_devfn(void)
{
    uint16_t pf0 = cosim_pcie_bdf(1, 0);
    uint16_t pf8 = cosim_pcie_bdf(1, 8);

    assert(pf0 == 0x0100);
    assert(pf8 == 0x0108);
    assert(pf8 != pf0);
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

    assert(req.requester_id == 0x0000);
    assert(req.target_bdf == 0x0108);
    assert(req.type == TLP_MRD);
    assert(req.addr == UINT64_C(0x123456789abcdef0));
    assert(req.len == 8);
    assert(req.first_be == 0x3);
    assert(req.last_be == 0xc);
    assert(req.data[0] == 0xff);
}

int main(void)
{
    test_bdf_keeps_full_devfn();
    test_host_route_sets_rc_requester_and_target_only();
    return 0;
}
