"""Independent generator for the frozen result-hash vectors (scheme sha256_v1).

Written from the encoding documented in src/VeridianCanonical.jl, not from the
Julia code, so it is a second implementation (compare control_plane/fixtures/
gen_calc_id_vectors.py). Run once; the output canonical_v1_vectors.json is
committed and must never change (D-041): a change means a new hash scheme.

    python3 -I test/fixtures/gen_canonical_vectors.py > test/fixtures/canonical_v1_vectors.json
    python3 -I test/fixtures/gen_canonical_vectors.py content > test/fixtures/content_v1_vectors.json
"""
import hashlib
import json
import struct
import sys
from datetime import date
from fractions import Fraction

DOMAIN = b"veridian/result/sha256_v1"
EPOCH = date(1970, 1, 1)


def u64(n):
    return struct.pack(">Q", n)


def i64(n):
    return struct.pack(">q", n)


def blob(b):
    return u64(len(b)) + b


def bigint(n):
    return blob(str(n).encode())


def number(desc):
    """Exact value of a number description: a fraction, or a float by its bits."""
    if "f64bits" in desc:
        (x,) = struct.unpack(">d", struct.pack(">Q", int(desc["f64bits"], 16)))
        return Fraction(x)  # exact
    return Fraction(int(desc["num"]), int(desc["den"]))


def half_even(fr):
    return round(fr)  # Python rounds Fractions half to even


def floor_log10(a):
    e = 0
    while a >= Fraction(10) ** (e + 1):
        e += 1
    while a < Fraction(10) ** e:
        e -= 1
    return e


def df_parts(fr):
    if fr == 0:
        return 0, 0
    a = abs(fr)
    e = floor_log10(a) - 6
    m = half_even(a / Fraction(10) ** e)
    if m == 10**7:
        m, e = 10**6, e + 1
    return (-m if fr < 0 else m), e


def encode(d):
    t = d["t"]
    if t == "bool":
        return b"\x10" + (b"\x01" if d["v"] else b"\x00")
    if t == "int":
        return b"\x11" + i64(int(d["v"]))
    if t == "string":
        return b"\x12" + blob(d["v"].encode("utf-8"))
    if t == "date":
        return b"\x13" + i64((date(d["y"], d["m"], d["d"]) - EPOCH).days)
    if t == "ts":
        return b"\x14" + i64(int(d["v"]))
    if t == "money":
        assert len(d["cur"]) == 3 and d["cur"].isascii() and d["cur"].isupper()
        return b"\x20" + d["cur"].encode() + bigint(half_even(number(d) * 10**4))
    if t == "rate":
        return b"\x21" + bigint(half_even(number(d) * 10**6))
    if t == "df":
        m, e = df_parts(number(d))
        return b"\x22" + bigint(m) + bigint(e)
    if t == "yf":
        fr = Fraction(int(d["num"]), int(d["den"]))  # lowest terms, den > 0
        return b"\x23" + bigint(fr.numerator) + bigint(fr.denominator)
    if t == "list":
        return b"\x30" + u64(len(d["v"])) + b"".join(encode(x) for x in d["v"])
    if t == "record":
        fields = sorted(d["v"].items(), key=lambda kv: kv[0].encode("utf-8"))
        out = b"\x31" + u64(len(fields))
        for name, v in fields:
            out += blob(name.encode("utf-8")) + encode(v)
        return out
    raise ValueError(t)


def f64(x):
    (bits,) = struct.unpack(">Q", struct.pack(">d", x))
    return {"f64bits": hex(bits)}


def q(num, den=1):
    return {"num": str(num), "den": str(den)}


def money(cur, n):
    return {"t": "money", "cur": cur, **n}


def rate(n):
    return {"t": "rate", **n}


def df(n):
    return {"t": "df", **n}


CASES = [
    ("bool_true", {"t": "bool", "v": True}),
    ("bool_false", {"t": "bool", "v": False}),
    ("int_min", {"t": "int", "v": str(-(2**63))}),
    ("int_max", {"t": "int", "v": str(2**63 - 1)}),
    ("string_unicode", {"t": "string", "v": "Zürich 東京 \U0001F600"}),
    ("string_empty", {"t": "string", "v": ""}),
    ("date_epoch", {"t": "date", "y": 1970, "m": 1, "d": 1}),
    ("date_before_epoch", {"t": "date", "y": 1969, "m": 12, "d": 31}),
    ("date_2026", {"t": "date", "y": 2026, "m": 11, "d": 20}),
    ("ts_negative", {"t": "ts", "v": "-1"}),
    ("ts_2026", {"t": "ts", "v": "1795219200000000"}),
    # Money: 4 places, half-even on the exact value.
    ("money_plain", money("USD", q(12345, 100))),
    ("money_tie_down", money("EUR", q(5, 100000))),  # 0.00005 -> 0.0000
    ("money_tie_up", money("EUR", q(15, 100000))),  # 0.00015 -> 0.0002
    ("money_tie_negative", money("GBP", q(-25, 100000))),  # -0.00025 -> -0.0002
    ("money_negative_zero", money("JPY", q(-4, 100000))),  # -0.00004 -> 0
    ("money_float_0_1", money("USD", f64(0.1))),
    ("money_float_tie_looking", money("USD", f64(0.00005))),  # not an exact tie in binary
    ("money_float_negative_zero", money("USD", f64(-0.0))),
    ("money_huge", money("USD", q(10**30 + 1, 3))),
    # Rate: 6 places.
    ("rate_plain", rate(q(25, 1000))),
    ("rate_tie_even", rate(q(5, 10**7))),  # 0.0000005 -> 0.000000
    ("rate_tie_odd", rate(q(15, 10**7))),  # 0.0000015 -> 0.000002
    ("rate_float", rate(f64(0.0315))),
    # Discount factor: 7 significant digits.
    ("df_one", df(q(1))),
    ("df_plain", df(q(9512345678, 10**10))),
    ("df_carry", df(q(99999995, 10**8))),  # 9999999.5 -> 10000000 -> carry
    ("df_tie_even", df(q(12345675, 10**8))),  # ...67|5 -> 0.1234568
    ("df_tiny", df(q(123456789, 10**15))),
    ("df_large", df(q(123456789012, 1))),
    ("df_zero", df(q(0))),
    ("df_negative", df(q(-95, 100))),
    ("df_float", df(f64(0.987654321))),
    # Year fractions: exact rationals.
    ("yf_reduced", {"t": "yf", "num": "182", "den": "364"}),
    ("yf_act360", {"t": "yf", "num": "181", "den": "360"}),
    ("yf_zero", {"t": "yf", "num": "0", "den": "7"}),
    ("yf_negative", {"t": "yf", "num": "-3", "den": "12"}),
    # Structures.
    ("list_empty", {"t": "list", "v": []}),
    (
        "list_mixed",
        {"t": "list", "v": [{"t": "int", "v": "1"}, {"t": "string", "v": "a"}, {"t": "bool", "v": True}]},
    ),
    (
        "list_order_a",
        {"t": "list", "v": [{"t": "int", "v": "1"}, {"t": "int", "v": "2"}]},
    ),
    (
        "list_order_b",
        {"t": "list", "v": [{"t": "int", "v": "2"}, {"t": "int", "v": "1"}]},
    ),
    (
        "record_sorted_fields",
        {
            "t": "record",
            "v": {
                "pv": money("USD", q(1234567, 100)),
                "dv01": money("USD", q(-4321, 1000)),
                "curve": {"t": "list", "v": [df(q(99, 100)), df(q(97, 100)), df(q(94, 100))]},
                "as_of": {"t": "ts", "v": "1795219200000000"},
                "id": {"t": "string", "v": "swap-1"},
            },
        },
    ),
    ("record_empty", {"t": "record", "v": {}}),
    # Names sort by UTF-8 bytes, not by locale or code point order of the language.
    (
        "record_name_byte_order",
        {"t": "record", "v": {"é": {"t": "int", "v": "1"}, "z": {"t": "int", "v": "2"}, "B": {"t": "int", "v": "3"}}},
    ),
    # Ambiguity guards: shifted boundaries must not collide.
    ("string_boundary_a", {"t": "list", "v": [{"t": "string", "v": "ab"}, {"t": "string", "v": "c"}]}),
    ("string_boundary_b", {"t": "list", "v": [{"t": "string", "v": "a"}, {"t": "string", "v": "bc"}]}),
]


DOMAINS = {"result": DOMAIN, "content": b"veridian/content/sha256_v1"}


def main():
    # No argument: the result vectors, unchanged. "content": the same values
    # under the content domain (D-081), written to content_v1_vectors.json.
    domain = DOMAINS[sys.argv[1] if len(sys.argv) > 1 else "result"]
    out = []
    for name, desc in CASES:
        body = encode(desc)
        digest = hashlib.sha256(blob(domain) + body).hexdigest()
        out.append({"name": name, "value": desc, "bytes_hex": body.hex(), "hash_hex": digest})
    print(json.dumps({"scheme": "sha256_v1", "domain": domain.decode(), "vectors": out}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
