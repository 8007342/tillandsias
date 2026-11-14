//! Refuse destinations that are not the public internet. Applied to EVERY
//! address a name resolves to, after resolving and before connecting, and the
//! connection is then pinned to an address that passed — so a DNS answer that
//! changes between check and connect (rebinding) cannot reach the enclave,
//! the host or a cloud metadata service.
//!
//! @trace spec:proxy-container, order:2041-csm4

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Why an address is refused, or `None` when it is public.
pub fn refusal(ip: IpAddr) -> Option<&'static str> {
    match ip {
        IpAddr::V4(v4) => refusal_v4(v4),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return refusal_v4(v4);
            }
            refusal_v6(v6)
        }
    }
}

fn refusal_v4(ip: Ipv4Addr) -> Option<&'static str> {
    let o = ip.octets();
    if ip.is_loopback() {
        Some("loopback")
    } else if ip.is_unspecified() || o[0] == 0 {
        Some("unspecified")
    } else if o == [169, 254, 169, 254] || o == [100, 100, 100, 200] {
        Some("metadata")
    } else if ip.is_link_local() {
        Some("link-local")
    } else if ip.is_private() {
        Some("private")
    } else if o[0] == 100 && (64..128).contains(&o[1]) {
        Some("shared-cgnat")
    } else if o[0] == 192 && o[1] == 0 && o[2] == 0 {
        Some("ietf-reserved")
    } else if (o[0] == 192 && o[1] == 0 && o[2] == 2)
        || (o[0] == 198 && o[1] == 51 && o[2] == 100)
        || (o[0] == 203 && o[1] == 0 && o[2] == 113)
        || (o[0] == 198 && (18..20).contains(&o[1]))
    {
        Some("documentation-or-benchmark")
    } else if ip.is_multicast() || ip.is_broadcast() || o[0] >= 240 {
        Some("reserved")
    } else {
        None
    }
}

fn refusal_v6(ip: Ipv6Addr) -> Option<&'static str> {
    let s = ip.segments();
    if ip.is_loopback() {
        Some("loopback")
    } else if ip.is_unspecified() {
        Some("unspecified")
    } else if (s[0] & 0xfe00) == 0xfc00 {
        Some("unique-local")
    } else if (s[0] & 0xffc0) == 0xfe80 {
        Some("link-local")
    } else if ip.is_multicast() {
        Some("reserved")
    } else if s[0] == 0x0064 && s[1] == 0xff9b {
        // NAT64 embeds an IPv4 address; judge that.
        let v4 = Ipv4Addr::new((s[6] >> 8) as u8, s[6] as u8, (s[7] >> 8) as u8, s[7] as u8);
        refusal_v4(v4)
    } else if s[0] == 0x2001 && s[1] == 0x0db8 {
        Some("documentation-or-benchmark")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(s: &str) -> Option<&'static str> {
        refusal(s.parse().unwrap())
    }

    #[test]
    fn refuses_non_public() {
        for (ip, why) in [
            ("127.0.0.1", "loopback"),
            ("10.0.42.40", "private"),
            ("172.16.0.1", "private"),
            ("192.168.1.1", "private"),
            ("169.254.169.254", "metadata"),
            ("169.254.1.1", "link-local"),
            ("100.64.0.1", "shared-cgnat"),
            ("0.0.0.0", "unspecified"),
            ("224.0.0.1", "reserved"),
            ("::1", "loopback"),
            ("::ffff:127.0.0.1", "loopback"),
            ("::ffff:10.1.2.3", "private"),
            ("fd12::1", "unique-local"),
            ("fe80::1", "link-local"),
            ("fd00::254", "unique-local"),
            ("64:ff9b::a9fe:a9fe", "metadata"),
        ] {
            assert_eq!(r(ip), Some(why), "{ip}");
        }
    }

    #[test]
    fn admits_public() {
        for ip in [
            "151.101.1.69",
            "8.8.8.8",
            "2606:4700::1111",
            "::ffff:1.1.1.1",
        ] {
            assert_eq!(r(ip), None, "{ip}");
        }
    }
}
