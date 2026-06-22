from __future__ import annotations

from typing import Iterable, List, Sequence

from .errors import ValidationError
from .models import PortMapping


def allocate_ports(server_number: int, used_ports: Iterable[int], additional_container_ports: Sequence[int], enable_vnc: bool) -> List[PortMapping]:
    start_port = 9000 + 100 * (server_number - 1)
    end_port = 9000 + 100 * server_number - 1
    used = set(int(port) for port in used_ports)
    available = [port for port in range(start_port, end_port + 1) if port not in used]

    required = 2 + (1 if enable_vnc else 0) + len(additional_container_ports)
    if len(available) < required:
        raise ValidationError(f"not enough available ports in {start_port}-{end_port}; need {required}, have {len(available)}")

    mappings = [
        PortMapping(available.pop(0), 22, "ssh"),
        PortMapping(available.pop(0), 8888, "jupyter notebook"),
    ]
    if enable_vnc:
        mappings.append(PortMapping(available.pop(0), 6080, "vnc"))
    for container_port in additional_container_ports:
        if int(container_port) == 6080 and enable_vnc:
            continue
        mappings.append(PortMapping(available.pop(0), int(container_port), f"container port {container_port}"))
    return mappings
