"""
    VeridianCanonical

The canonical form of a calculation result and its hash, scheme `sha256_v1`
(spec 02 `CanonicalRounding` and `VersionedHashScheme`; D-004, D-015, D-041).

Two results that are equal after canonical rounding have the same hash, on any
worker, in any language. Every number in a result carries its kind, because the
kind decides the rounding:

| Type             | Canonical form                                                   |
|------------------|------------------------------------------------------------------|
| `Money`          | currency (3 capital ASCII letters) and amount to 4 decimal places |
| `Rate`           | rate or percentage to 6 decimal places (0.01 basis point)         |
| `DiscountFactor` | 7 significant digits                                              |
| `YearFraction`   | exact rational, never rounded                                     |
| `Timestamp`      | `Int64` microseconds since the Unix epoch, UTC                    |
| `Date`           | days since 1970-01-01                                             |

Rounding is half-even on the **exact** value: a `Float64` is taken as the exact
binary rational it is, never through its decimal text, so the result does not
depend on a printing library. Plain `Float64` or untyped numbers are refused: a
number without a kind has no rounding rule.

# Encoding (`sha256_v1`)

All integers big-endian. `len` is an unsigned 64-bit byte count. A *bigint* is
`len` followed by the ASCII decimal text (`-` sign for negatives, no `+`, no
leading zeros, zero is `0`).

    value  := tag payload
    0x10 Bool            1 byte, 0 or 1
    0x11 Int             signed 64-bit
    0x12 String          len, UTF-8 bytes (valid UTF-8 only)
    0x13 Date            signed 64-bit days since 1970-01-01
    0x14 Timestamp       signed 64-bit microseconds since the Unix epoch
    0x20 Money           3 ASCII bytes of currency, bigint of amount * 10^4
    0x21 Rate            bigint of value * 10^6
    0x22 DiscountFactor  bigint mantissa, bigint exponent (value = mantissa * 10^exponent;
                         mantissa is 0 with exponent 0, or has exactly 7 digits)
    0x23 YearFraction    bigint numerator, bigint denominator (lowest terms, > 0)
    0x30 List            len(count), elements in order
    0x31 Record          len(count), then per field, sorted by name bytes:
                         len, name bytes, value (names unique)

The hash is SHA-256 over `len(domain) domain encoded_value`, with the domain
string `veridian/result/sha256_v1` for a result and `veridian/content/sha256_v1`
for an input's content (D-081). The encoding is frozen: changing it means a
new scheme (D-041), and the vectors in `test/fixtures` come from an independent
Python implementation.
"""
module VeridianCanonical

using Dates: Dates, Date
using SHA: SHA

export ResultValue, SCHEME, DOMAIN, Money, Rate, DiscountFactor, YearFraction, Timestamp
export canonical_bytes, result_hash, result_id, CONTENT_DOMAIN, content_hash, content_id

"The hashing scheme this package implements."
const SCHEME = "sha256_v1"
"The domain-separation string hashed before a result value."
const DOMAIN = "veridian/result/sha256_v1"
"The domain-separation string hashed before an input's content (D-081)."
const CONTENT_DOMAIN = "veridian/content/sha256_v1"

# Exact arithmetic --------------------------------------------------------------

"The exact rational value of a finite real number; refuses NaN and infinities."
exact(x::Integer)::Rational{BigInt} = Rational{BigInt}(x)
exact(x::Rational)::Rational{BigInt} = Rational{BigInt}(x)
function exact(x::AbstractFloat)::Rational{BigInt}
    isfinite(x) || throw(ArgumentError("not a finite number: $x"))
    return Rational{BigInt}(x)  # exact for binary floats
end
exact(x) = throw(ArgumentError("not a real number: $(repr(x))"))

"`round(x * 10^scale)`, half-even, on the exact value."
function scaled(x::Real, scale::Int)::BigInt
    return round(BigInt, exact(x) * big(10)^scale, RoundNearest)
end

"`10^e` as an exact rational, for any integer `e`."
pow10(e::Integer)::Rational{BigInt} = e >= 0 ? big(10)^e // 1 : 1 // big(10)^(-e)

"Largest `e` with `10^e <= r`, for `r > 0`, by integer arithmetic only."
function floor_log10(r::Rational{BigInt})::Int
    e = ndigits(r.num) - ndigits(r.den)  # within one of the answer
    while big(10)^max(e, 0) * r.den > r.num * big(10)^max(-e, 0)  # 10^e > r
        e -= 1
    end
    while big(10)^max(e + 1, 0) * r.den <= r.num * big(10)^max(-(e + 1), 0)  # 10^(e+1) <= r
        e += 1
    end
    return e
end

# Typed result values -----------------------------------------------------------

"Supertype of the kinded values; they compare and hash by value."
abstract type ResultValue end

Base.:(==)(a::T, b::T) where {T<:ResultValue} = all(f -> getfield(a, f) == getfield(b, f), fieldnames(T))
Base.hash(a::T, h::UInt) where {T<:ResultValue} =
    foldl((acc, f) -> hash(getfield(a, f), acc), fieldnames(T); init = hash(T, h))

"A monetary amount, held already rounded to 4 decimal places of its currency."
struct Money <: ResultValue
    units::BigInt  # amount * 10^4
    currency::String
    function Money(amount::Real, currency::AbstractString)
        occursin(r"^[A-Z]{3}$", currency) ||
            throw(ArgumentError("currency must be 3 capital ASCII letters: $(repr(currency))"))
        return new(scaled(amount, 4), String(currency))
    end
end

"A rate or percentage as a decimal rate, held already rounded to 6 decimal places."
struct Rate <: ResultValue
    units::BigInt  # value * 10^6
    Rate(value::Real) = new(scaled(value, 6))
end

"A discount factor, held already rounded to 7 significant digits."
struct DiscountFactor <: ResultValue
    mantissa::BigInt  # 0, or exactly 7 digits (sign carried here)
    exponent::BigInt
    function DiscountFactor(value::Real)
        r = exact(value)
        iszero(r) && return new(big(0), big(0))
        a = abs(r)
        e = floor_log10(a) - 6  # a / 10^e has 7 integer digits
        m = round(BigInt, a / pow10(e), RoundNearest)
        if m == big(10)^7  # rounded up to 8 digits
            m = big(10)^6
            e += 1
        end
        return new(r < 0 ? -m : m, big(e))
    end
end

"An exact year fraction (a day-count result): a rational, never rounded."
struct YearFraction <: ResultValue
    value::Rational{BigInt}
    function YearFraction(value::Union{Integer,Rational})
        return new(exact(value))
    end
end

"A UTC instant as signed 64-bit microseconds since the Unix epoch (D-015)."
struct Timestamp <: ResultValue
    micros::Int64
end

# Encoding ----------------------------------------------------------------------

const T_BOOL = 0x10
const T_INT = 0x11
const T_STRING = 0x12
const T_DATE = 0x13
const T_TIMESTAMP = 0x14
const T_MONEY = 0x20
const T_RATE = 0x21
const T_DF = 0x22
const T_YEARFRAC = 0x23
const T_LIST = 0x30
const T_RECORD = 0x31

put_u64!(io::IO, n::Integer) = write(io, hton(UInt64(n)))
put_i64!(io::IO, n::Integer) = write(io, hton(Int64(n)))

function put_bytes!(io::IO, b::AbstractVector{UInt8})
    put_u64!(io, length(b))
    write(io, b)
    return nothing
end

put_bigint!(io::IO, n::BigInt) = put_bytes!(io, codeunits(string(n)))

function put_string!(io::IO, s::AbstractString)
    isvalid(String, s) || throw(ArgumentError("string is not valid UTF-8"))
    return put_bytes!(io, codeunits(String(s)))
end

encode!(io::IO, x::Bool) = (write(io, T_BOOL, UInt8(x)); nothing)
encode!(io::IO, x::Int64) = (write(io, T_INT); put_i64!(io, x); nothing)
encode!(io::IO, x::String) = (write(io, T_STRING); put_string!(io, x); nothing)
encode!(io::IO, x::Date) = (write(io, T_DATE); put_i64!(io, Dates_days(x)); nothing)
encode!(io::IO, x::Timestamp) = (write(io, T_TIMESTAMP); put_i64!(io, x.micros); nothing)

function encode!(io::IO, x::Money)
    write(io, T_MONEY)
    write(io, codeunits(x.currency))
    put_bigint!(io, x.units)
    return nothing
end

function encode!(io::IO, x::Rate)
    write(io, T_RATE)
    put_bigint!(io, x.units)
    return nothing
end

function encode!(io::IO, x::DiscountFactor)
    write(io, T_DF)
    put_bigint!(io, x.mantissa)
    put_bigint!(io, x.exponent)
    return nothing
end

function encode!(io::IO, x::YearFraction)
    write(io, T_YEARFRAC)
    put_bigint!(io, numerator(x.value))
    put_bigint!(io, denominator(x.value))
    return nothing
end

function encode!(io::IO, xs::AbstractVector)
    write(io, T_LIST)
    put_u64!(io, length(xs))
    for x in xs
        encode!(io, x)
    end
    return nothing
end

function encode!(io::IO, r::NamedTuple)
    write(io, T_RECORD)
    fields = sort!([(String(k), v) for (k, v) in pairs(r)]; by = first)  # by name bytes
    put_u64!(io, length(fields))
    for (name, v) in fields
        put_string!(io, name)
        encode!(io, v)
    end
    return nothing
end

function encode!(::IO, x)
    throw(
        ArgumentError(
            "cannot encode $(typeof(x)): a result holds Bool, Int64, String, Date, " *
            "Timestamp, Money, Rate, DiscountFactor, YearFraction, vectors and named " *
            "tuples of these (a bare number has no rounding rule)",
        ),
    )
end

const EPOCH_DAY = Dates.value(Date(1970, 1, 1))
Dates_days(d::Date)::Int64 = Int64(Dates.value(d) - EPOCH_DAY)

"The canonical bytes of a result value."
function canonical_bytes(x)::Vector{UInt8}
    io = IOBuffer()
    encode!(io, x)
    return take!(io)
end

function domain_hash(domain::String, x)::Vector{UInt8}
    io = IOBuffer()
    put_bytes!(io, codeunits(domain))
    encode!(io, x)
    return SHA.sha256(take!(io))
end

"The 32-byte `sha256_v1` hash of a result value."
result_hash(x)::Vector{UInt8} = domain_hash(DOMAIN, x)

"The identifier text of a result value, as the control plane writes it: `result/sha256_v1/<hex>`."
result_id(x)::String = string("result/", SCHEME, "/", bytes2hex(result_hash(x)))

"""
The 32-byte `sha256_v1` content hash of an input version's content (D-081): the
same canonical encoding as a result, under its own domain string, so content
and results never share a hash.
"""
content_hash(x)::Vector{UInt8} = domain_hash(CONTENT_DOMAIN, x)

"The identifier text of input content, as the control plane records it: `content/sha256_v1/<hex>`."
content_id(x)::String = string("content/", SCHEME, "/", bytes2hex(content_hash(x)))

end # module
