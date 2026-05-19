@{
    Images = @{
        'rpios-bookworm-arm64-lite' = @{
            Url              = 'https://downloads.raspberrypi.com/raspios_oldstable_lite_arm64/images/raspios_oldstable_lite_arm64-2025-11-24/2025-11-24-raspios-bookworm-arm64-lite.img.xz'
            Checksum         = 'e6a69b5a5a8cd4afc0e9dbdc8404f6fed7c93e0d1796f438e7c780e0eac2d482'
            Algorithm        = 'SHA256'
        }
    }
    NodeImageMap = @{
        'pi-zero-dns' = 'rpios-bookworm-arm64-lite'
    }
    # Maps node type to cloud-init template filename in cloud-init/
    NodeConfigMap = @{
        'pi-zero-dns' = 'pi-zero-dns.yml'
    }
    # Optional. The flash script does not pin a static IP by default - we recommend
    # a DHCP reservation on the router so the appliance keeps a stable address
    # without baking it into cloud-init. Add entries here if you prefer a static IP.
    BaseIpMap = @{}
}
