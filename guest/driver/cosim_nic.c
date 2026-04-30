// SPDX-License-Identifier: GPL-2.0
/*
 * cosim_nic -- CoSim Platform stub NIC driver
 *
 * Provides:
 *   - PCI driver for cosim PF/VF devices (default VID:DID = abcd:1234)
 *   - SR-IOV sriov_configure callback (PF only)
 *   - Basic netdev with deterministic MAC
 *
 * Module parameters:
 *   vid=0xABCD  -- override vendor ID
 *   did=0x1234  -- override device ID
 *   vf_did=0x1235 -- override VF device ID
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/io.h>

#define DRV_NAME    "cosim_nic"
#define DRV_VERSION "1.0"

static unsigned int vid = 0xabcd;
static unsigned int did = 0x1234;
static unsigned int vf_did = 0x1235;
module_param(vid, uint, 0444);
module_param(did, uint, 0444);
module_param(vf_did, uint, 0444);
MODULE_PARM_DESC(vid, "PCI Vendor ID to match (default 0xabcd)");
MODULE_PARM_DESC(did, "PCI Device ID to match (default 0x1234)");
MODULE_PARM_DESC(vf_did, "VF PCI Device ID to match (default 0x1235)");

struct cosim_nic {
	struct pci_dev  *pdev;
	struct net_device *netdev;
	void __iomem    *bar0;
	bool             is_vf;
	struct list_head  sw_list;  /* software switch port list */
};

static int cosim_sriov_configure(struct pci_dev *dev, int num_vfs);

/* ========== Software switch (all cosim_nic ports) ========== */

static LIST_HEAD(cosim_sw_ports);
static DEFINE_SPINLOCK(cosim_sw_lock);

static struct net_device *cosim_sw_lookup_dst(const unsigned char *dmac,
					      struct net_device *src)
{
	struct cosim_nic *p;

	/* Broadcast/multicast: pick first port that isn't src */
	if (is_multicast_ether_addr(dmac)) {
		list_for_each_entry(p, &cosim_sw_ports, sw_list)
			if (p->netdev != src && netif_running(p->netdev))
				return p->netdev;
		return NULL;
	}

	/* Unicast: match destination MAC */
	list_for_each_entry(p, &cosim_sw_ports, sw_list)
		if (p->netdev != src && ether_addr_equal(p->netdev->dev_addr, dmac))
			return p->netdev;
	return NULL;
}

/* ========== Net device ops ========== */

static int cosim_open(struct net_device *ndev)
{
	netif_start_queue(ndev);
	return 0;
}

static int cosim_stop(struct net_device *ndev)
{
	netif_stop_queue(ndev);
	return 0;
}

static netdev_tx_t cosim_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct net_device *dst;
	struct sk_buff *nskb;

	ndev->stats.tx_packets++;
	ndev->stats.tx_bytes += skb->len;

	/* Software switch: forward to destination port by MAC lookup */
	spin_lock(&cosim_sw_lock);
	dst = cosim_sw_lookup_dst(eth_hdr(skb)->h_dest, ndev);
	if (dst) {
		nskb = skb_clone(skb, GFP_ATOMIC);
		if (nskb) {
			nskb->dev = dst;
			nskb->protocol = eth_type_trans(nskb, dst);
			nskb->ip_summed = CHECKSUM_UNNECESSARY;
			dst->stats.rx_packets++;
			dst->stats.rx_bytes += nskb->len;
			spin_unlock(&cosim_sw_lock);
			netif_rx(nskb);
		} else {
			spin_unlock(&cosim_sw_lock);
		}
	} else {
		/* Broadcast: flood to all other ports */
		struct cosim_nic *p;

		list_for_each_entry(p, &cosim_sw_ports, sw_list) {
			if (p->netdev == ndev || !netif_running(p->netdev))
				continue;
			nskb = skb_clone(skb, GFP_ATOMIC);
			if (!nskb)
				continue;
			nskb->dev = p->netdev;
			nskb->protocol = eth_type_trans(nskb, p->netdev);
			nskb->ip_summed = CHECKSUM_UNNECESSARY;
			p->netdev->stats.rx_packets++;
			p->netdev->stats.rx_bytes += nskb->len;
			netif_rx(nskb);
		}
		spin_unlock(&cosim_sw_lock);
	}

	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static const struct net_device_ops cosim_netdev_ops = {
	.ndo_open       = cosim_open,
	.ndo_stop       = cosim_stop,
	.ndo_start_xmit = cosim_xmit,
};

/* ========== PCI probe / remove ========== */

static int cosim_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct cosim_nic *priv;
	struct net_device *ndev;
	int err;
	bool is_vf = pdev->is_virtfn;

	err = pci_enable_device(pdev);
	if (err)
		return err;

	err = pci_request_regions(pdev, DRV_NAME);
	if (err)
		goto err_disable;

	pci_set_master(pdev);

	ndev = alloc_etherdev(sizeof(struct cosim_nic));
	if (!ndev) {
		err = -ENOMEM;
		goto err_regions;
	}

	SET_NETDEV_DEV(ndev, &pdev->dev);
	priv = netdev_priv(ndev);
	priv->pdev = pdev;
	priv->netdev = ndev;
	priv->is_vf = is_vf;

	ndev->netdev_ops = &cosim_netdev_ops;

	/* Deterministic MAC from BDF (use dev_addr_set for kernel 5.15+) */
	{
		u8 addr[ETH_ALEN];

		eth_random_addr(addr);
		addr[0] &= 0xfe;  /* unicast */
		addr[0] |= 0x02;  /* locally administered */
		addr[4] = PCI_SLOT(pdev->devfn);
		addr[5] = PCI_FUNC(pdev->devfn);
		dev_addr_set(ndev, addr);
	}

	/* Map BAR0 if present */
	if (pci_resource_len(pdev, 0) > 0) {
		priv->bar0 = pci_iomap(pdev, 0, 0);
		if (!priv->bar0)
			dev_warn(&pdev->dev, "BAR0 iomap failed\n");
	}

	err = register_netdev(ndev);
	if (err)
		goto err_unmap;

	pci_set_drvdata(pdev, priv);

	/* Register in software switch port list */
	spin_lock(&cosim_sw_lock);
	list_add_tail(&priv->sw_list, &cosim_sw_ports);
	spin_unlock(&cosim_sw_lock);

	dev_info(&pdev->dev, "%s: %s %s (BDF %04x:%02x:%02x.%x)\n",
		 ndev->name, is_vf ? "VF" : "PF", DRV_NAME,
		 pci_domain_nr(pdev->bus), pdev->bus->number,
		 PCI_SLOT(pdev->devfn), PCI_FUNC(pdev->devfn));

	return 0;

err_unmap:
	if (priv->bar0)
		pci_iounmap(pdev, priv->bar0);
	free_netdev(ndev);
err_regions:
	pci_release_regions(pdev);
err_disable:
	pci_disable_device(pdev);
	return err;
}

static void cosim_remove(struct pci_dev *pdev)
{
	struct cosim_nic *priv = pci_get_drvdata(pdev);

	if (!priv)
		return;

	/* Remove from software switch */
	spin_lock(&cosim_sw_lock);
	list_del(&priv->sw_list);
	spin_unlock(&cosim_sw_lock);

	if (!priv->is_vf && pdev->is_physfn)
		pci_disable_sriov(pdev);

	unregister_netdev(priv->netdev);
	if (priv->bar0)
		pci_iounmap(pdev, priv->bar0);
	free_netdev(priv->netdev);
	pci_release_regions(pdev);
	pci_disable_device(pdev);
}

/* ========== SR-IOV ========== */

static int cosim_sriov_configure(struct pci_dev *dev, int num_vfs)
{
	if (num_vfs > 0) {
		int ret;

		dev_info(&dev->dev, "Enabling %d VFs\n", num_vfs);
		ret = pci_enable_sriov(dev, num_vfs);
		if (ret)
			return ret;
		return num_vfs;  /* sriov_configure must return count on success */
	}

	dev_info(&dev->dev, "Disabling VFs\n");
	pci_disable_sriov(dev);
	return 0;
}

/* ========== PCI ID table ========== */

static struct pci_device_id cosim_id_table[] = {
	{ PCI_DEVICE(0xabcd, 0x1234) },  /* PF -- overridden in init */
	{ PCI_DEVICE(0xabcd, 0x1235) },  /* VF -- overridden in init */
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, cosim_id_table);

static struct pci_driver cosim_pci_driver = {
	.name           = DRV_NAME,
	.id_table       = cosim_id_table,
	.probe          = cosim_probe,
	.remove         = cosim_remove,
	.sriov_configure = cosim_sriov_configure,
};

static int __init cosim_nic_init(void)
{
	cosim_id_table[0].vendor = vid;
	cosim_id_table[0].device = did;
	cosim_id_table[1].vendor = vid;
	cosim_id_table[1].device = vf_did;

	pr_info(DRV_NAME ": v" DRV_VERSION " (PF %04x:%04x, VF %04x:%04x)\n",
		vid, did, vid, vf_did);

	return pci_register_driver(&cosim_pci_driver);
}

static void __exit cosim_nic_exit(void)
{
	pci_unregister_driver(&cosim_pci_driver);
}

module_init(cosim_nic_init);
module_exit(cosim_nic_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("CoSim Platform");
MODULE_DESCRIPTION("Stub NIC driver for QEMU-VCS CoSim with SR-IOV support");
MODULE_VERSION(DRV_VERSION);
