"""
    RoundThrows

Raises an `InexactError` if any rounding is necessary.
"""
const RoundThrows = RoundingMode{:Throw}()

# Return codes of `_parse_fd`
const _OK = 0x00
const _INVALID = 0x01
const _OVERFLOW = 0x02
const _INEXACT = 0x03

# Exponents are saturated at this magnitude while parsing, so they can't overflow `Int`.
# Any exponent this large over- or underflows every supported storage type anyway.
const _MAX_EXPONENT = 100_000_000

for T in (Base.BitSigned_types..., Base.BitUnsigned_types...)
    let bytes = Tuple(codeunits(string(typemax(T))))
        # The number of digits an integer of type T can hold
        @eval _maxintdigits(::Type{$T}) = $(length(bytes))
    end
end

@inline _isdigit(b::UInt8) = (b - UInt8('0')) <= 0x09
@inline _isspace(b::UInt8) = b == UInt8(' ') || UInt8('\t') <= b <= UInt8('\r')

# Parse the decimal number in `buf[i:j]` into the integer backing a `FixedDecimal{T,f}`,
# rounding any digits past the precision `f` with `mode`.
#
# Accepted grammar, optionally surrounded by ASCII whitespace:
#   [+-] digits [decimal digits] [(e|E|f|F) [+-] digits]
# where at least one mantissa digit is required, and `groupmark`s may separate the
# integer digits. Returns `(value, code)`, where `value` is only meaningful when
# `code == _OK`.
#
# The significant digits are accumulated into an unsigned integer type wide enough to
# hold `_maxintdigits(T) + 1` digits; anything past that either overflows or only
# matters for rounding, so no BigInts are needed.
function _parse_fd(
    ::Type{T}, f::Int, buf::AbstractVector{UInt8}, i::Int, j::Int,
    decimal::UInt8, groupmark::Union{UInt8,Nothing}, mode::RoundingMode,
) where {T<:Integer}
    @inbounds begin
        while i <= j && _isspace(buf[i])
            i += 1
        end
        while j >= i && _isspace(buf[j])
            j -= 1
        end
        i > j && return zero(T), _INVALID

        b = buf[i]
        neg = b == UInt8('-')
        (neg || b == UInt8('+')) && (i += 1)

        # First pass: validate the input and count digits
        p = i
        nint = 0   # digits before the decimal mark
        nfrac = 0  # digits after the decimal mark
        nsig = 0   # digits from the first non-zero digit onwards
        while p <= j
            b = buf[p]
            if _isdigit(b)
                nint += 1
                nsig += (nsig > 0) | (b != UInt8('0'))
            elseif !(b === groupmark && nint > 0 && p < j && _isdigit(buf[p + 1]))
                # Group marks are only allowed between two integer digits
                break
            end
            p += 1
        end
        if p <= j && buf[p] == decimal
            p += 1
            while p <= j && _isdigit(buf[p])
                nfrac += 1
                nsig += (nsig > 0) | (buf[p] != UInt8('0'))
                p += 1
            end
        end
        mantissa_end = p - 1
        nint + nfrac == 0 && return zero(T), _INVALID

        exp = 0
        if p <= j
            b = buf[p] | 0x20 # ASCII lowercase
            (b == UInt8('e') || b == UInt8('f')) || return zero(T), _INVALID
            p += 1
            p <= j || return zero(T), _INVALID
            exp_neg = buf[p] == UInt8('-')
            (exp_neg || buf[p] == UInt8('+')) && (p += 1)
            p <= j || return zero(T), _INVALID
            while p <= j
                b = buf[p]
                _isdigit(b) || return zero(T), _INVALID
                exp < _MAX_EXPONENT && (exp = 10exp + (b - UInt8('0')))
                p += 1
            end
            exp_neg && (exp = -exp)
        end

        # All digits are zero
        nsig == 0 && return zero(T), _OK

        # The number of digits of the backing integer, before rounding
        backing_integer_digits = nsig + f + exp - nfrac
        # Unsigned types can't represent negative numbers, unless they round to zero
        neg_unsigned = neg && T <: Unsigned
        if backing_integer_digits > _maxintdigits(T)
            # The leading digit is non-zero, so the backing integer is at least 10^(backing_integer_digits-1)
            return zero(T), neg_unsigned ? _INVALID : _OVERFLOW
        end
        if backing_integer_digits < 0
            # All digits are past our precision, and they are less than a half
            mode === RoundThrows && return zero(T), _INEXACT
            return zero(T), _OK
        end

        # Second pass: accumulate the significant digits that fit in our precision, and
        # note the first digit past our precision and whether any later digit is non-zero
        A = _widen(unsigned(T))
        x = zero(A)
        k = 0  # significant digits seen so far
        round_digit = 0x00
        sticky = false
        for q in i:mantissa_end
            b = buf[q] - UInt8('0')
            b <= 0x09 || continue                # group or decimal mark
            (k == 0 && b == 0x00) && continue    # leading zero
            if k < backing_integer_digits
                x = A(10) * x + b
            elseif k == backing_integer_digits
                round_digit = b
            else
                sticky |= b != 0x00
            end
            k += 1
        end
        # Pad with trailing zeros
        nsig < backing_integer_digits && (x *= A(10)^(backing_integer_digits - nsig))
    end

    neg_unsigned && !iszero(x) && return zero(T), _INVALID
    if mode === RoundThrows
        (round_digit != 0x00 || sticky) && return zero(T), _INEXACT
    elseif mode === RoundNearest
        # Ties to even
        if round_digit > 0x05 || (round_digit == 0x05 && (sticky || isodd(x)))
            x += one(A)
        end
    end

    if neg
        neg_unsigned && !iszero(x) && return zero(T), _INVALID
        x > A(typemax(T)) + one(A) && return zero(T), _OVERFLOW
    else
        x > A(typemax(T)) && return zero(T), _OVERFLOW
    end
    v = x % T
    return ifelse(neg, -v, v), _OK
end

function _check_rounding(mode::RoundingMode)
    if !(mode in (RoundNearest, RoundToZero, RoundThrows))
        throw(ArgumentError("Unhandled rounding mode $mode"))
    end
    return mode
end

function _markbyte(c::Char, name)
    if !isascii(c) || isdigit(c) || c in ('+', '-', 'e', 'E', 'f', 'F')
        throw(ArgumentError("Invalid `$name` mark $(repr(c))"))
    end
    return UInt8(c)
end
_markbyte(::Nothing, name) = nothing

function _marks(decimal::Char, groupmark::Union{Char,Nothing})
    decimal == groupmark && throw(ArgumentError("`decimal` and `groupmark` must differ, got $(repr(decimal))"))
    return _markbyte(decimal, "decimal"), _markbyte(groupmark, "groupmark")
end

@inline function _tryparse(
    ::Type{FD{T,f}}, buf::AbstractVector{UInt8}, i::Int, j::Int, decimal, groupmark, mode,
) where {T,f}
    v, code = _parse_fd(T, f, buf, i, j, decimal, groupmark, mode)
    return code == _OK ? reinterpret(FD{T,f}, v) : nothing
end

@inline function _parse(
    ::Type{FD{T,f}}, buf::AbstractVector{UInt8}, i::Int, j::Int, decimal, groupmark, mode,
) where {T,f}
    v, code = _parse_fd(T, f, buf, i, j, decimal, groupmark, mode)
    code == _OK || _throw_parse_error(FD{T,f}, code, String(buf[i:j]))
    return reinterpret(FD{T,f}, v)
end

@noinline function _throw_parse_error(::Type{FD{T,f}}, code, source) where {T,f}
    code == _INEXACT && throw(InexactError(:parse, FD{T, f}, source))
    code == _OVERFLOW && throw(OverflowError("overflow parsing $(repr(source)) as $(FD{T, f})"))
    throw(ArgumentError("cannot parse $(repr(source)) as $(FD{T, f})"))
end

function Base.tryparse(::Type{FD{T, f}}, source::AbstractString, mode::RoundingMode=RoundNearest) where {T, f}
    _check_rounding(mode)
    bytes = codeunits(source)
    return _tryparse(FD{T, f}, bytes, 1, length(bytes), UInt8('.'), nothing, mode)
end

function Base.parse(::Type{FD{T, f}}, source::AbstractString, mode::RoundingMode=RoundNearest) where {T, f}
    _check_rounding(mode)
    isempty(source) && throw(ArgumentError("Empty input is not allowed"))
    bytes = codeunits(source)
    return _parse(FD{T, f}, bytes, 1, length(bytes), UInt8('.'), nothing, mode)
end

# Parsers.jl integration: byte-span parsing, as used by e.g. CSV.jl, with the same keywords
# Parsers.jl uses for floats, plus the rounding mode.

"""
    Parsers.tryparse(FixedDecimal{T,f}, buf::AbstractVector{UInt8}, first, last; decimal='.', groupmark=nothing, rounding=RoundNearest)
    Parsers.tryparse(FixedDecimal{T,f}, source; decimal='.', groupmark=nothing, rounding=RoundNearest)

Parse the bytes `buf[first:last]` (or all of `source`, a string or byte vector) as a
`FixedDecimal{T,f}`, returning `nothing` if the input is invalid, out of range, or, for
`rounding=RoundThrows`, needs rounding. Surrounding ASCII whitespace is ignored.
"""
function Parsers.tryparse(
    ::Type{FD{T,f}}, buf::AbstractVector{UInt8}, first::Integer, last::Integer;
    decimal::Char='.', groupmark::Union{Char,Nothing}=nothing, rounding::RoundingMode=RoundNearest,
) where {T,f}
    _check_rounding(rounding)
    dec, grp = _marks(decimal, groupmark)
    checkbounds(buf, first:last)
    return _tryparse(FD{T,f}, buf, Int(first), Int(last), dec, grp, rounding)
end

"""
    Parsers.parse(FixedDecimal{T,f}, buf::AbstractVector{UInt8}, first, last; decimal='.', groupmark=nothing, rounding=RoundNearest)
    Parsers.parse(FixedDecimal{T,f}, source; decimal='.', groupmark=nothing, rounding=RoundNearest)

Like `Parsers.tryparse`, but throws an `ArgumentError` for invalid input, an
`OverflowError` for out of range values, and an `InexactError` if `rounding=RoundThrows`
and the input needs rounding.
"""
function Parsers.parse(
    ::Type{FD{T,f}}, buf::AbstractVector{UInt8}, first::Integer, last::Integer;
    decimal::Char='.', groupmark::Union{Char,Nothing}=nothing, rounding::RoundingMode=RoundNearest,
) where {T,f}
    _check_rounding(rounding)
    dec, grp = _marks(decimal, groupmark)
    checkbounds(buf, first:last)
    return _parse(FD{T,f}, buf, Int(first), Int(last), dec, grp, rounding)
end

function Parsers.tryparse(::Type{FD{T,f}}, source::Union{AbstractString,AbstractVector{UInt8}}; kw...) where {T,f}
    bytes = source isa AbstractString ? codeunits(source) : source
    return Parsers.tryparse(FD{T,f}, bytes, firstindex(bytes), lastindex(bytes); kw...)
end

function Parsers.parse(::Type{FD{T,f}}, source::Union{AbstractString,AbstractVector{UInt8}}; kw...) where {T,f}
    bytes = source isa AbstractString ? codeunits(source) : source
    return Parsers.parse(FD{T,f}, bytes, firstindex(bytes), lastindex(bytes); kw...)
end
