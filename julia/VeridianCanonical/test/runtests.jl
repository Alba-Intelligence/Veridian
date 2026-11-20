using Aqua
using Dates: Date
using JET
using JSON
using Supposition
using Supposition: Data
using Test
using VeridianCanonical

# The independent vectors (Python, from the documented layout) --------------------

function number(d)
    if haskey(d, "f64bits")
        return reinterpret(Float64, parse(UInt64, d["f64bits"][3:end]; base = 16))
    end
    return parse(BigInt, d["num"]) // parse(BigInt, d["den"])
end

function build(d)
    t = d["t"]
    t == "bool" && return d["v"]::Bool
    t == "int" && return parse(Int64, d["v"])
    t == "string" && return String(d["v"])
    t == "date" && return Date(d["y"], d["m"], d["d"])
    t == "ts" && return Timestamp(parse(Int64, d["v"]))
    t == "money" && return Money(number(d), d["cur"])
    t == "rate" && return Rate(number(d))
    t == "df" && return DiscountFactor(number(d))
    t == "yf" && return YearFraction(parse(BigInt, d["num"]) // parse(BigInt, d["den"]))
    t == "list" && return Any[build(x) for x in d["v"]]
    if t == "record"
        names = Tuple(Symbol(k) for k in keys(d["v"]))
        return NamedTuple{names}(Tuple(build(v) for v in values(d["v"])))
    end
    error("unknown vector type $t")
end

@testset "frozen vectors from the independent implementation" begin
    path = joinpath(@__DIR__, "fixtures", "canonical_v1_vectors.json")
    vectors = JSON.parsefile(path)
    @test vectors["scheme"] == SCHEME
    @test vectors["domain"] == DOMAIN
    @test length(vectors["vectors"]) >= 40
    for v in vectors["vectors"]
        value = build(v["value"])
        @test bytes2hex(canonical_bytes(value)) == v["bytes_hex"]
        @test bytes2hex(result_hash(value)) == v["hash_hex"]
    end
end

@testset "frozen content vectors (D-081)" begin
    path = joinpath(@__DIR__, "fixtures", "content_v1_vectors.json")
    vectors = JSON.parsefile(path)
    @test vectors["scheme"] == SCHEME
    @test vectors["domain"] == CONTENT_DOMAIN
    @test length(vectors["vectors"]) >= 40
    for v in vectors["vectors"]
        value = build(v["value"])
        @test bytes2hex(canonical_bytes(value)) == v["bytes_hex"]
        @test bytes2hex(content_hash(value)) == v["hash_hex"]
        @test content_id(value) == "content/sha256_v1/" * v["hash_hex"]
    end
end

# Rounding ----------------------------------------------------------------------

# Half-even rounding of a/b * 10^s by integers only: a second, simpler definition.
function half_even_units(a::Integer, b::Integer, s::Int)
    n = big(a) * big(10)^s
    q, r = divrem(n, big(b))  # b > 0; r has the sign of n
    twice = 2 * abs(r)
    away = sign(n) # direction to move when rounding away from zero
    if twice > b || (twice == b && isodd(q))
        q += away
    end
    return q
end

@testset "rounding" begin
    @test Money(5 // 100000, "EUR").units == 0     # 0.00005 -> 0.0000 (tie, even)
    @test Money(15 // 100000, "EUR").units == 2    # 0.00015 -> 0.0002 (tie, even)
    @test Money(-25 // 100000, "EUR").units == -2  # -0.00025 -> -0.0002
    @test Money(-4 // 100000, "EUR").units == 0    # no negative zero after rounding
    @test result_hash(Money(-4 // 100000, "EUR")) == result_hash(Money(0, "EUR"))
    @test Rate(5 // 10^7).units == 0 && Rate(15 // 10^7).units == 2
    # A float is the exact binary value it is, not its decimal text:
    @test Money(0.1, "USD").units == 1000
    @test Money(0.00005, "USD").units == 1  # 0.00005 in binary is just above the tie
    @test Money(-0.0, "USD") == Money(0, "USD")
    d = DiscountFactor(99999995 // 10^8)  # 0.99999995 -> carries to 1.000000
    @test (d.mantissa, d.exponent) == (1000000, -6)
    @test DiscountFactor(0).mantissa == 0 && DiscountFactor(0).exponent == 0
    @test DiscountFactor(-95 // 100).mantissa == -9500000
end

@testset "refusals" begin
    @test_throws ArgumentError Money(NaN, "USD")
    @test_throws ArgumentError Rate(Inf)
    @test_throws ArgumentError Money(1, "usd")
    @test_throws ArgumentError Money(1, "US")
    @test_throws ArgumentError Money(1, "ÜSD")
    @test_throws ArgumentError canonical_bytes(1.5)            # a bare float has no rounding rule
    @test_throws ArgumentError canonical_bytes(Int32(3))       # only Int64 is an Int
    @test_throws ArgumentError canonical_bytes(String([0xff])) # not UTF-8
    @test_throws ArgumentError canonical_bytes((a = 1.0,))
    @test_throws ArgumentError canonical_bytes(nothing)
    @test_throws MethodError YearFraction(0.5)                 # exact rationals only
    @test_throws MethodError Rate("0.1")
end

# Properties --------------------------------------------------------------------

const small_int = Data.Integers(-10^9, 10^9)
const pos_int = Data.Integers(1, 10^9)

@testset "properties" begin

@check db = false max_examples = 300 function money_rounding_matches_integer_definition(
    a = Data.Integers(-10^12, 10^12),
    b = Data.Integers(1, 10^6),
)
    Money(a // b, "USD").units == half_even_units(a, b, 4)
end

@check db = false max_examples = 300 function rate_rounding_matches_integer_definition(
    a = Data.Integers(-10^12, 10^12),
    b = Data.Integers(1, 10^6),
)
    Rate(a // b).units == half_even_units(a, b, 6)
end

@check db = false max_examples = 300 function rounding_is_idempotent(a = small_int, b = pos_int)
    m = Money(a // b, "USD")
    again = Money(m.units // 10^4, "USD")
    again == m && result_hash(again) == result_hash(m)
end

@check db = false max_examples = 300 function equal_after_rounding_means_equal_hash(a = small_int, b = pos_int)
    # Perturb below the rounding step so both round to the same units.
    m1 = Money(a // b, "USD")
    x = m1.units // 10^4
    m2 = Money(x + 1 // 10^6, "USD")
    m1.units == m2.units ? result_hash(m1) == result_hash(m2) : true
end

@check db = false max_examples = 300 function discount_factor_has_seven_digits_and_half_ulp_error(
    a = Data.Integers(-10^15, 10^15),
    b = Data.Integers(1, 10^15),
)
    r = a // b
    d = DiscountFactor(r)
    if a == 0
        return d.mantissa == 0 && d.exponent == 0
    end
    seven = ndigits(abs(d.mantissa)) == 7
    ulp = d.exponent >= 0 ? big(10)^d.exponent // 1 : 1 // big(10)^(-d.exponent)
    err = abs(Rational{BigInt}(r) - d.mantissa * ulp)
    seven && err <= ulp / 2
end

@check db = false max_examples = 300 function record_field_order_does_not_matter(x = small_int, y = small_int, z = pos_int)
    result_hash((a = x, b = y, c = Money(z, "USD"))) ==
    result_hash((c = Money(z, "USD"), a = x, b = y))
end

@check db = false max_examples = 300 function list_order_matters(x = small_int, y = small_int)
    x == y || result_hash(Any[Int64(x), Int64(y)]) != result_hash(Any[Int64(y), Int64(x)])
end

@check db = false max_examples = 300 function a_hash_is_deterministic_and_32_bytes(x = small_int, s = Data.Text(Data.AsciiCharacters(); max_len = 20))
    v = Any[Int64(x), s, Money(x, "EUR")]
    h = result_hash(v)
    length(h) == 32 && h == result_hash(deepcopy(v)) && h == result_hash(Any[Int64(x), s, Money(x, "EUR")])
end

@check db = false max_examples = 300 function distinct_values_have_distinct_bytes(
    a = small_int,
    b = small_int,
    s = Data.Text(Data.AsciiCharacters(); max_len = 8),
    t = Data.Text(Data.AsciiCharacters(); max_len = 8),
)
    # Strings next to each other must not run together, and an Int must not
    # collide with anything of another kind that holds the same digits.
    v1 = Any[s, t]
    v2 = Any[string(s, t), ""]
    same_pair = (s == string(s, t) && t == "")
    (canonical_bytes(v1) == canonical_bytes(v2)) == same_pair &&
        canonical_bytes(Int64(a)) != canonical_bytes(Money(a, "USD")) &&
        (Int64(a) == Int64(b) || canonical_bytes(Int64(a)) != canonical_bytes(Int64(b)))
end

@check db = false max_examples = 200 function floats_round_like_their_exact_value(x = Data.Floats{Float64}(nans = false, infs = false))
    abs(x) > 1e12 || Money(x, "USD").units == half_even_units(numerator(Rational{BigInt}(x)), denominator(Rational{BigInt}(x)), 4)
end

@check db = false max_examples = 300 function content_and_result_hashes_never_coincide(
    x = small_int,
    s = Data.Text(Data.AsciiCharacters(); max_len = 20),
)
    v = (pv = Money(x, "USD"), id = s, n = Int64(x))
    content_hash(v) != result_hash(v) && canonical_bytes(v) == canonical_bytes(deepcopy(v))
end

end # properties

# Package quality ---------------------------------------------------------------

@testset "Aqua" begin
    Aqua.test_all(VeridianCanonical)
end

@testset "JET" begin
    JET.test_package(VeridianCanonical; target_modules = (VeridianCanonical,))
end
