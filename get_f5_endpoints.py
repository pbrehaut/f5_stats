#!/usr/bin/env python3
"""Extract F5 endpoint data (VIPs, floating self-IPs, non-floating self-IPs)
from one or more BIG-IP UCS archives or pre-loaded F5StanzaCollection objects
and write the combined result to a JSON file.

Typical usage (path-based)::

    from get_f5_endpoints import generate_endpoint_json
    from pathlib import Path

    output = generate_endpoint_json(
        sources=[Path("D9FUJIO6.ucs"), Path("D9HMDCO6.ucs")],
        output_filename="test_data.json",
    )
    print(f"Written to {output}")

Typical usage (pre-loaded collections)::

    from get_f5_endpoints import generate_endpoint_json

    output = generate_endpoint_json(
        sources=[("device_a", collection_a), ("device_b", collection_b)],
        output_filename="test_data.json",
    )
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path
from typing import Sequence, Union

from config_parser.f5.collection import F5StanzaCollection
from config_parser.f5.ucs import UCS

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

PathSources = Sequence[Path]
CollectionSources = Sequence[tuple[str, F5StanzaCollection]]
Sources = Union[PathSources, CollectionSources]


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

def _extract_endpoints(name: str, collection: F5StanzaCollection) -> dict:
    """Extract VIP, floating self-IP and non-floating self-IP data from *collection*.

    Args:
        name: Logical device name used as the top-level key in the output dict.
        collection: Initialised :class:`F5StanzaCollection` to interrogate.

    Returns:
        Dict with keys ``vips``, ``float_ips``, and ``non_float_ips``.
    """
    return {
        "vips": {
            x.name: {
                "ip": x.parsed_config.get("ip_address"),
                "port": x.parsed_config.get("port"),
            }
            for x in collection.filter(("ltm", "virtual"))
        },
        "float_ips": {
            x.name: {"ip": x.ip_rd[0].split("/")[0]}
            for x in collection.filter(("net", "self"))
            if x.parsed_config.get("traffic-group") == "/Common/traffic-group-1"
        },
        "non_float_ips": {
            x.name: {"ip": x.ip_rd[0].split("/")[0]}
            for x in collection.filter(("net", "self"))
            if x.parsed_config.get("traffic-group")
            == "/Common/traffic-group-local-only"
        },
    }


def _iter_collections(
    sources: Sources,
) -> list[tuple[str, F5StanzaCollection]]:
    """Resolve *sources* into ``(name, collection)`` pairs.

    Accepts either a sequence of :class:`~pathlib.Path` objects (each UCS
    archive is opened and loaded) or a sequence of
    ``(name, F5StanzaCollection)`` tuples (used as-is).  Mixed sequences are
    not supported; the type is inferred from the first element.

    Args:
        sources: Either :data:`PathSources` or :data:`CollectionSources`.

    Returns:
        List of ``(name, collection)`` pairs ready for extraction.

    Raises:
        TypeError: If *sources* is empty or contains an unsupported element type.
        ValueError: If *sources* is an empty sequence.
    """
    if not sources:
        raise ValueError("'sources' must not be empty.")

    first = sources[0]

    if isinstance(first, Path):
        pairs: list[tuple[str, F5StanzaCollection]] = []
        for path in sources:
            if not isinstance(path, Path):
                raise TypeError(
                    "All elements of 'sources' must be Path objects when the "
                    f"first element is a Path; got {type(path).__name__!r}."
                )
            with UCS(path) as ucs:
                pairs.append((path.stem, ucs.load_collection()))
        return pairs

    if isinstance(first, tuple):
        result: list[tuple[str, F5StanzaCollection]] = []
        for item in sources:
            if not isinstance(item, tuple) or len(item) != 2:
                raise TypeError(
                    "All elements of 'sources' must be (name, F5StanzaCollection) "
                    f"tuples when the first element is a tuple; got {item!r}."
                )
            name, collection = item
            result.append((name, collection))
        return result

    raise TypeError(
        f"Unsupported source type {type(first).__name__!r}. "
        "Expected Path or (name, F5StanzaCollection) tuple."
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_endpoint_json(
    sources: Sources,
    output_filename: str,
) -> Path:
    """Extract F5 endpoint data from *sources* and write it to *output_filename*.

    Accepts either a sequence of :class:`~pathlib.Path` objects pointing at
    UCS archives (which are opened and loaded internally) **or** a sequence of
    ``(name, F5StanzaCollection)`` tuples for collections that have already
    been loaded.  Mixed sequences are not supported.

    The output file is written relative to the current working directory unless
    *output_filename* is an absolute path.

    Args:
        sources: A sequence of :class:`~pathlib.Path` objects **or** a sequence
            of ``(name, F5StanzaCollection)`` tuples.  Must not be empty.
        output_filename: Filename (or relative/absolute path) for the JSON
            output.  Relative paths are resolved against :func:`Path.cwd`.

    Returns:
        The resolved :class:`~pathlib.Path` of the written JSON file.

    Raises:
        ValueError: If *sources* is empty.
        TypeError: If *sources* contains mixed or unsupported element types.

    Example::

        path = generate_endpoint_json(
            sources=[Path("device_a.ucs"), Path("device_b.ucs")],
            output_filename="test_data.json",
        )
    """
    pairs = _iter_collections(sources)

    test_data: dict = defaultdict(dict)
    for name, collection in pairs:
        test_data[name] = _extract_endpoints(name, collection)

    output_path = Path(output_filename)
    if not output_path.is_absolute():
        output_path = Path.cwd() / output_path

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as fh:
        json.dump(test_data, fh, indent=4)

    return output_path


# ---------------------------------------------------------------------------
# Script entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Run endpoint extraction with UCS files."""
    ucs_dir = Path(__file__).parent / "UCS"
    ucs_files = [
        ucs_dir / "UCS_A.ucs",
        ucs_dir / "UCS_B.ucs",
    ]
    output = generate_endpoint_json(
        sources=ucs_files,
        output_filename=str(Path(__file__).parent / "UCS" / "endpoint_data.json"),
    )
    print(f"Endpoint data written to: {output}")


if __name__ == "__main__":
    main()
