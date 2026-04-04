#!/usr/bin/env python3

import argparse
import ipaddress
import json
import os
import re
import shlex
import sys
from pathlib import Path


HOST_RE = re.compile(r"^(lab|farm)(\d+)$", re.IGNORECASE)
VIRTUAL_PREFIXES = (
    "br-",
    "cali",
    "cni",
    "docker",
    "flannel",
    "kube",
    "lo",
    "tap",
    "tunl",
    "veth",
    "virbr",
    "vnet",
)
PHYSICAL_PREFIXES = ("eno", "ens", "enp", "eth", "enx")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate AI-friendly server JSONL from Ansible setup facts."
    )
    parser.add_argument(
        "--facts-dir",
        default="server_info",
        help="Directory created by `ansible all -m setup --tree ...`",
    )
    parser.add_argument(
        "--topology",
        default="config/network_topology.json",
        help="Static topology and public access rules JSON file",
    )
    parser.add_argument(
        "--inventory",
        default=None,
        help="Optional Ansible inventory.ini path. Defaults to $ANSIBLE_INVENTORY if set.",
    )
    parser.add_argument(
        "--output",
        default="server_inventory/servers.jsonl",
        help="Output JSONL path",
    )
    return parser.parse_args()


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_inventory(path):
    hosts = {}
    group_vars = {}
    current_group = None
    section_kind = None

    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue

            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                if section.endswith(":vars"):
                    current_group = section[:-5]
                    section_kind = "vars"
                    group_vars.setdefault(current_group, {})
                else:
                    current_group = section
                    section_kind = "hosts"
                continue

            if current_group is None:
                continue

            if section_kind == "vars":
                if "=" in line:
                    key, value = line.split("=", 1)
                    group_vars[current_group][key.strip()] = value.strip()
                continue

            parts = shlex.split(line)
            if not parts:
                continue
            host = parts[0]
            values = {}
            for token in parts[1:]:
                if "=" not in token:
                    continue
                key, value = token.split("=", 1)
                values[key.strip()] = value.strip()
            host_entry = hosts.setdefault(host, {"group": current_group, "vars": {}})
            host_entry["group"] = current_group
            host_entry["vars"].update(values)

    for host, entry in hosts.items():
        merged = {}
        merged.update(group_vars.get(entry["group"], {}))
        merged.update(entry["vars"])
        entry["vars"] = merged

    return hosts


def host_identity(hostname):
    match = HOST_RE.match(hostname)
    if not match:
        return None
    return match.group(1).upper(), int(match.group(2))


def is_virtual_interface(name):
    return name.startswith(VIRTUAL_PREFIXES)


def is_physical_interface(name, info):
    if not isinstance(info, dict):
        return False
    if is_virtual_interface(name):
        return False
    if name.startswith(PHYSICAL_PREFIXES):
        return True
    return info.get("type") == "ether" and bool(info.get("macaddress"))


def interface_ipv4(info):
    ipv4 = info.get("ipv4")
    return ipv4 if isinstance(ipv4, dict) else {}


def ip_in_subnet(address, subnet):
    if not address or not subnet:
        return False
    return ipaddress.ip_address(address) in ipaddress.ip_network(subnet, strict=False)


def select_interface(facts, subnet):
    default_name = facts.get("ansible_default_ipv4", {}).get("interface")
    matches = []
    for name in facts.get("ansible_interfaces", []):
        info = facts.get(f"ansible_{name}")
        if not is_physical_interface(name, info):
            continue
        ipv4 = interface_ipv4(info)
        if ip_in_subnet(ipv4.get("address"), subnet):
            score = 0
            if name == default_name:
                score += 2
            if info.get("active"):
                score += 1
            matches.append((score, name, info))
    if not matches:
        return None, None
    matches.sort(key=lambda item: (-item[0], item[1]))
    _, name, info = matches[0]
    return name, info


def summarize_interface(name, info, role=None, gateway=None, network_meta=None):
    ipv4 = interface_ipv4(info)
    speed = info.get("speed")
    try:
        if speed is not None:
            speed = int(speed)
        if speed is not None and speed <= 0:
            speed = None
    except (TypeError, ValueError):
        speed = None
    summary = {
        "name": name,
        "role": role,
        "mac": info.get("macaddress"),
        "ipv4": ipv4.get("address"),
        "netmask": ipv4.get("netmask"),
        "network": ipv4.get("network"),
        "broadcast": ipv4.get("broadcast"),
        "gateway": gateway,
        "mtu": info.get("mtu"),
        "speed_mbps": speed,
        "link_up": info.get("active"),
    }
    if network_meta:
        summary.update(
            {
                "subnet": network_meta.get("subnet"),
                "switch": network_meta.get("switch"),
                "vlan": network_meta.get("vlan"),
                "topology_note": network_meta.get("topology_note"),
            }
        )
    return {key: value for key, value in summary.items() if value is not None}


def gibibytes(size_bytes):
    if size_bytes in (None, ""):
        return None
    return round(int(size_bytes) / (1024 ** 3), 1)


def summarize_root_mount(facts):
    for mount in facts.get("ansible_mounts", []):
        if mount.get("mount") == "/":
            return {
                "root_total_gb": gibibytes(mount.get("size_total")),
                "root_free_gb": gibibytes(mount.get("size_available")),
                "root_device": mount.get("device"),
            }
    return {
        "root_total_gb": None,
        "root_free_gb": None,
        "root_device": None,
    }


def build_inventory_record(hostname, server_no, domain, host_inventory, mgmt_ipv4, domain_rules):
    inventory_vars = host_inventory.get("vars", {}) if host_inventory else {}
    ansible_host = inventory_vars.get("ansible_host") or mgmt_ipv4
    ssh_port = inventory_vars.get("ansible_port")
    if ssh_port is None:
        ssh_port = domain_rules["ssh_port_rule"]["base_port"] + server_no
    ssh_port = int(ssh_port)
    ansible_user = inventory_vars.get("ansible_user") or domain_rules.get("ansible_user")

    return {
        "group": host_inventory.get("group") if host_inventory else domain,
        "ansible_host": ansible_host,
        "ansible_port": ssh_port,
        "ansible_user": ansible_user,
    }


def build_public_access(domain_rules, server_no, ssh_port=None):
    if ssh_port is None:
        ssh_port = domain_rules["ssh_port_rule"]["base_port"] + server_no
    range_start = (
        domain_rules["service_port_rule"]["base_start"]
        + (server_no - 1) * domain_rules["service_port_rule"]["block_size"]
    )
    range_end = range_start + domain_rules["service_port_rule"]["block_size"] - 1

    return {
        "public_ip": domain_rules["public_ip"],
        "ssh_port": ssh_port,
        "ssh_endpoint": f"{domain_rules['public_ip']}:{ssh_port}",
        "service_port_range": {
            "start": range_start,
            "end": range_end,
        },
        "service_port_label": f"{range_start}-{range_end}",
    }


def build_record(hostname, facts, topology, inventory_hosts):
    identity = host_identity(hostname)
    if identity is None:
        return None

    domain, server_no = identity
    domain_rules = topology["domains"][domain]
    host_inventory = inventory_hosts.get(hostname, {})

    mgmt_meta = domain_rules["management_network"]
    storage_meta = domain_rules["storage_network"]

    mgmt_name, mgmt_info = (None, None)
    storage_name, storage_info = (None, None)
    default_ipv4 = {}
    mgmt_ipv4 = None

    if facts:
        default_ipv4 = facts.get("ansible_default_ipv4", {})
        mgmt_name, mgmt_info = select_interface(facts, mgmt_meta["subnet"])
        storage_name, storage_info = select_interface(facts, storage_meta["subnet"])
        mgmt_ipv4 = interface_ipv4(mgmt_info).get("address") if mgmt_info else default_ipv4.get("address")

    inventory = build_inventory_record(
        hostname=hostname,
        server_no=server_no,
        domain=domain,
        host_inventory=host_inventory,
        mgmt_ipv4=mgmt_ipv4,
        domain_rules=domain_rules,
    )

    management = None
    storage = None
    physical_nics = []
    if facts:
        if mgmt_info:
            management = summarize_interface(
                mgmt_name,
                mgmt_info,
                role="management",
                gateway=default_ipv4.get("gateway") if mgmt_name == default_ipv4.get("interface") else None,
                network_meta=mgmt_meta,
            )
        if storage_info:
            storage = summarize_interface(
                storage_name,
                storage_info,
                role="storage",
                network_meta=storage_meta,
            )

        for name in sorted(facts.get("ansible_interfaces", [])):
            info = facts.get(f"ansible_{name}")
            if not is_physical_interface(name, info):
                continue
            role = "spare"
            if name == mgmt_name:
                role = "management"
            elif name == storage_name:
                role = "storage"
            nic_summary = summarize_interface(name, info, role=role)
            physical_nics.append(nic_summary)

    root_mount = summarize_root_mount(facts) if facts else {
        "root_total_gb": None,
        "root_free_gb": None,
        "root_device": None,
    }

    system = {
        "os": facts.get("ansible_distribution") if facts else None,
        "os_version": facts.get("ansible_distribution_version") if facts else None,
        "kernel": facts.get("ansible_kernel") if facts else None,
        "arch": facts.get("ansible_architecture") if facts else None,
        "vcpus": facts.get("ansible_processor_vcpus") if facts else None,
        "mem_gb": round(facts.get("ansible_memtotal_mb", 0) / 1024, 1) if facts and facts.get("ansible_memtotal_mb") else None,
        **root_mount,
    }

    topology_snapshot = {
        "management_network": mgmt_meta,
        "storage_network": storage_meta,
    }

    status = {
        "reachable": facts is not None,
        "last_seen": facts.get("ansible_date_time", {}).get("iso8601") if facts else None,
    }

    return {
        "host": hostname,
        "server_id": f"{domain}{server_no}",
        "domain": domain,
        "server_no": server_no,
        "inventory": inventory,
        "public_access": build_public_access(domain_rules, server_no, inventory["ansible_port"]),
        "topology": topology_snapshot,
        "networks": {
            "management": management,
            "storage": storage,
            "physical_nics": physical_nics,
        },
        "system": system,
        "status": status,
    }


def main():
    args = parse_args()
    topology = load_json(args.topology)
    inventory_path = args.inventory or os.environ.get("ANSIBLE_INVENTORY")
    inventory_hosts = {}
    if inventory_path and Path(inventory_path).is_file():
        inventory_hosts = parse_inventory(inventory_path)

    facts_dir = Path(args.facts_dir)
    facts_by_host = {}
    if facts_dir.is_dir():
        for path in facts_dir.iterdir():
            if not path.is_file():
                continue
            if host_identity(path.name) is None:
                continue
            payload = load_json(path)
            facts_by_host[path.name] = payload.get("ansible_facts")

    all_hosts = sorted(
        set(facts_by_host) | {host for host in inventory_hosts if host_identity(host) is not None},
        key=lambda hostname: (host_identity(hostname)[0], host_identity(hostname)[1]),
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as handle:
        for hostname in all_hosts:
            record = build_record(hostname, facts_by_host.get(hostname), topology, inventory_hosts)
            if record is None:
                continue
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")

    print(f"Wrote {len(all_hosts)} records to {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
