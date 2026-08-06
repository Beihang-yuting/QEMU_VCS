version: 
    v2.1.8

#compile
make

#run
cd bin

Usage: reg_display
-h            			Help
-s <device>   			Slot/device (as per lspci)
-b <BAR>      			Base address region (BAR) to access, eg. 0 for BAR0
-m <block name> 	  	default show all block
                               block:pp,dptx,dprx,vtx,vrx,eth,ethv2,intf,ptype,rdma,pcie,psw
-t <vtx_ring_num> 	  	vtx ring num
-r <vrx_ring_num> 	  	vrx ring num
-c 				clear cnt

#show usage
./reg_display -h

#run
./reg_display -s 01:00.0 -m <block> -r <vrx ring num> -t <vtx ring num>
e.g.
./reg_display -s 01:00.0 -r 3 -t 8
./reg_display -s 0d:00.0 -r 3 -t 8

#show eth v2 extended registers (pause/pfc/debug counters)
./reg_display -s 01:00.0 -m ethv2

#show pcie registers (BREG/DM0/DM1)
./reg_display -s 01:00.0 -m pcie

#show pcie switch registers (BREG/IPRO/MUX/PSWCFG)
./reg_display -s 01:00.0 -m psw

#combine multiple blocks
./reg_display -s 01:00.0 -m intf -m pcie -m psw

#show DROP_PKT_CNT
e.g.
./reg_display -s 01:00.0 -r 16 | grep DROP_PKT_CNT
