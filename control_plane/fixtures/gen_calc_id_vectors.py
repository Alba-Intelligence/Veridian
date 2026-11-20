"""Independent generator for the frozen calc_id vectors (scheme sha256_v1).

Written from the layout documented in lib/veridian/calc_id.ex, not from the
Elixir code, so it is a second implementation. Run once; the output
calc_id_v1_vectors.json is committed and must never change (D-041): a change
means a new hash scheme, not an edit.

    python3 -I fixtures/gen_calc_id_vectors.py > fixtures/calc_id_v1_vectors.json
"""
import hashlib
import json
import struct
from datetime import datetime, timezone

DOMAIN = b"veridian/calc_id/sha256_v1"


def ident(kind, seed):
    digest = hashlib.sha256(seed.encode()).digest()
    return f"{kind}/sha256_v1/{digest.hex()}"


def field(b):
    return struct.pack(">Q", len(b)) + b


def ids_list(ids):
    # Sort by (scheme, digest bytes); every id here is sha256_v1.
    ordered = sorted(ids, key=lambda s: bytes.fromhex(s.rsplit("/", 1)[1]))
    return struct.pack(">Q", len(ordered)) + b"".join(field(i.encode()) for i in ordered)


def micros(iso):
    dt = datetime.fromisoformat(iso).astimezone(timezone.utc)
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    delta = dt - epoch
    return (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds


def calc_id(model, as_of_iso, inputs, prereqs):
    pre = (
        field(DOMAIN)
        + field(model.encode())
        + struct.pack(">q", micros(as_of_iso))
        + ids_list(inputs)
        + ids_list(prereqs)
    )
    return "calc/sha256_v1/" + hashlib.sha256(pre).hexdigest(), pre.hex()


M = ident("model_code", "irs_pv 1.0.0")
M2 = ident("model_code", "irs_pv 1.0.1")
A, B, C = (ident("content", s) for s in ("input-a", "input-b", "input-c"))
R1, R2 = (ident("result", s) for s in ("result-1", "result-2"))

cases = [
    ("no_inputs_no_prerequisites", M, "2026-11-20T00:00:00+00:00", [], []),
    ("one_input", M, "2026-11-20T00:00:00+00:00", [A], []),
    ("inputs_in_given_order_a_b_c", M, "2026-11-20T00:00:00+00:00", [A, B, C], []),
    ("inputs_in_other_order_c_a_b", M, "2026-11-20T00:00:00+00:00", [C, A, B], []),
    ("duplicate_input_is_kept", M, "2026-11-20T00:00:00+00:00", [A, A], []),
    ("one_prerequisite", M, "2026-11-20T00:00:00+00:00", [A], [R1]),
    ("two_prerequisites", M, "2026-11-20T00:00:00+00:00", [A], [R2, R1]),
    ("other_model_code", M2, "2026-11-20T00:00:00+00:00", [A], [R1]),
    ("as_of_microsecond", M, "2026-11-20T00:00:00.000001+00:00", [A], [R1]),
    ("as_of_before_epoch", M, "1969-12-31T23:59:59.999999+00:00", [], []),
]

out = []
for name, model, as_of, inputs, prereqs in cases:
    cid, pre = calc_id(model, as_of, inputs, prereqs)
    out.append(
        {
            "name": name,
            "model_code": model,
            "as_of": as_of,
            "inputs": inputs,
            "prerequisites": prereqs,
            "preimage_hex": pre,
            "calc_id": cid,
        }
    )
print(json.dumps({"scheme": "sha256_v1", "vectors": out}, indent=1))
