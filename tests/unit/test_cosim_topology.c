#include "cosim_topology.h"

#include "test_check.h"
#include <stdint.h>
#include <stdio.h>

static void test_single_bus_16pf_240vf(void)
{
    uint8_t seen[256] = {0};
    const uint16_t base = 0x0200;

    CHECK(cosim_single_bus_profile_fits(0, 16, 15));
    CHECK(!cosim_single_bus_profile_fits(0, 16, 16));

    for (unsigned pf = 0; pf < 16; pf++) {
        uint16_t rid = cosim_pf_rid(base, pf);
        CHECK((rid >> 8) == (base >> 8));
        CHECK(seen[rid & 0xff]++ == 0);
    }

    for (unsigned pf = 0; pf < 16; pf++) {
        uint16_t pf_rid = cosim_pf_rid(base, pf);
        for (unsigned vf = 0; vf < 15; vf++) {
            uint16_t rid = cosim_vf_rid(pf_rid, 16, 16, vf);
            CHECK((rid >> 8) == (base >> 8));
            CHECK(seen[rid & 0xff]++ == 0);
        }
    }

    for (unsigned devfn = 0; devfn < 256; devfn++) {
        CHECK(seen[devfn] == 1);
    }
    CHECK(cosim_pf_rid(base, 15) == 0x020f);
    CHECK(cosim_vf_rid(0x020f, 16, 16, 14) == 0x02ff);
}

static void test_legacy_single_pf_16vf(void)
{
    CHECK(cosim_single_bus_profile_fits(0, 1, 16));
    CHECK(cosim_pf_rid(0x0300, 0) == 0x0300);
    CHECK(cosim_vf_rid(0x0300, 1, 1, 15) == 0x0310);
}

static void test_dpu_pf_topology_fields(void)
{
    topology_resp_t topology = {0};

    for (unsigned pf = 0; pf < 4; pf++) {
        pf_topology_t *entry = &topology.pfs[pf];

        entry->device_id = (uint16_t)(0x5011u + pf);
        entry->pf_bar_flags[0] = 0x0c;
        entry->pf_bar_flags[2] = 0x0c;
        entry->pf_bar_flags[4] = 0x0c;

        CHECK(entry->device_id == 0x5011u + pf);
        CHECK(entry->pf_bar_flags[0] == 0x0c);
        CHECK(entry->pf_bar_flags[2] == 0x0c);
        CHECK(entry->pf_bar_flags[4] == 0x0c);
    }
}

int main(void)
{
    CHECK(sizeof(pf_topology_t) == 136);
    CHECK(sizeof(topology_resp_t) == 2180);
    test_single_bus_16pf_240vf();
    test_legacy_single_pf_16vf();
    test_dpu_pf_topology_fields();
    puts("PASS: cosim single-bus topology profiles");
    return 0;
}
