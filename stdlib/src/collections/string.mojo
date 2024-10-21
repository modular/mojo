# ===----------------------------------------------------------------------=== #
# Copyright (c) 2024, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Implements basic object methods for working with strings.

These are Mojo built-ins, so you don't need to import them.
"""

from collections import KeyElement, List, Optional
from collections._index_normalization import normalize_index
from sys import bitwidthof, llvm_intrinsic
from sys.ffi import c_char, OpaquePointer
from utils import StaticString, write_args

from bit import count_leading_zeros
from memory import UnsafePointer, memcmp, memcpy, stack_allocation
from python import PythonObject

from sys.intrinsics import _type_is_eq
from hashlib._hasher import _HashableWithHasher, _Hasher

from utils import (
    Span,
    IndexList,
    StringRef,
    StringSlice,
    Variant,
    Writable,
    Writer,
)
from utils.string_slice import (
    _utf8_byte_type,
    _StringSliceIter,
    _unicode_codepoint_utf8_byte_length,
    _shift_unicode_to_utf8,
    _FormatCurlyEntry,
    _CurlyEntryFormattable,
)

# ===----------------------------------------------------------------------=== #
# ord
# ===----------------------------------------------------------------------=== #


fn ord(s: String) -> Int:
    """Returns an integer that represents the given one-character string.

    Given a string representing one character, return an integer
    representing the code point of that character. For example, `ord("a")`
    returns the integer `97`. This is the inverse of the `chr()` function.

    Args:
        s: The input string slice, which must contain only a single character.

    Returns:
        An integer representing the code point of the given character.
    """
    return ord(s.as_string_slice())


fn ord(s: StringSlice) -> Int:
    """Returns an integer that represents the given one-character string.

    Given a string representing one character, return an integer
    representing the code point of that character. For example, `ord("a")`
    returns the integer `97`. This is the inverse of the `chr()` function.

    Args:
        s: The input string, which must contain only a single character.

    Returns:
        An integer representing the code point of the given character.
    """
    # UTF-8 to Unicode conversion:              (represented as UInt32 BE)
    # 1: 0aaaaaaa                            -> 00000000 00000000 00000000 0aaaaaaa     a
    # 2: 110aaaaa 10bbbbbb                   -> 00000000 00000000 00000aaa aabbbbbb     a << 6  | b
    # 3: 1110aaaa 10bbbbbb 10cccccc          -> 00000000 00000000 aaaabbbb bbcccccc     a << 12 | b << 6  | c
    # 4: 11110aaa 10bbbbbb 10cccccc 10dddddd -> 00000000 000aaabb bbbbcccc ccdddddd     a << 18 | b << 12 | c << 6 | d
    var p = s.unsafe_ptr().bitcast[UInt8]()
    var b1 = p[]
    if (b1 >> 7) == 0:  # This is 1 byte ASCII char
        debug_assert(s.byte_length() == 1, "input string length must be 1")
        return int(b1)
    var num_bytes = count_leading_zeros(~b1)
    debug_assert(
        s.byte_length() == int(num_bytes), "input string must be one character"
    )
    debug_assert(
        1 < int(num_bytes) < 5, "invalid UTF-8 byte ", b1, " at index 0"
    )
    var shift = int((6 * (num_bytes - 1)))
    var b1_mask = 0b11111111 >> (num_bytes + 1)
    var result = int(b1 & b1_mask) << shift
    for i in range(1, num_bytes):
        p += 1
        debug_assert(
            p[] >> 6 == 0b00000010, "invalid UTF-8 byte ", b1, " at index ", i
        )
        shift -= 6
        result |= int(p[] & 0b00111111) << shift
    return result


# ===----------------------------------------------------------------------=== #
# chr
# ===----------------------------------------------------------------------=== #


fn chr(c: Int) -> String:
    """Returns a String based on the given Unicode code point. This is the
    inverse of the `ord()` function.

    Args:
        c: An integer that represents a code point.

    Returns:
        A string containing a single character based on the given code point.

    Examples:
    ```mojo
    print(chr(97)) # "a"
    print(chr(8364)) # "€"
    ```
    .
    """

    if c < 0b1000_0000:  # 1 byte ASCII char
        return String(String._buffer_type(c, 0))

    var num_bytes = _unicode_codepoint_utf8_byte_length(c)
    var p: UnsafePointer[UInt8]
    if num_bytes == 2:
        p = stack_allocation[3, UInt8]()
    elif num_bytes == 3:
        p = stack_allocation[4, UInt8]()
    else:
        p = stack_allocation[5, UInt8]()
    _shift_unicode_to_utf8(p, c, num_bytes)
    # TODO: decide whether to use replacement char (�) or raise ValueError
    # if not _is_valid_utf8(p, num_bytes):
    #     debug_assert(False, "Invalid Unicode code point")
    #     return chr(0xFFFD)
    p[num_bytes] = 0
    return String(ptr=p, len=num_bytes + 1)


# ===----------------------------------------------------------------------=== #
# ascii
# ===----------------------------------------------------------------------=== #


@always_inline
fn isdigit(c: Byte) -> Bool:
    """Determines whether the given character is a digit: [0, 9].

    Args:
        c: The character to check.

    Returns:
        True if the character is a digit.
    """
    alias `0` = Byte(ord("0"))
    alias `9` = Byte(ord("9"))
    return `0` <= c <= `9`


@always_inline
fn _is_ascii_printable_vec[
    w: Int, //
](v: SIMD[DType.uint8, w]) -> SIMD[DType.bool, w]:
    alias ` ` = Byte(ord(" "))
    alias `~` = Byte(ord("~"))
    return ` ` <= v <= `~`


@always_inline
fn isprintable(v: SIMD[DType.uint8]) -> Bool:
    """Determines whether the given characters are ASCII printable.

    Args:
        v: The characters to check.

    Returns:
        True if the characters are printable, otherwise False.
    """
    return _is_ascii_printable_vec(v).reduce_and()


@always_inline
fn isprintable(span: Span[Byte]) -> Bool:
    """Determines whether the given characters are ASCII printable.

    Args:
        v: The characters to check.

    Returns:
        True if the characters are printable, otherwise False.
    """
    return span.count[_is_ascii_printable_vec]() == len(span)


trait _HasAscii:
    fn __ascii__(self) -> String:
        ...


@always_inline
fn ascii[T: _HasAscii](value: T) -> String:
    """Get the ASCII representation of the object.

    Args:
        value: The object to get the ASCII representation of.

    Returns:
        A string containing the ASCII representation of the object.
    """
    return value.__ascii__()


fn ascii[T: Stringlike, //](value: T) -> String:
    """Get the ASCII representation of the object.

    Parameters:
        T: The Stringlike type.

    Args:
        value: The object to get the ASCII representation of.

    Returns:
        A string containing the ASCII representation of the object.
    """

    alias `'` = UInt8(ord("'"))
    alias `\\` = UInt8(ord("\\"))
    alias `x` = UInt8(ord("x"))

    span = value.as_bytes_read()
    span_len = len(span)
    non_printable_chars = span_len - span.count[_is_ascii_printable_vec]()
    hex_prefix = non_printable_chars * 3
    b_len = value.byte_length()
    result = String(String._buffer_type(capacity=b_len + hex_prefix + 3))

    use_dquote = False
    v_ptr, r_ptr = value.unsafe_ptr(), result.unsafe_ptr()
    v_idx, r_idx = 0, 0

    for i in range(span_len):
        char = v_ptr[v_idx]
        use_dquote = use_dquote or (char == `'`)
        if isprintable(char):
            r_ptr[r_idx] = char
        else:
            r_ptr[r_idx] = `\\`
            r_ptr[r_idx + 1] = `x`
            r_ptr[r_idx + 2] = char // 16
            r_ptr[r_idx + 3] = char % 16
            r_idx += 3
        v_idx += 1
        r_idx += 1

    return '"' + result + '"' if use_dquote else "'" + result + "'"


@always_inline
fn _is_ascii_uppercase_vec[
    w: Int, //
](v: SIMD[DType.uint8, w]) -> SIMD[DType.bool, w]:
    alias `A` = Byte(ord("A"))
    alias `Z` = Byte(ord("Z"))
    return `A` <= c <= `Z`


@always_inline
fn _is_ascii_uppercase(v: SIMD[DType.uint8]) -> Bool:
    return _is_ascii_uppercase_vec(v).reduce_and()


@always_inline
fn _is_ascii_uppercase(span: Span[Byte]) -> Bool:
    return span.count[_is_ascii_uppercase_vec]() == len(span)


@always_inline
fn _is_ascii_lowercase_vec[
    w: Int, //
](v: SIMD[DType.uint8, w]) -> SIMD[DType.bool, w]:
    alias `a` = Byte(ord("a"))
    alias `z` = Byte(ord("z"))
    return `a` <= v <= `z`


@always_inline
fn _is_ascii_lowercase(v: SIMD[DType.uint8]) -> Bool:
    return _is_ascii_lowercase_vec(v).reduce_and()


@always_inline
fn _is_ascii_lowercase(span: Span[Byte]) -> Bool:
    return span.count[_is_ascii_lowercase_vec]() == len(span)


fn _is_ascii_space(c: Byte) -> Bool:
    """Determines whether the given character is an ASCII whitespace character:
    `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

    Args:
        c: The character to check.

    Returns:
        True if the character is one of the ASCII whitespace characters.

    Notes:
        For semantics similar to Python, use `String.isspace()`.
    """

    # NOTE: a global LUT doesn't work at compile time so we can't use it here.
    alias ` ` = Byte(ord(" "))
    alias `\t` = Byte(ord("\t"))
    alias `\n` = Byte(ord("\n"))
    alias `\r` = Byte(ord("\r"))
    alias `\f` = Byte(ord("\f"))
    alias `\v` = Byte(ord("\v"))
    alias `\x1c` = Byte(ord("\x1c"))
    alias `\x1d` = Byte(ord("\x1d"))
    alias `\x1e` = Byte(ord("\x1e"))

    # This compiles to something very clever that's even faster than a LUT.
    return (
        c == ` `
        or c == `\t`
        or c == `\n`
        or c == `\r`
        or c == `\f`
        or c == `\v`
        or c == `\x1c`
        or c == `\x1d`
        or c == `\x1e`
    )


# ===----------------------------------------------------------------------=== #
# strtol
# ===----------------------------------------------------------------------=== #


fn _atol(str_ref: StringSlice[_], base: Int = 10) raises -> Int:
    """Implementation of `atol` for StringRef inputs.

    Please see its docstring for details.
    """
    if (base != 0) and (base < 2 or base > 36):
        raise Error("Base must be >= 2 and <= 36, or 0.")
    if not str_ref:
        raise Error(_atol_error(base, str_ref))

    var real_base: Int
    var ord_num_max: Int

    var ord_letter_max = (-1, -1)
    var result = 0
    var is_negative: Bool = False
    var has_prefix: Bool = False
    var start: Int = 0
    var str_len = len(str_ref)
    var buff = str_ref.unsafe_ptr()

    for pos in range(start, str_len):
        if _is_ascii_space(buff[pos]):
            continue

        if str_ref[pos] == "-":
            is_negative = True
            start = pos + 1
        elif str_ref[pos] == "+":
            start = pos + 1
        else:
            start = pos
        break

    if str_ref[start] == "0" and start + 1 < str_len:
        if base == 2 and (
            str_ref[start + 1] == "b" or str_ref[start + 1] == "B"
        ):
            start += 2
            has_prefix = True
        elif base == 8 and (
            str_ref[start + 1] == "o" or str_ref[start + 1] == "O"
        ):
            start += 2
            has_prefix = True
        elif base == 16 and (
            str_ref[start + 1] == "x" or str_ref[start + 1] == "X"
        ):
            start += 2
            has_prefix = True

    alias ord_0 = ord("0")
    # FIXME:
    #   Change this to `alias` after fixing support for __getitem__ of alias.
    var ord_letter_min = (ord("a"), ord("A"))
    alias ord_underscore = ord("_")

    if base == 0:
        var real_base_new_start = _identify_base(str_ref, start)
        real_base = real_base_new_start[0]
        start = real_base_new_start[1]
        has_prefix = real_base != 10
        if real_base == -1:
            raise Error(_atol_error(base, str_ref))
    else:
        real_base = base

    if real_base <= 10:
        ord_num_max = ord(str(real_base - 1))
    else:
        ord_num_max = ord("9")
        ord_letter_max = (
            ord("a") + (real_base - 11),
            ord("A") + (real_base - 11),
        )

    var found_valid_chars_after_start = False
    var has_space_after_number = False
    # Prefixed integer literals with real_base 2, 8, 16 may begin with leading
    # underscores under the conditions they have a prefix
    var was_last_digit_undescore = not (real_base in (2, 8, 16) and has_prefix)
    for pos in range(start, str_len):
        var ord_current = int(buff[pos])
        if ord_current == ord_underscore:
            if was_last_digit_undescore:
                raise Error(_atol_error(base, str_ref))
            else:
                was_last_digit_undescore = True
                continue
        else:
            was_last_digit_undescore = False
        if ord_0 <= ord_current <= ord_num_max:
            result += ord_current - ord_0
            found_valid_chars_after_start = True
        elif ord_letter_min[0] <= ord_current <= ord_letter_max[0]:
            result += ord_current - ord_letter_min[0] + 10
            found_valid_chars_after_start = True
        elif ord_letter_min[1] <= ord_current <= ord_letter_max[1]:
            result += ord_current - ord_letter_min[1] + 10
            found_valid_chars_after_start = True
        elif _is_ascii_space(ord_current):
            has_space_after_number = True
            start = pos + 1
            break
        else:
            raise Error(_atol_error(base, str_ref))
        if pos + 1 < str_len and not _is_ascii_space(buff[pos + 1]):
            var nextresult = result * real_base
            if nextresult < result:
                raise Error(
                    _atol_error(base, str_ref)
                    + " String expresses an integer too large to store in Int."
                )
            result = nextresult

    if was_last_digit_undescore or (not found_valid_chars_after_start):
        raise Error(_atol_error(base, str_ref))

    if has_space_after_number:
        for pos in range(start, str_len):
            if not _is_ascii_space(buff[pos]):
                raise Error(_atol_error(base, str_ref))
    if is_negative:
        result = -result
    return result


fn _atol_error(base: Int, str_ref: StringSlice[_]) -> String:
    return (
        "String is not convertible to integer with base "
        + str(base)
        + ": '"
        + str(str_ref)
        + "'"
    )


fn _identify_base(str_ref: StringSlice[_], start: Int) -> Tuple[Int, Int]:
    var length = len(str_ref)
    # just 1 digit, assume base 10
    if start == (length - 1):
        return 10, start
    if str_ref[start] == "0":
        var second_digit = str_ref[start + 1]
        if second_digit == "b" or second_digit == "B":
            return 2, start + 2
        if second_digit == "o" or second_digit == "O":
            return 8, start + 2
        if second_digit == "x" or second_digit == "X":
            return 16, start + 2
        # checking for special case of all "0", "_" are also allowed
        var was_last_character_underscore = False
        for i in range(start + 1, length):
            if str_ref[i] == "_":
                if was_last_character_underscore:
                    return -1, -1
                else:
                    was_last_character_underscore = True
                    continue
            else:
                was_last_character_underscore = False
            if str_ref[i] != "0":
                return -1, -1
    elif ord("1") <= ord(str_ref[start]) <= ord("9"):
        return 10, start
    else:
        return -1, -1

    return 10, start


fn atol(str: String, base: Int = 10) raises -> Int:
    """Parses and returns the given string as an integer in the given base.

    For example, `atol("19")` returns `19`. If base is 0 the the string is
    parsed as an Integer literal, see: https://docs.python.org/3/reference/lexical_analysis.html#integers.

    Raises:
        If the given string cannot be parsed as an integer value. For example in
        `atol("hi")`.

    Args:
        str: A string to be parsed as an integer in the given base.
        base: Base used for conversion, value must be between 2 and 36, or 0.

    Returns:
        An integer value that represents the string, or otherwise raises.
    """
    return _atol(str.as_string_slice(), base)


fn _atof_error(str_ref: StringSlice[_]) -> Error:
    return Error("String is not convertible to float: '" + str(str_ref) + "'")


fn _atof(str_ref: StringSlice[_]) raises -> Float64:
    """Implementation of `atof` for StringRef inputs.

    Please see its docstring for details.
    """
    if not str_ref:
        raise _atof_error(str_ref)

    var result: Float64 = 0.0
    var exponent: Int = 0
    var sign: Int = 1

    alias ord_0 = UInt8(ord("0"))
    alias ord_9 = UInt8(ord("9"))
    alias ord_dot = UInt8(ord("."))
    alias ord_plus = UInt8(ord("+"))
    alias ord_minus = UInt8(ord("-"))
    alias ord_f = UInt8(ord("f"))
    alias ord_F = UInt8(ord("F"))
    alias ord_e = UInt8(ord("e"))
    alias ord_E = UInt8(ord("E"))

    var start: Int = 0
    var str_ref_strip = str_ref.strip()
    var str_len = len(str_ref_strip)
    var buff = str_ref_strip.unsafe_ptr()

    # check sign, inf, nan
    if buff[start] == ord_plus:
        start += 1
    elif buff[start] == ord_minus:
        start += 1
        sign = -1
    if (str_len - start) >= 3:
        if StringRef(buff + start, 3) == "nan":
            return FloatLiteral.nan
        if StringRef(buff + start, 3) == "inf":
            return FloatLiteral.infinity * sign
    # read before dot
    for pos in range(start, str_len):
        if ord_0 <= buff[pos] <= ord_9:
            result = result * 10.0 + int(buff[pos] - ord_0)
            start += 1
        else:
            break
    # if dot -> read after dot
    if buff[start] == ord_dot:
        start += 1
        for pos in range(start, str_len):
            if ord_0 <= buff[pos] <= ord_9:
                result = result * 10.0 + int(buff[pos] - ord_0)
                exponent -= 1
            else:
                break
            start += 1
    # if e/E -> read scientific notation
    if buff[start] == ord_e or buff[start] == ord_E:
        start += 1
        var sign: Int = 1
        var shift: Int = 0
        var has_number: Bool = False
        for pos in range(start, str_len):
            if buff[start] == ord_plus:
                pass
            elif buff[pos] == ord_minus:
                sign = -1
            elif ord_0 <= buff[start] <= ord_9:
                has_number = True
                shift = shift * 10 + int(buff[pos] - ord_0)
            else:
                break
            start += 1
        exponent += sign * shift
        if not has_number:
            raise _atof_error(str_ref)
    # check for f/F at the end
    if buff[start] == ord_f or buff[start] == ord_F:
        start += 1
    # check if string got fully parsed
    if start != str_len:
        raise _atof_error(str_ref)
    # apply shift
    # NOTE: Instead of `var result *= 10.0 ** exponent`, we calculate a positive
    # integer factor as shift and multiply or divide by it based on the shift
    # direction. This allows for better precision.
    # TODO: investigate if there is a floating point arithmetic problem.
    var shift: Int = 10 ** abs(exponent)
    if exponent > 0:
        result *= shift
    if exponent < 0:
        result /= shift
    # apply sign
    return result * sign


fn atof(str: String) raises -> Float64:
    """Parses the given string as a floating point and returns that value.

    For example, `atof("2.25")` returns `2.25`.

    Raises:
        If the given string cannot be parsed as an floating point value, for
        example in `atof("hi")`.

    Args:
        str: A string to be parsed as a floating point.

    Returns:
        An floating point value that represents the string, or otherwise raises.
    """
    return _atof(str.as_string_slice())


# ===----------------------------------------------------------------------=== #
# isupper
# ===----------------------------------------------------------------------=== #


@always_inline
fn isupper(c: UInt8) -> Bool:
    """Determines whether the given character is an ASCII uppercase character:
    `"ABCDEFGHIJKLMNOPQRSTUVWXYZ"`.

    Args:
        c: The character to check.

    Returns:
        True if the character is uppercase.
    """
    return _is_ascii_uppercase(c)


# ===----------------------------------------------------------------------=== #
# islower
# ===----------------------------------------------------------------------=== #


@always_inline
fn islower(c: UInt8) -> Bool:
    """Determines whether the given character is an ASCII lowercase character:
    `"abcdefghijklmnopqrstuvwxyz"`.

    Args:
        c: The character to check.

    Returns:
        True if the character is lowercase.
    """
    return _is_ascii_lowercase(c)


# ===----------------------------------------------------------------------=== #
# String
# ===----------------------------------------------------------------------=== #


@value
struct String(
    Sized,
    Stringable,
    AsBytes,
    Representable,
    IntableRaising,
    KeyElement,
    Comparable,
    Boolable,
    Writable,
    Writer,
    CollectionElementNew,
    FloatableRaising,
    _HashableWithHasher,
):
    """Represents a mutable string."""

    # Fields
    alias _buffer_type = List[UInt8, hint_trivial_type=True]
    var _buffer: Self._buffer_type
    """The underlying storage for the string."""

    """ Useful string aliases. """
    alias ASCII_LOWERCASE = String("abcdefghijklmnopqrstuvwxyz")
    alias ASCII_UPPERCASE = String("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    alias ASCII_LETTERS = String.ASCII_LOWERCASE + String.ASCII_UPPERCASE
    alias DIGITS = String("0123456789")
    alias HEX_DIGITS = String.DIGITS + String("abcdef") + String("ABCDEF")
    alias OCT_DIGITS = String("01234567")
    alias PUNCTUATION = String("""!"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~""")
    alias PRINTABLE = (
        String.DIGITS
        + String.ASCII_LETTERS
        + String.PUNCTUATION
        + " \t\n\r\v\f"  # single byte utf8 whitespaces
    )

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @always_inline
    fn __init__(inout self, owned impl: List[UInt8, *_]):
        """Construct a string from a buffer of bytes.

        The buffer must be terminated with a null byte:

        ```mojo
        var buf = List[UInt8]()
        buf.append(ord('H'))
        buf.append(ord('i'))
        buf.append(0)
        var hi = String(buf)
        ```

        Args:
            impl: The buffer.
        """
        debug_assert(
            len(impl) > 0 and impl[-1] == 0,
            "expected last element of String buffer to be null terminator",
        )
        # We make a backup because steal_data() will clear size and capacity.
        var size = impl.size
        var capacity = impl.capacity
        self._buffer = Self._buffer_type(
            unsafe_pointer=impl.steal_data(), size=size, capacity=capacity
        )

    @always_inline
    fn __init__(inout self):
        """Construct an uninitialized string."""
        self._buffer = Self._buffer_type()

    fn __init__(inout self, *, other: Self):
        """Explicitly copy the provided value.

        Args:
            other: The value to copy.
        """
        self.__copyinit__(other)

    fn __init__(inout self, str: StringRef):
        """Construct a string from a StringRef object.

        Args:
            str: The StringRef from which to construct this string object.
        """
        var length = len(str)
        var buffer = Self._buffer_type()
        # +1 for null terminator, initialized to 0
        buffer.resize(length + 1, 0)
        memcpy(dest=buffer.data, src=str.data, count=length)
        self = Self(buffer^)

    fn __init__(inout self, str_slice: StringSlice):
        """Construct a string from a string slice.

        This will allocate a new string that copies the string contents from
        the provided string slice `str_slice`.

        Args:
            str_slice: The string slice from which to construct this string.
        """

        # Calculate length in bytes
        var length: Int = len(str_slice.as_bytes())
        var buffer = Self._buffer_type()
        # +1 for null terminator, initialized to 0
        buffer.resize(length + 1, 0)
        memcpy(
            dest=buffer.data,
            src=str_slice.as_bytes().unsafe_ptr(),
            count=length,
        )
        self = Self(buffer^)

    @always_inline
    fn __init__(inout self, literal: StringLiteral):
        """Constructs a String value given a constant string.

        Args:
            literal: The input constant string.
        """
        self = literal.__str__()

    @always_inline
    fn __init__(inout self, ptr: UnsafePointer[UInt8], len: Int):
        """Creates a string from the buffer. Note that the string now owns
        the buffer.

        The buffer must be terminated with a null byte.

        Args:
            ptr: The pointer to the buffer.
            len: The length of the buffer, including the null terminator.
        """
        # we don't know the capacity of ptr, but we'll assume it's the same or
        # larger than len
        self = Self(
            Self._buffer_type(
                unsafe_pointer=ptr.bitcast[UInt8](), size=len, capacity=len
            )
        )

    # ===------------------------------------------------------------------=== #
    # Factory dunders
    # ===------------------------------------------------------------------=== #

    fn write_bytes(inout self, bytes: Span[Byte, _]):
        """
        Write a byte span to this String.

        Args:
            bytes: The byte span to write to this String. Must NOT be
              null terminated.
        """
        self._iadd[True](bytes)

    fn write[*Ts: Writable](inout self, *args: *Ts):
        """Write a sequence of Writable arguments to the provided Writer.

        Parameters:
            Ts: Types of the provided argument sequence.

        Args:
            args: Sequence of arguments to write to this Writer.
        """

        @parameter
        fn write_arg[T: Writable](arg: T):
            arg.write_to(self)

        args.each[write_arg]()

    @staticmethod
    @no_inline
    fn write[
        *Ts: Writable
    ](*args: *Ts, sep: StaticString = "", end: StaticString = "") -> Self:
        """
        Construct a string by concatenating a sequence of Writable arguments.

        Args:
            args: A sequence of Writable arguments.
            sep: The separator used between elements.
            end: The String to write after printing the elements.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
                `Writable`.

        Returns:
            A string formed by formatting the argument sequence.

        Examples:

        Construct a String from several `Writable` arguments:

        ```mojo
        var string = String.write(1, ", ", 2.0, ", ", "three")
        print(string) # "1, 2.0, three"
        %# from testing import assert_equal
        %# assert_equal(string, "1, 2.0, three")
        ```
        .
        """
        var output = String()
        write_args(output, args, sep=sep, end=end)
        return output^

    @staticmethod
    @no_inline
    fn write[
        *Ts: Writable
    ](
        args: VariadicPack[_, Writable, *Ts],
        sep: StaticString = "",
        end: StaticString = "",
    ) -> Self:
        """
        Construct a string by passing a variadic pack.

        Args:
            args: A VariadicPack of Writable arguments.
            sep: The separator used between elements.
            end: The String to write after printing the elements.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
                `Writable`.

        Returns:
            A string formed by formatting the VariadicPack.

        Examples:

        ```mojo
        fn variadic_pack_to_string[
            *Ts: Writable,
        ](*args: *Ts) -> String:
            return String.write(args)

        string = variadic_pack_to_string(1, ", ", 2.0, ", ", "three")
        %# from testing import assert_equal
        %# assert_equal(string, "1, 2.0, three")
        ```
        .
        """
        var output = String()
        write_args(output, args, sep=sep, end=end)
        return output^

    @staticmethod
    @always_inline
    fn _from_bytes(owned buff: UnsafePointer[UInt8]) -> String:
        """Construct a string from a sequence of bytes.

        This does no validation that the given bytes are valid in any specific
        String encoding.

        Args:
            buff: The buffer. This should have an existing terminator.
        """

        return String(buff, len(StringRef(buff)) + 1)

    @staticmethod
    fn _from_bytes(owned buff: Self._buffer_type) -> String:
        """Construct a string from a sequence of bytes.

        This does no validation that the given bytes are valid in any specific
        String encoding.

        Args:
            buff: The buffer.
        """

        # If a terminator does not already exist, then add it.
        if buff[-1]:
            buff.append(0)

        return String(buff^)

    # ===------------------------------------------------------------------=== #
    # Operator dunders
    # ===------------------------------------------------------------------=== #

    fn __getitem__[IndexerType: Indexer](self, idx: IndexerType) -> String:
        """Gets the character at the specified position.

        Parameters:
            IndexerType: The inferred type of an indexer argument.

        Args:
            idx: The index value.

        Returns:
            A new string containing the character at the specified position.
        """
        # TODO(#933): implement this for unicode when we support llvm intrinsic evaluation at compile time
        var normalized_idx = normalize_index["String"](idx, self)
        var buf = Self._buffer_type(capacity=1)
        buf.append(self._buffer[normalized_idx])
        buf.append(0)
        return String(buf^)

    fn __getitem__(self, span: Slice) -> String:
        """Gets the sequence of characters at the specified positions.

        Args:
            span: A slice that specifies positions of the new substring.

        Returns:
            A new string containing the string at the specified positions.
        """
        var start: Int
        var end: Int
        var step: Int
        # TODO(#933): implement this for unicode when we support llvm intrinsic evaluation at compile time

        start, end, step = span.indices(self.byte_length())
        var r = range(start, end, step)
        if step == 1:
            return StringRef(self._buffer.data + start, len(r))

        var buffer = Self._buffer_type()
        var result_len = len(r)
        buffer.resize(result_len + 1, 0)
        var ptr = self.unsafe_ptr()
        for i in range(result_len):
            buffer[i] = ptr[r[i]]
        buffer[result_len] = 0
        return Self(buffer^)

    @always_inline
    fn __eq__(self, other: String) -> Bool:
        """Compares two Strings if they have the same values.

        Args:
            other: The rhs of the operation.

        Returns:
            True if the Strings are equal and False otherwise.
        """
        return not (self != other)

    @always_inline
    fn __ne__(self, other: String) -> Bool:
        """Compares two Strings if they do not have the same values.

        Args:
            other: The rhs of the operation.

        Returns:
            True if the Strings are not equal and False otherwise.
        """
        return self._strref_dangerous() != other._strref_dangerous()

    @always_inline
    fn __lt__(self, rhs: String) -> Bool:
        """Compare this String to the RHS using LT comparison.

        Args:
            rhs: The other String to compare against.

        Returns:
            True if this String is strictly less than the RHS String and False
            otherwise.
        """
        return self.as_string_slice() < rhs.as_string_slice()

    @always_inline
    fn __le__(self, rhs: String) -> Bool:
        """Compare this String to the RHS using LE comparison.

        Args:
            rhs: The other String to compare against.

        Returns:
            True iff this String is less than or equal to the RHS String.
        """
        return not (rhs < self)

    @always_inline
    fn __gt__(self, rhs: String) -> Bool:
        """Compare this String to the RHS using GT comparison.

        Args:
            rhs: The other String to compare against.

        Returns:
            True iff this String is strictly greater than the RHS String.
        """
        return rhs < self

    @always_inline
    fn __ge__(self, rhs: String) -> Bool:
        """Compare this String to the RHS using GE comparison.

        Args:
            rhs: The other String to compare against.

        Returns:
            True iff this String is greater than or equal to the RHS String.
        """
        return not (self < rhs)

    @staticmethod
    fn _add[rhs_has_null: Bool](lhs: Span[Byte], rhs: Span[Byte]) -> String:
        var lhs_len = len(lhs)
        var rhs_len = len(rhs)
        var lhs_ptr = lhs.unsafe_ptr()
        var rhs_ptr = rhs.unsafe_ptr()
        alias S = StringSlice[ImmutableAnyOrigin]
        if lhs_len == 0:
            return String(S(unsafe_from_utf8_ptr=rhs_ptr, len=rhs_len))
        elif rhs_len == 0:
            return String(S(unsafe_from_utf8_ptr=lhs_ptr, len=lhs_len))
        var sum_len = lhs_len + rhs_len
        var buffer = Self._buffer_type(capacity=sum_len + 1)
        var ptr = buffer.unsafe_ptr()
        memcpy(ptr, lhs_ptr, lhs_len)
        memcpy(ptr + lhs_len, rhs_ptr, rhs_len + int(rhs_has_null))
        buffer.size = sum_len + 1

        @parameter
        if not rhs_has_null:
            ptr[sum_len] = 0
        return Self(buffer^)

    @always_inline
    fn __add__(self, other: String) -> String:
        """Creates a string by appending another string at the end.

        Args:
            other: The string to append.

        Returns:
            The new constructed string.
        """
        return Self._add[True](self.as_bytes(), other.as_bytes())

    @always_inline
    fn __add__(self, other: StringLiteral) -> String:
        """Creates a string by appending a string literal at the end.

        Args:
            other: The string literal to append.

        Returns:
            The new constructed string.
        """
        return Self._add[False](self.as_bytes(), other.as_bytes())

    @always_inline
    fn __add__(self, other: StringSlice) -> String:
        """Creates a string by appending a string slice at the end.

        Args:
            other: The string slice to append.

        Returns:
            The new constructed string.
        """
        return Self._add[False](self.as_bytes(), other.as_bytes())

    @always_inline
    fn __radd__(self, other: String) -> String:
        """Creates a string by prepending another string to the start.

        Args:
            other: The string to prepend.

        Returns:
            The new constructed string.
        """
        return Self._add[True](other.as_bytes(), self.as_bytes())

    @always_inline
    fn __radd__(self, other: StringLiteral) -> String:
        """Creates a string by prepending another string literal to the start.

        Args:
            other: The string to prepend.

        Returns:
            The new constructed string.
        """
        return Self._add[True](other.as_bytes(), self.as_bytes())

    @always_inline
    fn __radd__(self, other: StringSlice) -> String:
        """Creates a string by prepending another string slice to the start.

        Args:
            other: The string to prepend.

        Returns:
            The new constructed string.
        """
        return Self._add[True](other.as_bytes(), self.as_bytes())

    fn _iadd[has_null: Bool](inout self, other: Span[Byte]):
        var s_len = self.byte_length()
        var o_len = len(other)
        var o_ptr = other.unsafe_ptr()
        if s_len == 0:
            alias S = StringSlice[ImmutableAnyOrigin]
            self = String(S(unsafe_from_utf8_ptr=o_ptr, len=o_len))
            return
        elif o_len == 0:
            return
        var sum_len = s_len + o_len
        self._buffer.reserve(sum_len + 1)
        var s_ptr = self.unsafe_ptr()
        memcpy(s_ptr + s_len, o_ptr, o_len + int(has_null))
        self._buffer.size = sum_len + 1

        @parameter
        if not has_null:
            s_ptr[sum_len] = 0

    @always_inline
    fn __iadd__(inout self, other: String):
        """Appends another string to this string.

        Args:
            other: The string to append.
        """
        self._iadd[True](other.as_bytes())

    @always_inline
    fn __iadd__(inout self, other: StringLiteral):
        """Appends another string literal to this string.

        Args:
            other: The string to append.
        """
        self._iadd[False](other.as_bytes())

    @always_inline
    fn __iadd__(inout self, other: StringSlice):
        """Appends another string slice to this string.

        Args:
            other: The string to append.
        """
        self._iadd[False](other.as_bytes())

    fn __iter__(self) -> _StringSliceIter[__origin_of(self)]:
        """Iterate over the string, returning immutable references.

        Returns:
            An iterator of references to the string elements.
        """
        return _StringSliceIter[__origin_of(self)](
            unsafe_pointer=self.unsafe_ptr(), length=self.byte_length()
        )

    fn __reversed__(self) -> _StringSliceIter[__origin_of(self), False]:
        """Iterate backwards over the string, returning immutable references.

        Returns:
            A reversed iterator of references to the string elements.
        """
        return _StringSliceIter[__origin_of(self), forward=False](
            unsafe_pointer=self.unsafe_ptr(), length=self.byte_length()
        )

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @always_inline
    fn __bool__(self) -> Bool:
        """Checks if the string is not empty.

        Returns:
            True if the string length is greater than zero, and False otherwise.
        """
        return self.byte_length() > 0

    fn __len__(self) -> Int:
        """Gets the string length, in bytes (for now) PREFER:
        String.byte_length(), a future version will make this method return
        Unicode codepoints.

        Returns:
            The string length, in bytes (for now).
        """
        var unicode_length = self.byte_length()

        # TODO: everything uses this method assuming it's byte length
        # for i in range(unicode_length):
        #     if _utf8_byte_type(self._buffer[i]) == 1:
        #         unicode_length -= 1

        return unicode_length

    @always_inline
    fn __str__(self) -> String:
        """Gets the string itself.

        Returns:
            The string itself.

        Notes:
            This method ensures that you can pass a `String` to a method that
            takes a `Stringable` value.
        """
        return self

    fn __repr__(self) -> String:
        """Return a representation of the string instance. You don't need to
        call this method directly, use `repr("...")` instead.

        Returns:
            A new representation of the string.
        """
        return ascii(self)

    fn __ascii__(self) -> String:
        """Get the ASCII representation of the object. You don't need to call
        this method directly, use `ascii("...")` instead.

        Returns:
            A string containing the ASCII representation of the object.
        """
        return ascii(self)

    fn __fspath__(self) -> String:
        """Return the file system path representation (just the string itself).

        Returns:
          The file system path representation as a string.
        """
        return self

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    fn write_to[W: Writer](self, inout writer: W):
        """
        Formats this string to the provided Writer.

        Parameters:
            W: A type conforming to the Writable trait.

        Args:
            writer: The object to write to.
        """

        writer.write_bytes(self.as_bytes())

    fn join(self, *elems: Int) -> String:
        """Joins the elements from the tuple using the current string as a
        delimiter.

        Args:
            elems: The input tuple.

        Returns:
            The joined string.
        """
        if len(elems) == 0:
            return ""
        var curr = str(elems[0])
        for i in range(1, len(elems)):
            curr += self + str(elems[i])
        return curr

    fn join[*Types: Writable](self, *elems: *Types) -> String:
        """Joins string elements using the current string as a delimiter.

        Parameters:
            Types: The types of the elements.

        Args:
            elems: The input values.

        Returns:
            The joined string.
        """

        var result = String()
        var is_first = True

        @parameter
        fn add_elt[T: Writable](a: T):
            if is_first:
                is_first = False
            else:
                result.write(self)
            result.write(a)

        elems.each[add_elt]()
        _ = is_first
        return result

    fn join[T: StringableCollectionElement](self, elems: List[T, *_]) -> String:
        """Joins string elements using the current string as a delimiter.

        Parameters:
            T: The types of the elements.

        Args:
            elems: The input values.

        Returns:
            The joined string.
        """

        # TODO(#3403): Simplify this when the linked conditional conformance
        # feature is added.  Runs a faster algorithm if the concrete types are
        # able to be converted to a span of bytes.
        @parameter
        if _type_is_eq[T, String]():
            return self.fast_join(rebind[List[String]](elems))
        elif _type_is_eq[T, StringLiteral]():
            return self.fast_join(rebind[List[StringLiteral]](elems))
        # FIXME(#3597): once StringSlice conforms to CollectionElement trait:
        # if _type_is_eq[T, StringSlice]():
        # return self.fast_join(rebind[List[StringSlice]](elems))
        else:
            var result: String = ""
            var is_first = True

            for e in elems:
                if is_first:
                    is_first = False
                else:
                    result += self
                result += str(e[])

            return result

    fn fast_join[
        T: BytesCollectionElement, //,
    ](self, elems: List[T, *_]) -> String:
        """Joins string elements using the current string as a delimiter.

        Parameters:
            T: The types of the elements.

        Args:
            elems: The input values.

        Returns:
            The joined string.
        """
        var n_elems = len(elems)
        if n_elems == 0:
            return String("")
        var len_self = self.byte_length()
        var len_elems = 0
        # Calculate the total size of the elements to join beforehand
        # to prevent alloc syscalls as we know the buffer size.
        # This can hugely improve the performance on large lists
        for e_ref in elems:
            len_elems += len(e_ref[].as_bytes())
        var capacity = len_self * (n_elems - 1) + len_elems
        var buf = Self._buffer_type(capacity=capacity)
        var self_ptr = self.unsafe_ptr()
        var ptr = buf.unsafe_ptr()
        var offset = 0
        var i = 0
        var is_first = True
        while i < n_elems:
            if is_first:
                is_first = False
            else:
                memcpy(dest=ptr + offset, src=self_ptr, count=len_self)
                offset += len_self
            var e = elems[i].as_bytes()
            var e_len = len(e)
            memcpy(dest=ptr + offset, src=e.unsafe_ptr(), count=e_len)
            offset += e_len
            i += 1
        buf.size = capacity
        buf.append(0)
        return String(buf^)

    fn _strref_dangerous(self) -> StringRef:
        """
        Returns an inner pointer to the string as a StringRef.
        This functionality is extremely dangerous because Mojo eagerly releases
        strings.  Using this requires the use of the _strref_keepalive() method
        to keep the underlying string alive long enough.
        """
        return StringRef(self.unsafe_ptr(), self.byte_length())

    fn _strref_keepalive(self):
        """
        A noop that keeps `self` alive through the call.  This
        can be carefully used with `_strref_dangerous()` to wield inner pointers
        without the string getting deallocated early.
        """
        pass

    fn unsafe_ptr(self) -> UnsafePointer[UInt8]:
        """Retrieves a pointer to the underlying memory.

        Returns:
            The pointer to the underlying memory.
        """
        return self._buffer.data

    fn unsafe_cstr_ptr(self) -> UnsafePointer[c_char]:
        """Retrieves a C-string-compatible pointer to the underlying memory.

        The returned pointer is guaranteed to be null, or NUL terminated.

        Returns:
            The pointer to the underlying memory.
        """
        return self.unsafe_ptr().bitcast[c_char]()

    @always_inline
    fn as_bytes(ref [_]self) -> Span[Byte, __origin_of(self)]:
        """Returns a contiguous slice of the bytes owned by this string.

        Returns:
            A contiguous slice pointing to the bytes owned by this string.

        Notes:
            This does not include the trailing null terminator.
        """

        # Does NOT include the NUL terminator.
        return Span[Byte, __origin_of(self)](
            unsafe_ptr=self._buffer.unsafe_ptr(), len=self.byte_length()
        )

    @always_inline
    fn as_string_slice(ref [_]self) -> StringSlice[__origin_of(self)]:
        """Returns a string slice of the data owned by this string.

        Returns:
            A string slice pointing to the data owned by this string.
        """
        # FIXME(MSTDL-160):
        #   Enforce UTF-8 encoding in String so this is actually
        #   guaranteed to be valid.
        return StringSlice(unsafe_from_utf8=self.as_bytes())

    @always_inline
    fn byte_length(self) -> Int:
        """Get the string length in bytes.

        Returns:
            The length of this string in bytes, excluding null terminator.

        Notes:
            This does not include the trailing null terminator in the count.
        """
        var length = len(self._buffer)
        return length - int(length > 0)

    fn _steal_ptr(inout self) -> UnsafePointer[UInt8]:
        """Transfer ownership of pointer to the underlying memory.
        The caller is responsible for freeing up the memory.

        Returns:
            The pointer to the underlying memory.
        """
        var ptr = self.unsafe_ptr()
        self._buffer.data = UnsafePointer[UInt8]()
        self._buffer.size = 0
        self._buffer.capacity = 0
        return ptr

    fn count(self, substr: String) -> Int:
        """Return the number of non-overlapping occurrences of substring
        `substr` in the string.

        If sub is empty, returns the number of empty strings between characters
        which is the length of the string plus one.

        Args:
          substr: The substring to count.

        Returns:
          The number of occurrences of `substr`.
        """
        if not substr:
            return len(self) + 1

        var res = 0
        var offset = 0

        while True:
            var pos = self.find(substr, offset)
            if pos == -1:
                break
            res += 1

            offset = pos + substr.byte_length()

        return res

    fn __contains__(self, substr: String) -> Bool:
        """Returns True if the substring is contained within the current string.

        Args:
          substr: The substring to check.

        Returns:
          True if the string contains the substring.
        """
        return substr.as_string_slice() in self.as_string_slice()

    fn find(self, substr: String, start: Int = 0) -> Int:
        """Finds the offset of the first occurrence of `substr` starting at
        `start`. If not found, returns -1.

        Args:
          substr: The substring to find.
          start: The offset from which to find.

        Returns:
          The offset of `substr` relative to the beginning of the string.
        """

        return self.as_string_slice().find(substr.as_string_slice(), start)

    fn rfind(self, substr: String, start: Int = 0) -> Int:
        """Finds the offset of the last occurrence of `substr` starting at
        `start`. If not found, returns -1.

        Args:
          substr: The substring to find.
          start: The offset from which to find.

        Returns:
          The offset of `substr` relative to the beginning of the string.
        """

        return self.as_string_slice().rfind(
            substr.as_string_slice(), start=start
        )

    fn isspace(self) -> Bool:
        """Determines whether every character in the given String is a
        python whitespace String. This corresponds to Python's
        [universal separators](
            https://docs.python.org/3/library/stdtypes.html#str.splitlines)
        `" \\t\\n\\r\\f\\v\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Returns:
            True if the whole String is made up of whitespace characters
                listed above, otherwise False.
        """
        return self.as_string_slice().isspace()

    fn split(self, sep: String, maxsplit: Int = -1) raises -> List[String]:
        """Split the string by a separator.

        Args:
            sep: The string to split on.
            maxsplit: The maximum amount of items to split from String.
                Defaults to unlimited.

        Returns:
            A List of Strings containing the input split by the separator.

        Raises:
            If the separator is empty.

        Examples:

        ```mojo
        # Splitting a space
        _ = String("hello world").split(" ") # ["hello", "world"]
        # Splitting adjacent separators
        _ = String("hello,,world").split(",") # ["hello", "", "world"]
        # Splitting with maxsplit
        _ = String("1,2,3").split(",", 1) # ['1', '2,3']
        ```
        .
        """
        var output = List[String]()

        var str_byte_len = self.byte_length() - 1
        var lhs = 0
        var rhs = 0
        var items = 0
        var sep_len = sep.byte_length()
        if sep_len == 0:
            raise Error("Separator cannot be empty.")
        if str_byte_len < 0:
            output.append("")

        while lhs <= str_byte_len:
            rhs = self.find(sep, lhs)
            if rhs == -1:
                output.append(self[lhs:])
                break

            if maxsplit > -1:
                if items == maxsplit:
                    output.append(self[lhs:])
                    break
                items += 1

            output.append(self[lhs:rhs])
            lhs = rhs + sep_len

        if self.endswith(sep) and (len(output) <= maxsplit or maxsplit == -1):
            output.append("")
        return output

    fn split(self, sep: NoneType = None, maxsplit: Int = -1) -> List[String]:
        """Split the string by every Whitespace separator.

        Args:
            sep: None.
            maxsplit: The maximum amount of items to split from String. Defaults
                to unlimited.

        Returns:
            A List of Strings containing the input split by the separator.

        Examples:

        ```mojo
        # Splitting an empty string or filled with whitespaces
        _ = String("      ").split() # []
        _ = String("").split() # []

        # Splitting a string with leading, trailing, and middle whitespaces
        _ = String("      hello    world     ").split() # ["hello", "world"]
        # Splitting adjacent universal newlines:
        _ = String(
            "hello \\t\\n\\r\\f\\v\\x1c\\x1d\\x1e\\x85\\u2028\\u2029world"
        ).split()  # ["hello", "world"]
        ```
        .
        """

        fn num_bytes(b: UInt8) -> Int:
            var flipped = ~b
            return int(count_leading_zeros(flipped) + (flipped >> 7))

        var output = List[String]()
        var str_byte_len = self.byte_length() - 1
        var lhs = 0
        var rhs = 0
        var items = 0
        while lhs <= str_byte_len:
            # Python adds all "whitespace chars" as one separator
            # if no separator was specified
            for s in self[lhs:]:
                if not str(s).isspace():  # TODO: with StringSlice.isspace()
                    break
                lhs += s.byte_length()
            # if it went until the end of the String, then
            # it should be sliced up until the original
            # start of the whitespace which was already appended
            if lhs - 1 == str_byte_len:
                break
            elif lhs == str_byte_len:
                # if the last char is not whitespace
                output.append(self[str_byte_len])
                break
            rhs = lhs + num_bytes(self.unsafe_ptr()[lhs])
            for s in self[lhs + num_bytes(self.unsafe_ptr()[lhs]) :]:
                if str(s).isspace():  # TODO: with StringSlice.isspace()
                    break
                rhs += s.byte_length()

            if maxsplit > -1:
                if items == maxsplit:
                    output.append(self[lhs:])
                    break
                items += 1

            output.append(self[lhs:rhs])
            lhs = rhs

        return output

    fn splitlines(self, keepends: Bool = False) -> List[String]:
        """Split the string at line boundaries. This corresponds to Python's
        [universal newlines](
            https://docs.python.org/3/library/stdtypes.html#str.splitlines)
        `"\\t\\n\\r\\r\\n\\f\\v\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Args:
            keepends: If True, line breaks are kept in the resulting strings.

        Returns:
            A List of Strings containing the input split by line boundaries.
        """
        return self.as_string_slice().splitlines(keepends)

    fn replace(self, old: String, new: String) -> String:
        """Return a copy of the string with all occurrences of substring `old`
        if replaced by `new`.

        Args:
            old: The substring to replace.
            new: The substring to replace with.

        Returns:
            The string where all occurrences of `old` are replaced with `new`.
        """
        if not old:
            return self._interleave(new)

        var occurrences = self.count(old)
        if occurrences == -1:
            return self

        var self_start = self.unsafe_ptr()
        var self_ptr = self.unsafe_ptr()
        var new_ptr = new.unsafe_ptr()

        var self_len = self.byte_length()
        var old_len = old.byte_length()
        var new_len = new.byte_length()

        var res = Self._buffer_type()
        res.reserve(self_len + (old_len - new_len) * occurrences + 1)

        for _ in range(occurrences):
            var curr_offset = int(self_ptr) - int(self_start)

            var idx = self.find(old, curr_offset)

            debug_assert(idx >= 0, "expected to find occurrence during find")

            # Copy preceding unchanged chars
            for _ in range(curr_offset, idx):
                res.append(self_ptr[])
                self_ptr += 1

            # Insert a copy of the new replacement string
            for i in range(new_len):
                res.append(new_ptr[i])

            self_ptr += old_len

        while True:
            var val = self_ptr[]
            if val == 0:
                break
            res.append(self_ptr[])
            self_ptr += 1

        res.append(0)
        return String(res^)

    fn strip(self, chars: String) -> String:
        """Return a copy of the string with leading and trailing characters
        removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no leading or trailing characters.
        """

        return self.lstrip(chars).rstrip(chars)

    fn strip(self) -> String:
        """Return a copy of the string with leading and trailing whitespaces
        removed.

        Returns:
            A copy of the string with no leading or trailing whitespaces.
        """
        return self.lstrip().rstrip()

    fn rstrip(self, chars: String) -> String:
        """Return a copy of the string with trailing characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no trailing characters.
        """

        var r_idx = self.byte_length()
        while r_idx > 0 and self[r_idx - 1] in chars:
            r_idx -= 1

        return self[:r_idx]

    fn rstrip(self) -> String:
        """Return a copy of the string with trailing whitespaces removed.

        Returns:
            A copy of the string with no trailing whitespaces.
        """
        var r_idx = self.byte_length()
        # TODO (#933): should use this once llvm intrinsics can be used at comp time
        # for s in self.__reversed__():
        #     if not s.isspace():
        #         break
        #     r_idx -= 1
        while r_idx > 0 and _is_ascii_space(self._buffer.unsafe_get(r_idx - 1)):
            r_idx -= 1
        return self[:r_idx]

    fn lstrip(self, chars: String) -> String:
        """Return a copy of the string with leading characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no leading characters.
        """

        var l_idx = 0
        while l_idx < self.byte_length() and self[l_idx] in chars:
            l_idx += 1

        return self[l_idx:]

    fn lstrip(self) -> String:
        """Return a copy of the string with leading whitespaces removed.

        Returns:
            A copy of the string with no leading whitespaces.
        """
        var l_idx = 0
        # TODO (#933): should use this once llvm intrinsics can be used at comp time
        # for s in self:
        #     if not s.isspace():
        #         break
        #     l_idx += 1
        while l_idx < self.byte_length() and _is_ascii_space(
            self._buffer.unsafe_get(l_idx)
        ):
            l_idx += 1
        return self[l_idx:]

    fn __hash__(self) -> UInt:
        """Hash the underlying buffer using builtin hash.

        Returns:
            A 64-bit hash value. This value is _not_ suitable for cryptographic
            uses. Its intended usage is for data structures. See the `hash`
            builtin documentation for more details.
        """
        return hash(self.as_string_slice())

    fn __hash__[H: _Hasher](self, inout hasher: H):
        """Updates hasher with the underlying bytes.

        Parameters:
            H: The hasher type.

        Args:
            hasher: The hasher instance.
        """
        hasher._update_with_bytes(self.unsafe_ptr(), self.byte_length())

    fn _interleave(self, val: String) -> String:
        var res = Self._buffer_type()
        var val_ptr = val.unsafe_ptr()
        var self_ptr = self.unsafe_ptr()
        res.reserve(val.byte_length() * self.byte_length() + 1)
        for i in range(self.byte_length()):
            for j in range(val.byte_length()):
                res.append(val_ptr[j])
            res.append(self_ptr[i])
        res.append(0)
        return String(res^)

    fn lower(self) -> String:
        """Returns a copy of the string with all ASCII cased characters
        converted to lowercase.

        Returns:
            A new string where cased letters have been converted to lowercase.
        """

        # TODO(#26444):
        # Support the Unicode standard casing behavior to handle cased letters
        # outside of the standard ASCII letters.
        return self._toggle_ascii_case[_is_ascii_uppercase]()

    fn upper(self) -> String:
        """Returns a copy of the string with all ASCII cased characters
        converted to uppercase.

        Returns:
            A new string where cased letters have been converted to uppercase.
        """

        # TODO(#26444):
        # Support the Unicode standard casing behavior to handle cased letters
        # outside of the standard ASCII letters.
        return self._toggle_ascii_case[_is_ascii_lowercase]()

    fn _toggle_ascii_case[check_case: fn (UInt8) -> Bool](self) -> String:
        var copy: String = self

        var char_ptr = copy.unsafe_ptr()

        for i in range(self.byte_length()):
            var char: UInt8 = char_ptr[i]
            if check_case(char):
                var lower = _toggle_ascii_case(char)
                char_ptr[i] = lower

        return copy

    fn startswith(
        ref [_]self, prefix: String, start: Int = 0, end: Int = -1
    ) -> Bool:
        """Checks if the string starts with the specified prefix between start
        and end positions. Returns True if found and False otherwise.

        Args:
          prefix: The prefix to check.
          start: The start offset from which to check.
          end: The end offset from which to check.

        Returns:
          True if the self[start:end] is prefixed by the input prefix.
        """
        if end == -1:
            return StringSlice[__origin_of(self)](
                unsafe_from_utf8_ptr=self.unsafe_ptr() + start,
                len=self.byte_length() - start,
            ).startswith(prefix.as_string_slice())

        return StringSlice[__origin_of(self)](
            unsafe_from_utf8_ptr=self.unsafe_ptr() + start, len=end - start
        ).startswith(prefix.as_string_slice())

    fn endswith(self, suffix: String, start: Int = 0, end: Int = -1) -> Bool:
        """Checks if the string end with the specified suffix between start
        and end positions. Returns True if found and False otherwise.

        Args:
          suffix: The suffix to check.
          start: The start offset from which to check.
          end: The end offset from which to check.

        Returns:
          True if the self[start:end] is suffixed by the input suffix.
        """
        if end == -1:
            return StringSlice[__origin_of(self)](
                unsafe_from_utf8_ptr=self.unsafe_ptr() + start,
                len=self.byte_length() - start,
            ).endswith(suffix.as_string_slice())

        return StringSlice[__origin_of(self)](
            unsafe_from_utf8_ptr=self.unsafe_ptr() + start, len=end - start
        ).endswith(suffix.as_string_slice())

    fn removeprefix(self, prefix: String, /) -> String:
        """Returns a new string with the prefix removed if it was present.

        For example:

        ```mojo
        print(String('TestHook').removeprefix('Test'))
        # 'Hook'
        print(String('BaseTestCase').removeprefix('Test'))
        # 'BaseTestCase'
        ```

        Args:
            prefix: The prefix to remove from the string.

        Returns:
            `string[len(prefix):]` if the string starts with the prefix string,
            or a copy of the original string otherwise.
        """
        if self.startswith(prefix):
            return self[prefix.byte_length() :]
        return self

    fn removesuffix(self, suffix: String, /) -> String:
        """Returns a new string with the suffix removed if it was present.

        For example:

        ```mojo
        print(String('TestHook').removesuffix('Hook'))
        # 'Test'
        print(String('BaseTestCase').removesuffix('Test'))
        # 'BaseTestCase'
        ```

        Args:
            suffix: The suffix to remove from the string.

        Returns:
            `string[:-len(suffix)]` if the string ends with the suffix string,
            or a copy of the original string otherwise.
        """
        if suffix and self.endswith(suffix):
            return self[: -suffix.byte_length()]
        return self

    @always_inline
    fn __int__(self) raises -> Int:
        """Parses the given string as a base-10 integer and returns that value.
        If the string cannot be parsed as an int, an error is raised.

        Returns:
            An integer value that represents the string, or otherwise raises.
        """
        return atol(self)

    @always_inline
    fn __float__(self) raises -> Float64:
        """Parses the string as a float point number and returns that value. If
        the string cannot be parsed as a float, an error is raised.

        Returns:
            A float value that represents the string, or otherwise raises.
        """
        return atof(self)

    fn __mul__(self, n: Int) -> String:
        """Concatenates the string `n` times.

        Args:
            n : The number of times to concatenate the string.

        Returns:
            The string concatenated `n` times.
        """
        if n <= 0:
            return ""
        var len_self = self.byte_length()
        var count = len_self * n + 1
        var buf = Self._buffer_type(capacity=count)
        buf.resize(count, 0)
        for i in range(n):
            memcpy(
                dest=buf.data + len_self * i,
                src=self.unsafe_ptr(),
                count=len_self,
            )
        return String(buf^)

    @always_inline
    fn format[*Ts: _CurlyEntryFormattable](self, *args: *Ts) raises -> String:
        """Format a template with `*args`.

        Args:
            args: The substitution values.

        Parameters:
            Ts: The types of substitution values that implement `Representable`
                and `Stringable` (to be changed and made more flexible).

        Returns:
            The template with the given values substituted.

        Examples:

        ```mojo
        # Manual indexing:
        print(String("{0} {1} {0}").format("Mojo", 1.125)) # Mojo 1.125 Mojo
        # Automatic indexing:
        print(String("{} {}").format(True, "hello world")) # True hello world
        ```
        .
        """
        return _FormatCurlyEntry.format(self, args)

    fn isdigit(self) -> Bool:
        """A string is a digit string if all characters in the string are digits
        and there is at least one character in the string.

        Note that this currently only works with ASCII strings.

        Returns:
            True if all characters are digits and it's not empty else False.
        """
        if not self:
            return False
        for c in self:
            if not isdigit(ord(c)):
                return False
        return True

    fn _isupper_islower[*, upper: Bool](self) -> Bool:
        fn is_ascii_cased(c: UInt8) -> Bool:
            return _is_ascii_uppercase(c) or _is_ascii_lowercase(c)

        for c in self:
            debug_assert(c.byte_length() == 1, "only implemented for ASCII")
            if is_ascii_cased(ord(c)):

                @parameter
                if upper:
                    return self == self.upper()
                else:
                    return self == self.lower()
        return False

    fn isupper(self) -> Bool:
        """Returns True if all cased characters in the string are uppercase and
        there is at least one cased character.

        Note that this currently only works with ASCII strings.

        Returns:
            True if all cased characters in the string are uppercase and there
            is at least one cased character, False otherwise.
        """
        return self._isupper_islower[upper=True]()

    fn islower(self) -> Bool:
        """Returns True if all cased characters in the string are lowercase and
        there is at least one cased character.

        Note that this currently only works with ASCII strings.

        Returns:
            True if all cased characters in the string are lowercase and there
            is at least one cased character, False otherwise.
        """
        return self._isupper_islower[upper=False]()

    fn isprintable(self) -> Bool:
        """Returns True if all characters in the string are ASCII printable.

        Note that this currently only works with ASCII strings.

        Returns:
            True if all characters are printable else False.
        """
        return isprintable(self.as_bytes())

    fn rjust(self, width: Int, fillchar: StringLiteral = " ") -> String:
        """Returns the string right justified in a string of specified width.

        Args:
            width: The width of the field containing the string.
            fillchar: Specifies the padding character.

        Returns:
            Returns right justified string, or self if width is not bigger than self length.
        """
        return self._justify(width - len(self), width, fillchar)

    fn ljust(self, width: Int, fillchar: StringLiteral = " ") -> String:
        """Returns the string left justified in a string of specified width.

        Args:
            width: The width of the field containing the string.
            fillchar: Specifies the padding character.

        Returns:
            Returns left justified string, or self if width is not bigger than self length.
        """
        return self._justify(0, width, fillchar)

    fn center(self, width: Int, fillchar: StringLiteral = " ") -> String:
        """Returns the string center justified in a string of specified width.

        Args:
            width: The width of the field containing the string.
            fillchar: Specifies the padding character.

        Returns:
            Returns center justified string, or self if width is not bigger than self length.
        """
        return self._justify(width - len(self) >> 1, width, fillchar)

    fn _justify(
        self, start: Int, width: Int, fillchar: StringLiteral
    ) -> String:
        if len(self) >= width:
            return self
        debug_assert(
            len(fillchar) == 1, "fill char needs to be a one byte literal"
        )
        var fillbyte = fillchar.as_bytes()[0]
        var buffer = Self._buffer_type(capacity=width + 1)
        buffer.resize(width, fillbyte)
        buffer.append(0)
        memcpy(buffer.unsafe_ptr().offset(start), self.unsafe_ptr(), len(self))
        var result = String(buffer)
        return result^


# ===----------------------------------------------------------------------=== #
# Utilities
# ===----------------------------------------------------------------------=== #


fn _toggle_ascii_case(char: UInt8) -> UInt8:
    """Assuming char is a cased ASCII character, this function will return the
    opposite-cased letter.
    """

    # ASCII defines A-Z and a-z as differing only in their 6th bit,
    # so converting is as easy as a bit flip.
    return char ^ (1 << 5)


fn _calc_initial_buffer_size_int32(n0: Int) -> Int:
    # See https://commaok.xyz/post/lookup_tables/ and
    # https://lemire.me/blog/2021/06/03/computing-the-number-of-digits-of-an-integer-even-faster/
    # for a description.
    alias lookup_table = VariadicList[Int](
        4294967296,
        8589934582,
        8589934582,
        8589934582,
        12884901788,
        12884901788,
        12884901788,
        17179868184,
        17179868184,
        17179868184,
        21474826480,
        21474826480,
        21474826480,
        21474826480,
        25769703776,
        25769703776,
        25769703776,
        30063771072,
        30063771072,
        30063771072,
        34349738368,
        34349738368,
        34349738368,
        34349738368,
        38554705664,
        38554705664,
        38554705664,
        41949672960,
        41949672960,
        41949672960,
        42949672960,
        42949672960,
    )
    var n = UInt32(n0)
    var log2 = int(
        (bitwidthof[DType.uint32]() - 1) ^ count_leading_zeros(n | 1)
    )
    return (n0 + lookup_table[int(log2)]) >> 32


fn _calc_initial_buffer_size_int64(n0: UInt64) -> Int:
    var result: Int = 1
    var n = n0
    while True:
        if n < 10:
            return result
        if n < 100:
            return result + 1
        if n < 1_000:
            return result + 2
        if n < 10_000:
            return result + 3
        n //= 10_000
        result += 4


fn _calc_initial_buffer_size(n0: Int) -> Int:
    var sign = 0 if n0 > 0 else 1

    # Add 1 for the terminator
    return sign + n0._decimal_digit_count() + 1


fn _calc_initial_buffer_size(n: Float64) -> Int:
    return 128 + 1  # Add 1 for the terminator


fn _calc_initial_buffer_size[type: DType](n0: Scalar[type]) -> Int:
    @parameter
    if type.is_integral():
        var n = abs(n0)
        var sign = 0 if n0 > 0 else 1
        alias is_32bit_system = bitwidthof[DType.index]() == 32

        @parameter
        if is_32bit_system or bitwidthof[type]() <= 32:
            return sign + _calc_initial_buffer_size_int32(int(n)) + 1
        else:
            return (
                sign
                + _calc_initial_buffer_size_int64(n.cast[DType.uint64]())
                + 1
            )

    return 128 + 1  # Add 1 for the terminator


fn _calc_format_buffer_size[type: DType]() -> Int:
    """
    Returns a buffer size in bytes that is large enough to store a formatted
    number of the specified type.
    """

    # TODO:
    #   Use a smaller size based on the `dtype`, e.g. we don't need as much
    #   space to store a formatted int8 as a float64.
    @parameter
    if type.is_integral():
        return 64 + 1
    else:
        return 128 + 1  # Add 1 for the terminator
