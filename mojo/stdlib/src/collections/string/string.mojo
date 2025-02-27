# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
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
"""Implements basic object methods for working with strings."""

from collections import KeyElement, List, Optional
from collections._index_normalization import normalize_index
from collections.string import CodepointsIter
from collections.string.format import _CurlyEntryFormattable, _FormatCurlyEntry
from collections.string.string_slice import (
    StaticString,
    StringSlice,
    CodepointSliceIter,
    _to_string_list,
    _utf8_byte_type,
)
from collections.string._unicode import (
    is_lowercase,
    is_uppercase,
    to_lowercase,
    to_uppercase,
)
from hashlib._hasher import _HashableWithHasher, _Hasher
from os import abort
from sys import bitwidthof, llvm_intrinsic
from sys.ffi import c_char
from sys.intrinsics import _type_is_eq

from bit import count_leading_zeros
from memory import Span, UnsafePointer, memcmp, memcpy
from python import PythonObject

from utils import IndexList, Variant, Writable, Writer, write_args
from utils.write import _TotalWritableBytes, _WriteBufferHeap, write_buffered

# ===----------------------------------------------------------------------=== #
# ord
# ===----------------------------------------------------------------------=== #


fn ord(s: StringSlice) -> Int:
    """Returns an integer that represents the codepoint of a single-character
    string.

    Given a string containing a single character `Codepoint`, return an integer
    representing the codepoint of that character. For example, `ord("a")`
    returns the integer `97`. This is the inverse of the `chr()` function.

    Args:
        s: The input string, which must contain only a single- character.

    Returns:
        An integer representing the code point of the given character.
    """
    return Int(Codepoint.ord(s))


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
    print(chr(97), chr(8364)) # "a €"
    ```
    .
    """

    if c < 0b1000_0000:  # 1 byte ASCII char
        return String(String._buffer_type(c, 0))

    var char_opt = Codepoint.from_u32(c)
    if not char_opt:
        # TODO: Raise ValueError instead.
        return abort[String](
            String("chr(", c, ") is not a valid Unicode codepoint")
        )

    # SAFETY: We just checked that `char` is present.
    var char = char_opt.unsafe_value()

    return String(char)


# ===----------------------------------------------------------------------=== #
# ascii
# ===----------------------------------------------------------------------=== #


fn _chr_ascii(c: UInt8) -> String:
    """Returns a string based on the given ASCII code point.

    Args:
        c: An integer that represents a code point.

    Returns:
        A string containing a single character based on the given code point.
    """
    return String(String._buffer_type(c, 0))


fn _repr_ascii(c: UInt8) -> String:
    """Returns a printable representation of the given ASCII code point.

    Args:
        c: An integer that represents a code point.

    Returns:
        A string containing a representation of the given code point.
    """
    alias ord_tab = ord("\t")
    alias ord_new_line = ord("\n")
    alias ord_carriage_return = ord("\r")
    alias ord_back_slash = ord("\\")

    if c == ord_back_slash:
        return r"\\"
    elif Codepoint(c).is_ascii_printable():
        return _chr_ascii(c)
    elif c == ord_tab:
        return r"\t"
    elif c == ord_new_line:
        return r"\n"
    elif c == ord_carriage_return:
        return r"\r"
    else:
        var uc = c.cast[DType.uint8]()
        if uc < 16:
            return hex(uc, prefix=r"\x0")
        else:
            return hex(uc, prefix=r"\x")


@always_inline
fn ascii(value: StringSlice) -> String:
    """Get the ASCII representation of the object.

    Args:
        value: The object to get the ASCII representation of.

    Returns:
        A string containing the ASCII representation of the object.
    """
    alias ord_squote = ord("'")
    var result = String()
    var use_dquote = False

    for idx in range(len(value._slice)):
        var char = value._slice[idx]
        result += _repr_ascii(char)
        use_dquote = use_dquote or (char == ord_squote)

    if use_dquote:
        return '"' + result + '"'
    else:
        return "'" + result + "'"


# ===----------------------------------------------------------------------=== #
# strtol
# ===----------------------------------------------------------------------=== #


fn atol(str_slice: StringSlice, base: Int = 10) raises -> Int:
    """Parses and returns the given string as an integer in the given base.

    If base is set to 0, the string is parsed as an Integer literal, with the
    following considerations:
    - '0b' or '0B' prefix indicates binary (base 2)
    - '0o' or '0O' prefix indicates octal (base 8)
    - '0x' or '0X' prefix indicates hexadecimal (base 16)
    - Without a prefix, it's treated as decimal (base 10)

    Args:
        str_slice: A string to be parsed as an integer in the given base.
        base: Base used for conversion, value must be between 2 and 36, or 0.

    Returns:
        An integer value that represents the string.

    Raises:
        If the given string cannot be parsed as an integer value or if an
        incorrect base is provided.

    Examples:
        >>> atol("32")
        32
        >>> atol("FF", 16)
        255
        >>> atol("0xFF", 0)
        255
        >>> atol("0b1010", 0)
        10

    Notes:
        This follows [Python's integer literals](
        https://docs.python.org/3/reference/lexical_analysis.html#integers).
    """

    if (base != 0) and (base < 2 or base > 36):
        raise Error("Base must be >= 2 and <= 36, or 0.")
    if not str_slice:
        raise Error(_str_to_base_error(base, str_slice))

    var real_base: Int
    var ord_num_max: Int

    var ord_letter_max = (-1, -1)
    var result = 0
    var is_negative: Bool = False
    var has_prefix: Bool = False
    var start: Int = 0
    var str_len = str_slice.byte_length()

    start, is_negative = _trim_and_handle_sign(str_slice, str_len)

    alias ord_0 = ord("0")
    alias ord_letter_min = (ord("a"), ord("A"))
    alias ord_underscore = ord("_")

    if base == 0:
        var real_base_new_start = _identify_base(str_slice, start)
        real_base = real_base_new_start[0]
        start = real_base_new_start[1]
        has_prefix = real_base != 10
        if real_base == -1:
            raise Error(_str_to_base_error(base, str_slice))
    else:
        start, has_prefix = _handle_base_prefix(start, str_slice, str_len, base)
        real_base = base

    if real_base <= 10:
        ord_num_max = ord(String(real_base - 1))
    else:
        ord_num_max = ord("9")
        ord_letter_max = (
            ord("a") + (real_base - 11),
            ord("A") + (real_base - 11),
        )

    var buff = str_slice.unsafe_ptr()
    var found_valid_chars_after_start = False
    var has_space_after_number = False

    # Prefixed integer literals with real_base 2, 8, 16 may begin with leading
    # underscores under the conditions they have a prefix
    var was_last_digit_underscore = not (real_base in (2, 8, 16) and has_prefix)
    for pos in range(start, str_len):
        var ord_current = Int(buff[pos])
        if ord_current == ord_underscore:
            if was_last_digit_underscore:
                raise Error(_str_to_base_error(base, str_slice))
            else:
                was_last_digit_underscore = True
                continue
        else:
            was_last_digit_underscore = False
        if ord_0 <= ord_current <= ord_num_max:
            result += ord_current - ord_0
            found_valid_chars_after_start = True
        elif ord_letter_min[0] <= ord_current <= ord_letter_max[0]:
            result += ord_current - ord_letter_min[0] + 10
            found_valid_chars_after_start = True
        elif ord_letter_min[1] <= ord_current <= ord_letter_max[1]:
            result += ord_current - ord_letter_min[1] + 10
            found_valid_chars_after_start = True
        elif Codepoint(UInt8(ord_current)).is_posix_space():
            has_space_after_number = True
            start = pos + 1
            break
        else:
            raise Error(_str_to_base_error(base, str_slice))
        if pos + 1 < str_len and not Codepoint(buff[pos + 1]).is_posix_space():
            var nextresult = result * real_base
            if nextresult < result:
                raise Error(
                    _str_to_base_error(base, str_slice)
                    + " String expresses an integer too large to store in Int."
                )
            result = nextresult

    if was_last_digit_underscore or (not found_valid_chars_after_start):
        raise Error(_str_to_base_error(base, str_slice))

    if has_space_after_number:
        for pos in range(start, str_len):
            if not Codepoint(buff[pos]).is_posix_space():
                raise Error(_str_to_base_error(base, str_slice))
    if is_negative:
        result = -result
    return result


@always_inline
fn _trim_and_handle_sign(str_slice: StringSlice, str_len: Int) -> (Int, Bool):
    """Trims leading whitespace, handles the sign of the number in the string.

    Args:
        str_slice: A StringSlice containing the number to parse.
        str_len: The length of the string.

    Returns:
        A tuple containing:
        - The starting index of the number after whitespace and sign.
        - A boolean indicating whether the number is negative.
    """
    var buff = str_slice.unsafe_ptr()
    var start: Int = 0
    while start < str_len and Codepoint(buff[start]).is_posix_space():
        start += 1
    var p: Bool = buff[start] == ord("+")
    var n: Bool = buff[start] == ord("-")
    return start + (Int(p) or Int(n)), n


@always_inline
fn _handle_base_prefix(
    pos: Int, str_slice: StringSlice, str_len: Int, base: Int
) -> (Int, Bool):
    """Adjusts the starting position if a valid base prefix is present.

    Handles "0b"/"0B" for base 2, "0o"/"0O" for base 8, and "0x"/"0X" for base
    16. Only adjusts if the base matches the prefix.

    Args:
        pos: Current position in the string.
        str_slice: The input StringSlice.
        str_len: Length of the input string.
        base: The specified base.

    Returns:
        A tuple containing:
            - Updated position after the prefix, if applicable.
            - A boolean indicating if the prefix was valid for the given base.
    """
    var start = pos
    var buff = str_slice.unsafe_ptr()
    if start + 1 < str_len:
        var prefix_char = chr(Int(buff[start + 1]))
        if buff[start] == ord("0") and (
            (base == 2 and (prefix_char == "b" or prefix_char == "B"))
            or (base == 8 and (prefix_char == "o" or prefix_char == "O"))
            or (base == 16 and (prefix_char == "x" or prefix_char == "X"))
        ):
            start += 2
    return start, start != pos


fn _str_to_base_error(base: Int, str_slice: StringSlice) -> String:
    return String(
        "String is not convertible to integer with base ",
        base,
        ": '",
        str_slice,
        "'",
    )


fn _identify_base(str_slice: StringSlice, start: Int) -> Tuple[Int, Int]:
    var length = str_slice.byte_length()
    # just 1 digit, assume base 10
    if start == (length - 1):
        return 10, start
    if str_slice[start] == "0":
        var second_digit = str_slice[start + 1]
        if second_digit == "b" or second_digit == "B":
            return 2, start + 2
        if second_digit == "o" or second_digit == "O":
            return 8, start + 2
        if second_digit == "x" or second_digit == "X":
            return 16, start + 2
        # checking for special case of all "0", "_" are also allowed
        var was_last_character_underscore = False
        for i in range(start + 1, length):
            if str_slice[i] == "_":
                if was_last_character_underscore:
                    return -1, -1
                else:
                    was_last_character_underscore = True
                    continue
            else:
                was_last_character_underscore = False
            if str_slice[i] != "0":
                return -1, -1
    elif ord("1") <= ord(str_slice[start]) <= ord("9"):
        return 10, start
    else:
        return -1, -1

    return 10, start


fn _atof_error(str_ref: StringSlice) -> Error:
    return Error("String is not convertible to float: '", str_ref, "'")


fn atof(str_slice: StringSlice) raises -> Float64:
    """Parses the given string as a floating point and returns that value.

    For example, `atof("2.25")` returns `2.25`.

    Raises:
        If the given string cannot be parsed as an floating point value, for
        example in `atof("hi")`.

    Args:
        str_slice: A string to be parsed as a floating point.

    Returns:
        An floating point value that represents the string, or otherwise raises.
    """

    if not str_slice:
        raise _atof_error(str_slice)

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
    var str_slice_strip = str_slice.strip()
    var str_len = len(str_slice_strip)
    var buff = str_slice_strip.unsafe_ptr()

    # check sign, inf, nan
    if buff[start] == ord_plus:
        start += 1
    elif buff[start] == ord_minus:
        start += 1
        sign = -1
    if (str_len - start) >= 3:
        if StringSlice[buff.origin](ptr=buff + start, length=3) == "nan":
            return FloatLiteral.nan
        if StringSlice[buff.origin](ptr=buff + start, length=3) == "inf":
            return FloatLiteral.infinity * sign
    # read before dot
    for pos in range(start, str_len):
        if ord_0 <= buff[pos] <= ord_9:
            result = result * 10.0 + Int(buff[pos] - ord_0)
            start += 1
        else:
            break
    # if dot -> read after dot
    if buff[start] == ord_dot:
        start += 1
        for pos in range(start, str_len):
            if ord_0 <= buff[pos] <= ord_9:
                result = result * 10.0 + Int(buff[pos] - ord_0)
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
                shift = shift * 10 + Int(buff[pos] - ord_0)
            else:
                break
            start += 1
        exponent += sign * shift
        if not has_number:
            raise _atof_error(str_slice)
    # check for f/F at the end
    if buff[start] == ord_f or buff[start] == ord_F:
        start += 1
    # check if string got fully parsed
    if start != str_len:
        raise _atof_error(str_slice)
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
    alias ASCII_LOWERCASE = "abcdefghijklmnopqrstuvwxyz"
    alias ASCII_UPPERCASE = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    alias ASCII_LETTERS = Self.ASCII_LOWERCASE + Self.ASCII_UPPERCASE
    alias DIGITS = "0123456789"
    alias HEX_DIGITS = Self.DIGITS + "abcdef" + "ABCDEF"
    alias OCT_DIGITS = "01234567"
    alias PUNCTUATION = """!"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"""
    alias PRINTABLE = Self.DIGITS + Self.ASCII_LETTERS + Self.PUNCTUATION + " \t\n\r\v\f"

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @always_inline
    fn __init__(out self):
        """Construct an uninitialized string."""
        self._buffer = Self._buffer_type()

    @no_inline
    fn __init__[T: Stringable](out self, value: T):
        """Initialize from a type conforming to `Stringable`.

        Parameters:
            T: The type conforming to Stringable.

        Args:
            value: The object to get the string representation of.
        """
        self = value.__str__()

    @no_inline
    fn __init__[T: StringableRaising](out self, value: T) raises:
        """Initialize from a type conforming to `StringableRaising`.

        Parameters:
            T: The type conforming to Stringable.

        Args:
            value: The object to get the string representation of.

        Raises:
            If there is an error when computing the string representation of the type.
        """
        self = value.__str__()

    @no_inline
    fn __init__[
        *Ts: Writable
    ](out self, *args: *Ts, sep: StaticString = "", end: StaticString = ""):
        """
        Construct a string by concatenating a sequence of Writable arguments.

        Args:
            args: A sequence of Writable arguments.
            sep: The separator used between elements.
            end: The String to write after printing the elements.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
                `Writable`.

        Examples:

        Construct a String from several `Writable` arguments:

        ```mojo
        var string = String(1, 2.0, "three", sep=", ")
        print(string) # "1, 2.0, three"
        ```
        .
        """
        self = String()
        write_buffered(self, args, sep=sep, end=end)

    @staticmethod
    @no_inline
    fn __init__[
        *Ts: Writable
    ](
        out self,
        args: VariadicPack[_, Writable, *Ts],
        sep: StaticString = "",
        end: StaticString = "",
    ):
        """
        Construct a string by passing a variadic pack.

        Args:
            args: A VariadicPack of Writable arguments.
            sep: The separator used between elements.
            end: The String to write after printing the elements.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
                `Writable`.

        Examples:

        ```mojo
        fn variadic_pack_to_string[
            *Ts: Writable,
        ](*args: *Ts) -> String:
            return String(args)

        string = variadic_pack_to_string(1, ", ", 2.0, ", ", "three")
        %# from testing import assert_equal
        %# assert_equal(string, "1, 2.0, three")
        ```
        .
        """
        self = String()
        write_buffered(self, args, sep=sep, end=end)

    @no_inline
    fn __init__(out self, value: None):
        """Initialize a `None` type as "None".

        Args:
            value: The object to get the string representation of.
        """
        self = "None"

    @always_inline
    fn __init__(out self, *, capacity: Int):
        """Construct an uninitialized string with the given capacity.

        Args:
            capacity: The capacity of the string.
        """
        self._buffer = Self._buffer_type(capacity=capacity)

    @always_inline
    fn __init__(out self, *, owned buffer: List[Byte, *_]):
        """Construct a string from a buffer of null-terminated bytes, copying
        the allocated data. Use the transfer operator `^` to avoid the copy.

        Args:
            buffer: The null-terminated buffer.

        Examples:

        ```mojo
        %# from testing import assert_equal
        var buf = List[Byte](ord('h'), ord('i'), 0)
        var hi = String(buffer=buf^)
        assert_equal(hi, "hi")
        ```
        .
        """
        debug_assert(
            len(buffer) > 0 and buffer[-1] == 0,
            "expected last element of String buffer to be null terminator",
        )
        self._buffer = rebind[Self._buffer_type](buffer)

    fn copy(self) -> Self:
        """Explicitly copy the provided value.

        Returns:
            A copy of the value.
        """
        return self  # Just use the implicit copyinit.

    @always_inline
    @implicit
    fn __init__(out self, literal: StringLiteral):
        """Constructs a String value given a constant string.

        Args:
            literal: The input constant string.
        """
        self = literal.__str__()

    @always_inline
    fn __init__(out self, *, ptr: UnsafePointer[Byte], length: UInt):
        """Creates a string from the buffer. Note that the string now owns
        the buffer.

        The buffer must be terminated with a null byte.

        Args:
            ptr: The pointer to the buffer.
            length: The length of the buffer, including the null terminator.
        """
        # we don't know the capacity of ptr, but we'll assume it's the same or
        # larger than len
        self = Self(Self._buffer_type(ptr=ptr, length=length, capacity=length))

    # ===------------------------------------------------------------------=== #
    # Factory dunders
    # ===------------------------------------------------------------------=== #

    fn write_bytes(mut self, bytes: Span[Byte, _]):
        """Write a byte span to this String.

        Args:
            bytes: The byte span to write to this String. Must NOT be
                null terminated.
        """
        self._iadd(bytes)

    fn write[*Ts: Writable](mut self, *args: *Ts):
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
        """Construct a string by concatenating a sequence of Writable arguments.

        Args:
            args: A sequence of Writable arguments.
            sep: The separator used between elements.
            end: The String to write after printing the elements.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
                `Writable`.

        Returns:
            A string formed by formatting the argument sequence.

        This is used only when reusing the `write_to` method for
        `__str__` in order to avoid an endless loop recalling
        the constructor:

        ```mojo
        fn write_to[W: Writer](self, mut writer: W):
            writer.write_bytes(self.as_bytes())

        fn __str__(self) -> String:
            return String.write(self)
        ```

        Otherwise you can use the `String` constructor directly without calling
        the `String.write` static method:

        ```mojo
        var msg = String("my message", 42, 42.2, True)
        ```
        .
        """
        var string = String()
        write_buffered(string, args, sep=sep, end=end)
        return string^

    @staticmethod
    @always_inline
    fn _from_bytes(owned buff: UnsafePointer[UInt8]) -> String:
        """Construct a string from a sequence of bytes.

        This does no validation that the given bytes are valid in any specific
        String encoding.

        Args:
            buff: The buffer. This should have an existing terminator.
        """

        return String(
            ptr=buff,
            length=len(StringSlice[buff.origin](unsafe_from_utf8_ptr=buff)) + 1,
        )

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

        return String(buffer=buff^)

    # ===------------------------------------------------------------------=== #
    # Operator dunders
    # ===------------------------------------------------------------------=== #

    fn __getitem__[I: Indexer](self, idx: I) -> String:
        """Gets the character at the specified position.

        Parameters:
            I: A type that can be used as an index.

        Args:
            idx: The index value.

        Returns:
            A new string containing the character at the specified position.
        """
        # TODO(#933): implement this for unicode when we support llvm intrinsic evaluation at compile time
        var normalized_idx = normalize_index["String"](idx, len(self))
        return String(buffer=Self._buffer_type(self._buffer[normalized_idx], 0))

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
            return String(
                StringSlice[__origin_of(self._buffer)](
                    ptr=self._buffer.data + start, length=len(r)
                )
            )

        var buffer = Self._buffer_type(capacity=len(r) + 1)
        var ptr = self.unsafe_ptr()
        for i in r:
            buffer.append(ptr[i])
        buffer.append(0)
        return String(buffer=buffer^)

    @always_inline
    fn __eq__(self, other: String) -> Bool:
        """Compares two Strings if they have the same values.

        Args:
            other: The rhs of the operation.

        Returns:
            True if the Strings are equal and False otherwise.
        """
        if not self and not other:
            return True
        if len(self) != len(other):
            return False
        # same pointer and length, so equal
        if self.unsafe_ptr() == other.unsafe_ptr():
            return True
        for i in range(len(self)):
            if self.unsafe_ptr()[i] != other.unsafe_ptr()[i]:
                return False
        return True

    @always_inline
    fn __ne__(self, other: String) -> Bool:
        """Compares two Strings if they do not have the same values.

        Args:
            other: The rhs of the operation.

        Returns:
            True if the Strings are not equal and False otherwise.
        """
        return not (self == other)

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
    fn _add(lhs: Span[Byte], rhs: Span[Byte]) -> String:
        var lhs_len = len(lhs)
        var rhs_len = len(rhs)
        alias S = StringSlice[ImmutableAnyOrigin]
        if lhs_len == 0:
            return String(S(ptr=rhs.unsafe_ptr(), length=rhs_len))
        elif rhs_len == 0:
            return String(S(ptr=lhs.unsafe_ptr(), length=lhs_len))
        var buffer = Self._buffer_type(capacity=lhs_len + rhs_len + 1)
        buffer.extend(lhs)
        buffer.extend(rhs)
        buffer.append(0)
        return String(buffer=buffer^)

    @always_inline
    fn __add__(self, other: StringSlice) -> String:
        """Creates a string by appending a string slice at the end.

        Args:
            other: The string slice to append.

        Returns:
            The new constructed string.
        """
        return Self._add(self.as_bytes(), other.as_bytes())

    @always_inline
    fn __radd__(self, other: StringSlice) -> String:
        """Creates a string by prepending another string slice to the start.

        Args:
            other: The string to prepend.

        Returns:
            The new constructed string.
        """
        return Self._add(other.as_bytes(), self.as_bytes())

    fn _iadd(mut self, other: Span[Byte]):
        var o_len = len(other)
        if o_len == 0:
            return
        self._buffer.reserve(self.byte_length() + o_len + 1)
        if len(self._buffer) > 0:
            _ = self._buffer.pop()
        self._buffer.extend(other)
        self._buffer.append(0)

    @always_inline
    fn __iadd__(mut self, other: StringSlice):
        """Appends another string slice to this string.

        Args:
            other: The string to append.
        """
        self._iadd(other.as_bytes())

    @deprecated("Use `str.codepoints()` or `str.codepoint_slices()` instead.")
    fn __iter__(self) -> CodepointSliceIter[__origin_of(self)]:
        """Iterate over the string, returning immutable references.

        Returns:
            An iterator of references to the string elements.
        """
        return self.codepoint_slices()

    fn __reversed__(self) -> CodepointSliceIter[__origin_of(self), False]:
        """Iterate backwards over the string, returning immutable references.

        Returns:
            A reversed iterator of references to the string elements.
        """
        return CodepointSliceIter[__origin_of(self), forward=False](self)

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

    @always_inline
    fn __len__(self) -> Int:
        """Get the string length of in bytes.

        This function returns the number of bytes in the underlying UTF-8
        representation of the string.

        To get the number of Unicode codepoints in a string, use
        `len(str.codepoints())`.

        Returns:
            The string length in bytes.

        # Examples

        Query the length of a string, in bytes and Unicode codepoints:

        ```mojo
        from testing import assert_equal

        var s = String("ನಮಸ್ಕಾರ")

        assert_equal(len(s), 21)
        assert_equal(len(s.codepoints()), 7)
        ```

        Strings containing only ASCII characters have the same byte and
        Unicode codepoint length:

        ```mojo
        from testing import assert_equal

        var s = String("abc")

        assert_equal(len(s), 3)
        assert_equal(len(s.codepoints()), 3)
        ```
        .
        """
        return self.byte_length()

    @always_inline
    fn __str__(self) -> String:
        """Gets the string itself.

        This method ensures that you can pass a `String` to a method that
        takes a `Stringable` value.

        Returns:
            The string itself.
        """
        return self

    fn __repr__(self) -> String:
        """Return a Mojo-compatible representation of the `String` instance.

        Returns:
            A new representation of the string.
        """
        return repr(StringSlice(self))

    fn __fspath__(self) -> String:
        """Return the file system path representation (just the string itself).

        Returns:
          The file system path representation as a string.
        """
        return self

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    fn write_to[W: Writer](self, mut writer: W):
        """
        Formats this string to the provided Writer.

        Parameters:
            W: A type conforming to the Writable trait.

        Args:
            writer: The object to write to.
        """

        writer.write_bytes(self.as_bytes())

    fn join[*Ts: Writable](self, *elems: *Ts) -> String:
        """Joins string elements using the current string as a delimiter.

        Parameters:
            Ts: The types of the elements.

        Args:
            elems: The input values.

        Returns:
            The joined string.
        """
        var sep = StaticString(ptr=self.unsafe_ptr(), length=len(self))
        return String(elems, sep=sep)

    fn join[
        T: WritableCollectionElement, //, buffer_size: Int = 4096
    ](self, elems: List[T, *_]) -> String:
        """Joins string elements using the current string as a delimiter.
        Defaults to writing to the stack if total bytes of `elems` is less than
        `buffer_size`, otherwise will allocate once to the heap and write
        directly into that. The `buffer_size` defaults to 4096 bytes to match
        the default page size on arm64 and x86-64, but you can increase this if
        you're joining a very large `List` of elements to write into the stack
        instead of the heap.

        Parameters:
            T: The types of the elements.
            buffer_size: The max size of the stack buffer.

        Args:
            elems: The input values.

        Returns:
            The joined string.
        """
        var sep = StaticString(ptr=self.unsafe_ptr(), length=len(self))
        var total_bytes = _TotalWritableBytes(elems, sep=sep)

        # Use heap if over the stack buffer size
        if total_bytes.size + 1 > buffer_size:
            var buffer = _WriteBufferHeap(total_bytes.size + 1)
            buffer.write_list(elems, sep=sep)
            buffer.data[total_bytes.size] = 0
            return String(ptr=buffer.data, length=total_bytes.size + 1)
        # Use stack otherwise
        else:
            var string = String()
            write_buffered[buffer_size](string, elems, sep=sep)
            return string

    @always_inline
    fn codepoints(self) -> CodepointsIter[__origin_of(self)]:
        """Returns an iterator over the `Codepoint`s encoded in this string slice.

        Returns:
            An iterator type that returns successive `Codepoint` values stored in
            this string slice.

        # Examples

        Print the characters in a string:

        ```mojo
        from testing import assert_equal

        var s = String("abc")
        var iter = s.codepoints()
        assert_equal(iter.__next__(), Codepoint.ord("a"))
        assert_equal(iter.__next__(), Codepoint.ord("b"))
        assert_equal(iter.__next__(), Codepoint.ord("c"))
        assert_equal(iter.__has_next__(), False)
        ```

        `codepoints()` iterates over Unicode codepoints, and supports multibyte
        codepoints:

        ```mojo
        from testing import assert_equal

        # A visual character composed of a combining sequence of 2 codepoints.
        var s = String("á")
        assert_equal(s.byte_length(), 3)

        var iter = s.codepoints()
        assert_equal(iter.__next__(), Codepoint.ord("a"))
         # U+0301 Combining Acute Accent
        assert_equal(iter.__next__().to_u32(), 0x0301)
        assert_equal(iter.__has_next__(), False)
        ```
        .
        """
        return self.as_string_slice().codepoints()

    fn codepoint_slices(self) -> CodepointSliceIter[__origin_of(self)]:
        """Returns an iterator over single-character slices of this string.

        Each returned slice points to a single Unicode codepoint encoded in the
        underlying UTF-8 representation of this string.

        Returns:
            An iterator of references to the string elements.

        # Examples

        Iterate over the character slices in a string:

        ```mojo
        from testing import assert_equal, assert_true

        var s = String("abc")
        var iter = s.codepoint_slices()
        assert_true(iter.__next__() == "a")
        assert_true(iter.__next__() == "b")
        assert_true(iter.__next__() == "c")
        assert_equal(iter.__has_next__(), False)
        ```
        .
        """
        return self.as_string_slice().codepoint_slices()

    fn unsafe_ptr(
        ref self,
    ) -> UnsafePointer[
        Byte,
        mut = Origin(__origin_of(self)).is_mutable,
        origin = __origin_of(self),
    ]:
        """Retrieves a pointer to the underlying memory.

        Returns:
            The pointer to the underlying memory.
        """
        return self._buffer.unsafe_ptr()

    fn unsafe_cstr_ptr(self) -> UnsafePointer[c_char]:
        """Retrieves a C-string-compatible pointer to the underlying memory.

        The returned pointer is guaranteed to be null, or NUL terminated.

        Returns:
            The pointer to the underlying memory.
        """
        return self.unsafe_ptr().bitcast[c_char]()

    @always_inline
    fn as_bytes(ref self) -> Span[Byte, __origin_of(self)]:
        """Returns a contiguous slice of the bytes owned by this string.

        Returns:
            A contiguous slice pointing to the bytes owned by this string.

        Notes:
            This does not include the trailing null terminator.
        """

        # Does NOT include the NUL terminator.
        return Span[Byte, __origin_of(self)](
            ptr=self._buffer.unsafe_ptr(), length=self.byte_length()
        )

    @always_inline
    fn as_string_slice(ref self) -> StringSlice[__origin_of(self)]:
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
        return length - Int(length > 0)

    fn _steal_ptr(mut self) -> UnsafePointer[UInt8]:
        """Transfer ownership of pointer to the underlying memory.
        The caller is responsible for freeing up the memory.

        Returns:
            The pointer to the underlying memory.
        """
        return self._buffer.steal_data()

    fn count(self, substr: StringSlice) -> Int:
        """Return the number of non-overlapping occurrences of substring
        `substr` in the string.

        If sub is empty, returns the number of empty strings between characters
        which is the length of the string plus one.

        Args:
          substr: The substring to count.

        Returns:
          The number of occurrences of `substr`.
        """
        return self.as_string_slice().count(substr)

    fn __contains__(self, substr: StringSlice) -> Bool:
        """Returns True if the substring is contained within the current string.

        Args:
          substr: The substring to check.

        Returns:
          True if the string contains the substring.
        """
        return substr in self.as_string_slice()

    fn find(self, substr: StringSlice, start: Int = 0) -> Int:
        """Finds the offset of the first occurrence of `substr` starting at
        `start`. If not found, returns -1.

        Args:
          substr: The substring to find.
          start: The offset from which to find.

        Returns:
          The offset of `substr` relative to the beginning of the string.
        """

        return self.as_string_slice().find(substr, start)

    fn rfind(self, substr: StringSlice, start: Int = 0) -> Int:
        """Finds the offset of the last occurrence of `substr` starting at
        `start`. If not found, returns -1.

        Args:
          substr: The substring to find.
          start: The offset from which to find.

        Returns:
          The offset of `substr` relative to the beginning of the string.
        """

        return self.as_string_slice().rfind(substr, start=start)

    fn isspace(self) -> Bool:
        """Determines whether every character in the given String is a
        python whitespace String. This corresponds to Python's
        [universal separators](
            https://docs.python.org/3/library/stdtypes.html#str.splitlines)
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Returns:
            True if the whole String is made up of whitespace characters
                listed above, otherwise False.
        """
        return self.as_string_slice().isspace()

    # TODO(MSTDL-590): String.split() should return `StringSlice`s.
    fn split(self, sep: StringSlice, maxsplit: Int = -1) raises -> List[String]:
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
        return self.as_string_slice().split[sep.mut, sep.origin](
            sep, maxsplit=maxsplit
        )

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
            "hello \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e\\x85\\u2028\\u2029world"
        ).split()  # ["hello", "world"]
        ```
        .
        """

        # TODO(MSTDL-590): Avoid the need to loop to convert `StringSlice` to
        #   `String` by making `String.split()` return `StringSlice`s.
        var str_slices = self.as_string_slice()._split_whitespace(
            maxsplit=maxsplit
        )

        var output = List[String](capacity=len(str_slices))

        for str_slice in str_slices:
            output.append(String(str_slice[]))

        return output^

    fn splitlines(self, keepends: Bool = False) -> List[String]:
        """Split the string at line boundaries. This corresponds to Python's
        [universal newlines:](
            https://docs.python.org/3/library/stdtypes.html#str.splitlines)
        `"\\r\\n"` and `"\\t\\n\\v\\f\\r\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Args:
            keepends: If True, line breaks are kept in the resulting strings.

        Returns:
            A List of Strings containing the input split by line boundaries.
        """
        return _to_string_list(self.as_string_slice().splitlines(keepends))

    fn replace(self, old: StringSlice, new: StringSlice) -> String:
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
            var curr_offset = Int(self_ptr) - Int(self_start)

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

    fn strip(self, chars: StringSlice) -> StringSlice[__origin_of(self)]:
        """Return a copy of the string with leading and trailing characters
        removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no leading or trailing characters.
        """

        return self.lstrip(chars).rstrip(chars)

    fn strip(self) -> StringSlice[__origin_of(self)]:
        """Return a copy of the string with leading and trailing whitespaces
        removed. This only takes ASCII whitespace into account:
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

        Returns:
            A copy of the string with no leading or trailing whitespaces.
        """
        return self.lstrip().rstrip()

    fn rstrip(self, chars: StringSlice) -> StringSlice[__origin_of(self)]:
        """Return a copy of the string with trailing characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no trailing characters.
        """

        return self.as_string_slice().rstrip(chars)

    fn rstrip(self) -> StringSlice[__origin_of(self)]:
        """Return a copy of the string with trailing whitespaces removed. This
        only takes ASCII whitespace into account:
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

        Returns:
            A copy of the string with no trailing whitespaces.
        """
        return self.as_string_slice().rstrip()

    fn lstrip(self, chars: StringSlice) -> StringSlice[__origin_of(self)]:
        """Return a copy of the string with leading characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no leading characters.
        """

        return self.as_string_slice().lstrip(chars)

    fn lstrip(self) -> StringSlice[__origin_of(self)]:
        """Return a copy of the string with leading whitespaces removed. This
        only takes ASCII whitespace into account:
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

        Returns:
            A copy of the string with no leading whitespaces.
        """
        return self.as_string_slice().lstrip()

    fn __hash__(self) -> UInt:
        """Hash the underlying buffer using builtin hash.

        Returns:
            A 64-bit hash value. This value is _not_ suitable for cryptographic
            uses. Its intended usage is for data structures. See the `hash`
            builtin documentation for more details.
        """
        return hash(self.as_string_slice())

    fn __hash__[H: _Hasher](self, mut hasher: H):
        """Updates hasher with the underlying bytes.

        Parameters:
            H: The hasher type.

        Args:
            hasher: The hasher instance.
        """
        hasher._update_with_bytes(self.unsafe_ptr(), self.byte_length())

    fn _interleave(self, val: StringSlice) -> String:
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
        """Returns a copy of the string with all cased characters
        converted to lowercase.

        Returns:
            A new string where cased letters have been converted to lowercase.
        """

        return self.as_string_slice().lower()

    fn upper(self) -> String:
        """Returns a copy of the string with all cased characters
        converted to uppercase.

        Returns:
            A new string where cased letters have been converted to uppercase.
        """

        return self.as_string_slice().upper()

    fn startswith(
        self, prefix: StringSlice, start: Int = 0, end: Int = -1
    ) -> Bool:
        """Checks if the string starts with the specified prefix between start
        and end positions. Returns True if found and False otherwise.

        Args:
            prefix: The prefix to check.
            start: The start offset from which to check.
            end: The end offset from which to check.

        Returns:
            True if the `self[start:end]` is prefixed by the input prefix.
        """
        return self.as_string_slice().startswith(prefix, start, end)

    fn endswith(
        self, suffix: StringSlice, start: Int = 0, end: Int = -1
    ) -> Bool:
        """Checks if the string end with the specified suffix between start
        and end positions. Returns True if found and False otherwise.

        Args:
            suffix: The suffix to check.
            start: The start offset from which to check.
            end: The end offset from which to check.

        Returns:
            True if the `self[start:end]` is suffixed by the input suffix.
        """
        return self.as_string_slice().endswith(suffix, start, end)

    fn removeprefix(self, prefix: StringSlice, /) -> String:
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

    fn removesuffix(self, suffix: StringSlice, /) -> String:
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
        return self.as_string_slice() * n

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
        return self.as_string_slice().is_ascii_digit()

    fn isupper(self) -> Bool:
        """Returns True if all cased characters in the string are uppercase and
        there is at least one cased character.

        Returns:
            True if all cased characters in the string are uppercase and there
            is at least one cased character, False otherwise.
        """
        return self.as_string_slice().isupper()

    fn islower(self) -> Bool:
        """Returns True if all cased characters in the string are lowercase and
        there is at least one cased character.

        Returns:
            True if all cased characters in the string are lowercase and there
            is at least one cased character, False otherwise.
        """
        return self.as_string_slice().islower()

    fn isprintable(self) -> Bool:
        """Returns True if all characters in the string are ASCII printable.

        Note that this currently only works with ASCII strings.

        Returns:
            True if all characters are printable else False.
        """
        return self.as_string_slice().is_ascii_printable()

    fn rjust(self, width: Int, fillchar: StringLiteral = " ") -> String:
        """Returns the string right justified in a string of specified width.

        Args:
            width: The width of the field containing the string.
            fillchar: Specifies the padding character.

        Returns:
            Returns right justified string, or self if width is not bigger than self length.
        """
        return self.as_string_slice().rjust(width, fillchar)

    fn ljust(self, width: Int, fillchar: StringLiteral = " ") -> String:
        """Returns the string left justified in a string of specified width.

        Args:
            width: The width of the field containing the string.
            fillchar: Specifies the padding character.

        Returns:
            Returns left justified string, or self if width is not bigger than self length.
        """
        return self.as_string_slice().ljust(width, fillchar)

    fn center(self, width: Int, fillchar: StringLiteral = " ") -> String:
        """Returns the string center justified in a string of specified width.

        Args:
            width: The width of the field containing the string.
            fillchar: Specifies the padding character.

        Returns:
            Returns center justified string, or self if width is not bigger than self length.
        """
        return self.as_string_slice().center(width, fillchar)

    fn reserve(mut self, new_capacity: Int):
        """Reserves the requested capacity.

        Args:
            new_capacity: The new capacity.

        Notes:
            If the current capacity is greater or equal, this is a no-op.
            Otherwise, the storage is reallocated and the data is moved.
        """
        self._buffer.reserve(new_capacity)


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
    var log2 = Int(
        (bitwidthof[DType.uint32]() - 1) ^ count_leading_zeros(n | 1)
    )
    return (n0 + lookup_table[Int(log2)]) >> 32


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
            return sign + _calc_initial_buffer_size_int32(Int(n)) + 1
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
