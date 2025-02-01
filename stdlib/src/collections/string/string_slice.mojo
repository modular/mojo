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
"""Implements the StringSlice type.

You can import these APIs from the `collections.string.string_slice` module.

Examples:

```mojo
from collections.string import StringSlice
```
"""

from bit import count_leading_zeros
from collections import List, Optional
from collections.string.format import _CurlyEntryFormattable, _FormatCurlyEntry
from collections.string._utf8_validation import _is_valid_utf8
from memory import UnsafePointer, memcmp, memcpy, Span
from memory.memory import _memcmp_impl_unconstrained
from sys import bitwidthof, simdwidthof
from sys.intrinsics import unlikely, likely
from sys.ffi import c_char
from utils.stringref import StringRef, _memmem
from hashlib._hasher import _HashableWithHasher, _Hasher
from os import PathLike

alias StaticString = StringSlice[StaticConstantOrigin]
"""An immutable static string slice."""


fn _count_utf8_continuation_bytes(str_slice: StringSlice) -> Int:
    alias sizes = (256, 128, 64, 32, 16, 8)
    var ptr = str_slice.unsafe_ptr()
    var num_bytes = str_slice.byte_length()
    var amnt: Int = 0
    var processed = 0

    @parameter
    for i in range(len(sizes)):
        alias s = sizes[i]

        @parameter
        if simdwidthof[DType.uint8]() >= s:
            var rest = num_bytes - processed
            for _ in range(rest // s):
                var vec = (ptr + processed).load[width=s]()
                var comp = (vec & 0b1100_0000) == 0b1000_0000
                amnt += Int(comp.cast[DType.uint8]().reduce_add())
                processed += s

    for i in range(num_bytes - processed):
        amnt += Int((ptr[processed + i] & 0b1100_0000) == 0b1000_0000)

    return amnt


@always_inline
fn _utf8_first_byte_sequence_length(b: Byte) -> Int:
    """Get the length of the sequence starting with given byte. Do note that
    this does not work correctly if given a continuation byte."""

    debug_assert(
        (b & 0b1100_0000) != 0b1000_0000,
        "Function does not work correctly if given a continuation byte.",
    )
    return Int(count_leading_zeros(~b)) + Int(b < 0b1000_0000)


fn _utf8_byte_type(b: SIMD[DType.uint8, _], /) -> __type_of(b):
    """UTF-8 byte type.

    Returns:
        The byte type.

    Notes:

        - 0 -> ASCII byte.
        - 1 -> continuation byte.
        - 2 -> start of 2 byte long sequence.
        - 3 -> start of 3 byte long sequence.
        - 4 -> start of 4 byte long sequence.
    """
    return count_leading_zeros(~(b & UInt8(0b1111_0000)))


@always_inline
fn _memrchr[
    type: DType
](
    source: UnsafePointer[Scalar[type]], char: Scalar[type], len: Int
) -> UnsafePointer[Scalar[type]]:
    if not len:
        return UnsafePointer[Scalar[type]]()
    for i in reversed(range(len)):
        if source[i] == char:
            return source + i
    return UnsafePointer[Scalar[type]]()


@always_inline
fn _memrmem[
    type: DType
](
    haystack: UnsafePointer[Scalar[type]],
    haystack_len: Int,
    needle: UnsafePointer[Scalar[type]],
    needle_len: Int,
) -> UnsafePointer[Scalar[type]]:
    if not needle_len:
        return haystack
    if needle_len > haystack_len:
        return UnsafePointer[Scalar[type]]()
    if needle_len == 1:
        return _memrchr[type](haystack, needle[0], haystack_len)
    for i in reversed(range(haystack_len - needle_len + 1)):
        if haystack[i] != needle[0]:
            continue
        if memcmp(haystack + i + 1, needle + 1, needle_len - 1) == 0:
            return haystack + i
    return UnsafePointer[Scalar[type]]()


@value
struct _StringSliceIter[
    mut: Bool, //,
    origin: Origin[mut],
    forward: Bool = True,
]:
    """Iterator for `StringSlice` over unicode characters.

    Parameters:
        mut: Whether the slice is mutable.
        origin: The origin of the underlying string data.
        forward: The iteration direction. `False` is backwards.
    """

    var index: Int
    var ptr: UnsafePointer[Byte]
    var length: Int

    fn __init__(out self, *, ptr: UnsafePointer[Byte], length: UInt):
        self.index = 0 if forward else length
        self.ptr = ptr
        self.length = length

    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self) -> StringSlice[origin]:
        @parameter
        if forward:
            byte_len = _utf8_first_byte_sequence_length(self.ptr[self.index])
            i = self.index
            self.index += byte_len
            return StringSlice[origin](ptr=self.ptr + i, length=byte_len)
        else:
            byte_len = 1
            while _utf8_byte_type(self.ptr[self.index - byte_len]) == 1:
                byte_len += 1
            self.index -= byte_len
            return StringSlice[origin](
                ptr=self.ptr + self.index, length=byte_len
            )

    @always_inline
    fn __has_next__(self) -> Bool:
        @parameter
        if forward:
            return self.index < self.length
        else:
            return self.index > 0

    fn __len__(self) -> Int:
        @parameter
        if forward:
            var remaining = self.length - self.index
            var span = Span[Byte, ImmutableAnyOrigin](
                ptr=self.ptr + self.index, length=remaining
            )
            return StringSlice(unsafe_from_utf8=span).char_length()
        else:
            var span = Span[Byte, ImmutableAnyOrigin](
                ptr=self.ptr, length=self.index
            )
            return StringSlice(unsafe_from_utf8=span).char_length()


@value
struct CharsIter[mut: Bool, //, origin: Origin[mut]]:
    """Iterator over the `Char`s in a string slice, constructed by
    `StringSlice.chars()`.

    Parameters:
        mut: Mutability of the underlying string data.
        origin: Origin of the underlying string data.
    """

    var _slice: StringSlice[origin]
    """String slice containing the bytes that have not been read yet.

    When this iterator advances, the pointer in `_slice` is advanced by the
    byte length of each read character, and the slice length is decremented by
    the same amount.
    """

    # Note:
    #   Marked private since `StringSlice.chars()` is the intended public way to
    #   construct this type.
    @doc_private
    fn __init__(out self, str_slice: StringSlice[origin]):
        self._slice = str_slice

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    @doc_private
    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self) -> Char:
        """Get the next character in the underlying string slice.

        This returns the next `Char` encoded in the underlying string, and
        advances the iterator state.

        This function will abort if this iterator has been exhausted.

        Returns:
            The next character in the string.
        """

        return self.next().value()

    @always_inline
    fn __has_next__(self) -> Bool:
        """Returns True if there are still elements in this iterator.

        Returns:
            A boolean indicating if there are still elements in this iterator.
        """
        return Bool(self.peek_next())

    @always_inline
    fn __len__(self) -> Int:
        """Returns the remaining length of this iterator in `Char`s.

        The value returned from this method indicates the number of subsequent
        calls to `next()` that will return a value.

        Returns:
            Number of codepoints remaining in this iterator.
        """
        return self._slice.char_length()

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    fn peek_next(self) -> Optional[Char]:
        """Check what the next character in this iterator is, without advancing
        the iterator state.

        Repeated calls to this method will return the same value.

        Returns:
            The next character in the underlying string, or None if the string
            is empty.

        # Examples

        `peek_next()` does not advance the iterator, so repeated calls will
        return the same value:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var input = StringSlice("123")
        var iter = input.chars()

        assert_equal(iter.peek_next().value(), Char.ord("1"))
        assert_equal(iter.peek_next().value(), Char.ord("1"))
        assert_equal(iter.peek_next().value(), Char.ord("1"))

        # A call to `next()` return the same value as `peek_next()` had,
        # but also advance the iterator.
        assert_equal(iter.next().value(), Char.ord("1"))

        # Later `peek_next()` calls will return the _new_ next character:
        assert_equal(iter.peek_next().value(), Char.ord("2"))
        ```
        .
        """
        if len(self._slice) > 0:
            # SAFETY: Will not read out of bounds because `_slice` is guaranteed
            #   to contain valid UTF-8.
            char, _ = Char.unsafe_decode_utf8_char(self._slice.unsafe_ptr())
            return char
        else:
            return None

    fn next(mut self) -> Optional[Char]:
        """Get the next character in the underlying string slice, or None if
        the iterator is empty.

        This returns the next `Char` encoded in the underlying string, and
        advances the iterator state.

        Returns:
            A character if the string is not empty, otherwise None.
        """
        var result: Optional[Char] = self.peek_next()

        if result:
            # SAFETY: We just checked that `result` holds a value
            var char_len = result.unsafe_value().utf8_byte_length()
            # Advance the pointer in _slice.
            self._slice._slice._data += char_len
            # Decrement the byte-length of _slice.
            self._slice._slice._len -= char_len

        return result


@value
@register_passable("trivial")
struct StringSlice[mut: Bool, //, origin: Origin[mut]](
    Stringable,
    Representable,
    Sized,
    Writable,
    CollectionElement,
    CollectionElementNew,
    EqualityComparable,
    Hashable,
    PathLike,
):
    """A non-owning view to encoded string data.

    This type is guaranteed to have the same ABI (size, alignment, and field
    layout) as the `llvm::StringRef` type.

    Parameters:
        mut: Whether the slice is mutable.
        origin: The origin of the underlying string data.

    Notes:
        TODO: The underlying string data is guaranteed to be encoded using
        UTF-8.
    """

    var _slice: Span[Byte, origin]

    # ===------------------------------------------------------------------===#
    # Initializers
    # ===------------------------------------------------------------------===#

    @always_inline
    @implicit
    fn __init__(out self: StaticString, lit: StringLiteral):
        """Construct a new `StringSlice` from a `StringLiteral`.

        Args:
            lit: The literal to construct this `StringSlice` from.
        """
        # Since a StringLiteral has static origin, it will outlive
        # whatever arbitrary `origin` the user has specified they need this
        # slice to live for.
        # SAFETY:
        #   StringLiteral is guaranteed to use UTF-8 encoding.
        # FIXME(MSTDL-160):
        #   Ensure StringLiteral _actually_ always uses UTF-8 encoding.
        self = StaticString(unsafe_from_utf8=lit.as_bytes())

    @always_inline
    fn __init__(out self, *, owned unsafe_from_utf8: Span[Byte, origin]):
        """Construct a new `StringSlice` from a sequence of UTF-8 encoded bytes.

        Args:
            unsafe_from_utf8: A `Span[Byte]` encoded in UTF-8.

        Safety:
            `unsafe_from_utf8` MUST be valid UTF-8 encoded data.
        """
        # FIXME(#3706): can't run at compile time
        # TODO(MOCO-1525):
        #   Support skipping UTF-8 during comptime evaluations, or support
        #   the necessary SIMD intrinsics to allow this to evaluate at compile
        #   time.
        # debug_assert(
        #     _is_valid_utf8(value.as_bytes()), "value is not valid utf8"
        # )
        self._slice = unsafe_from_utf8

    fn __init__(out self, *, unsafe_from_utf8_strref: StringRef):
        """Construct a new StringSlice from a `StringRef` pointing to UTF-8
        encoded bytes.

        Args:
            unsafe_from_utf8_strref: A `StringRef` of bytes encoded in UTF-8.

        Safety:
            - `unsafe_from_utf8_strref` MUST point to data that is valid for
              `origin`.
            - `unsafe_from_utf8_strref` MUST be valid UTF-8 encoded data.
        """

        var strref = unsafe_from_utf8_strref

        var byte_slice = Span[Byte, origin](
            ptr=strref.unsafe_ptr(),
            length=len(strref),
        )

        self = Self(unsafe_from_utf8=byte_slice)

    fn __init__(out self, *, unsafe_from_utf8_ptr: UnsafePointer[Byte]):
        """Construct a new StringSlice from a `UnsafePointer[Byte]` pointing to null-terminated UTF-8
        encoded bytes.

        Args:
            unsafe_from_utf8_ptr: An `UnsafePointer[Byte]` of null-terminated bytes encoded in UTF-8.

        Safety:
            - `unsafe_from_utf8_ptr` MUST point to data that is valid for
                `origin`.
            - `unsafe_from_utf8_ptr` MUST be valid UTF-8 encoded data.
            - `unsafe_from_utf8_ptr` MUST be null terminated.
        """

        var count = _unsafe_strlen(unsafe_from_utf8_ptr)

        var byte_slice = Span[Byte, origin](
            ptr=unsafe_from_utf8_ptr,
            length=count,
        )

        self = Self(unsafe_from_utf8=byte_slice)

    fn __init__(out self, *, unsafe_from_utf8_cstr_ptr: UnsafePointer[c_char]):
        """Construct a new StringSlice from a `UnsafePointer[c_char]` pointing to null-terminated UTF-8
        encoded bytes.

        Args:
            unsafe_from_utf8_cstr_ptr: An `UnsafePointer[c_char]` of null-terminated bytes encoded in UTF-8.

        Safety:
            - `unsafe_from_utf8_ptr` MUST point to data that is valid for
                `origin`.
            - `unsafe_from_utf8_ptr` MUST be valid UTF-8 encoded data.
            - `unsafe_from_utf8_ptr` MUST be null terminated.
        """
        var ptr = unsafe_from_utf8_cstr_ptr.bitcast[Byte]()
        self = Self(unsafe_from_utf8_ptr=ptr)

    @always_inline
    fn __init__(out self, *, ptr: UnsafePointer[Byte], length: UInt):
        """Construct a `StringSlice` from a pointer to a sequence of UTF-8
        encoded bytes and a length.

        Args:
            ptr: A pointer to a sequence of bytes encoded in UTF-8.
            length: The number of bytes of encoded data.

        Safety:
            - `ptr` MUST point to at least `length` bytes of valid UTF-8 encoded
                data.
            - `ptr` must point to data that is live for the duration of
                `origin`.
        """
        self = Self(unsafe_from_utf8=Span[Byte, origin](ptr=ptr, length=length))

    @always_inline
    fn copy(self) -> Self:
        """Explicitly construct a deep copy of the provided `StringSlice`.

        Returns:
            A copy of the value.
        """
        return Self(unsafe_from_utf8=self._slice)

    @implicit
    fn __init__[
        O: ImmutableOrigin, //
    ](mut self: StringSlice[O], ref [O]value: String):
        """Construct an immutable StringSlice.

        Parameters:
            O: The immutable origin.

        Args:
            value: The string value.
        """
        self = StringSlice[O](unsafe_from_utf8=value.as_bytes())

    # ===-------------------------------------------------------------------===#
    # Factory methods
    # ===-------------------------------------------------------------------===#

    # TODO: Change to `__init__(out self, *, from_utf8: Span[..])` once ambiguity
    #   with existing `unsafe_from_utf8` overload is fixed. Would require
    #   signature comparision to take into account required named arguments.
    @staticmethod
    fn from_utf8(from_utf8: Span[Byte, origin]) raises -> StringSlice[origin]:
        """Construct a new `StringSlice` from a buffer containing UTF-8 encoded
        data.

        Args:
            from_utf8: A span of bytes containing UTF-8 encoded data.

        Returns:
            A new validated `StringSlice` pointing to the provided buffer.

        Raises:
            An exception is raised if the provided buffer byte values do not
            form valid UTF-8 encoded codepoints.
        """
        if not _is_valid_utf8(from_utf8):
            raise Error("StringSlice: buffer is not valid UTF-8")

        return StringSlice[origin](unsafe_from_utf8=from_utf8)

    # ===------------------------------------------------------------------===#
    # Trait implementations
    # ===------------------------------------------------------------------===#

    @no_inline
    fn __str__(self) -> String:
        """Convert this StringSlice to a String.

        Returns:
            A new String.

        Notes:
            This will allocate a new string that copies the string contents from
            the provided string slice.
        """
        var length = self.byte_length()
        var ptr = UnsafePointer[Byte].alloc(length + 1)  # null terminator
        memcpy(ptr, self.unsafe_ptr(), length)
        ptr[length] = 0
        return String(ptr=ptr, length=length + 1)

    fn __repr__(self) -> String:
        """Return a Mojo-compatible representation of this string slice.

        Returns:
            Representation of this string slice as a Mojo string literal input
            form syntax.
        """
        var result = String()
        var use_dquote = False
        for s in self.char_slices():
            use_dquote = use_dquote or (s == "'")

            if s == "\\":
                result += r"\\"
            elif s == "\t":
                result += r"\t"
            elif s == "\n":
                result += r"\n"
            elif s == "\r":
                result += r"\r"
            else:
                var codepoint = Char.ord(s)
                if codepoint.is_ascii_printable():
                    result += s
                elif codepoint.to_u32() < 0x10:
                    result += hex(codepoint, prefix=r"\x0")
                elif codepoint.to_u32() < 0x20 or codepoint.to_u32() == 0x7F:
                    result += hex(codepoint, prefix=r"\x")
                else:  # multi-byte character
                    result += s

        if use_dquote:
            return '"' + result + '"'
        else:
            return "'" + result + "'"

    @always_inline
    fn __len__(self) -> Int:
        """Get the string length in bytes.

        This function returns the number of bytes in the underlying UTF-8
        representation of the string.

        To get the number of Unicode codepoints in a string, use
        `len(str.chars())`.

        Returns:
            The string length in bytes.

        # Examples

        Query the length of a string, in bytes and Unicode codepoints:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var s = StringSlice("ನಮಸ್ಕಾರ")

        assert_equal(len(s), 21)
        assert_equal(len(s.chars()), 7)
        ```

        Strings containing only ASCII characters have the same byte and
        Unicode codepoint length:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var s = StringSlice("abc")

        assert_equal(len(s), 3)
        assert_equal(len(s.chars()), 3)
        ```
        .
        """
        return self.byte_length()

    fn write_to[W: Writer](self, mut writer: W):
        """Formats this string slice to the provided `Writer`.

        Parameters:
            W: A type conforming to the `Writable` trait.

        Args:
            writer: The object to write to.
        """
        writer.write_bytes(self.as_bytes())

    fn __bool__(self) -> Bool:
        """Check if a string slice is non-empty.

        Returns:
           True if a string slice is non-empty, False otherwise.
        """
        return len(self._slice) > 0

    fn __hash__(self) -> UInt:
        """Hash the underlying buffer using builtin hash.

        Returns:
            A 64-bit hash value. This value is _not_ suitable for cryptographic
            uses. Its intended usage is for data structures. See the `hash`
            builtin documentation for more details.
        """
        return hash(self._slice._data, self._slice._len)

    fn __hash__[H: _Hasher](self, mut hasher: H):
        """Updates hasher with the underlying bytes.

        Parameters:
            H: The hasher type.

        Args:
            hasher: The hasher instance.
        """
        hasher._update_with_bytes(self.unsafe_ptr(), len(self))

    fn __fspath__(self) -> String:
        """Return the file system path representation of this string.

        Returns:
          The file system path representation as a string.
        """
        return self.__str__()

    @always_inline
    fn __getitem__(self, span: Slice) raises -> Self:
        """Gets the sequence of characters at the specified positions.

        Args:
            span: A slice that specifies positions of the new substring.

        Returns:
            A new StringSlice containing the substring at the specified positions.
        """
        var step: Int
        var start: Int
        var end: Int
        start, end, step = span.indices(len(self))

        if step != 1:
            raise Error("Slice must be within bounds and step must be 1")

        return Self(unsafe_from_utf8=self._slice[span])

    # ===------------------------------------------------------------------===#
    # Operator dunders
    # ===------------------------------------------------------------------===#

    # This decorator informs the compiler that indirect address spaces are not
    # dereferenced by the method.
    # TODO: replace with a safe model that checks the body of the method for
    # accesses to the origin.
    @__unsafe_disable_nested_origin_exclusivity
    fn __eq__(self, rhs_same: Self) -> Bool:
        """Verify if a `StringSlice` is equal to another `StringSlice` with the
        same origin.

        Args:
            rhs_same: The `StringSlice` to compare against.

        Returns:
            If the `StringSlice` is equal to the input in length and contents.
        """
        return Self.__eq__(self, rhs=rhs_same)

    # This decorator informs the compiler that indirect address spaces are not
    # dereferenced by the method.
    # TODO: replace with a safe model that checks the body of the method for
    # accesses to the origin.
    @__unsafe_disable_nested_origin_exclusivity
    fn __eq__(self, rhs: StringSlice) -> Bool:
        """Verify if a `StringSlice` is equal to another `StringSlice`.

        Args:
            rhs: The `StringSlice` to compare against.

        Returns:
            If the `StringSlice` is equal to the input in length and contents.
        """

        var s_len = self.byte_length()
        var s_ptr = self.unsafe_ptr()
        var rhs_ptr = rhs.unsafe_ptr()
        if s_len != rhs.byte_length():
            return False
        # same pointer and length, so equal
        elif s_len == 0 or s_ptr == rhs_ptr:
            return True
        return memcmp(s_ptr, rhs_ptr, s_len) == 0

    fn __ne__(self, rhs_same: Self) -> Bool:
        """Verify if a `StringSlice` is not equal to another `StringSlice` with
        the same origin.

        Args:
            rhs_same: The `StringSlice` to compare against.

        Returns:
            If the `StringSlice` is not equal to the input in length and
            contents.
        """
        return Self.__ne__(self, rhs=rhs_same)

    @__unsafe_disable_nested_origin_exclusivity
    @always_inline
    fn __ne__(self, rhs: StringSlice) -> Bool:
        """Verify if span is not equal to another `StringSlice`.

        Args:
            rhs: The `StringSlice` to compare against.

        Returns:
            If the `StringSlice` is not equal to the input in length and
            contents.
        """
        return not self == rhs

    @always_inline
    fn __lt__(self, rhs: StringSlice) -> Bool:
        """Verify if the `StringSlice` bytes are strictly less than the input in
        overlapping content.

        Args:
            rhs: The other `StringSlice` to compare against.

        Returns:
            If the `StringSlice` bytes are strictly less than the input in
            overlapping content.
        """
        var len1 = len(self)
        var len2 = len(rhs)
        return Int(len1 < len2) > _memcmp_impl_unconstrained(
            self.unsafe_ptr(), rhs.unsafe_ptr(), min(len1, len2)
        )

    fn __iter__(self) -> _StringSliceIter[origin]:
        """Iterate over the string, returning immutable references.

        Returns:
            An iterator of references to the string elements.
        """
        return self.char_slices()

    fn __reversed__(self) -> _StringSliceIter[origin, False]:
        """Iterate backwards over the string, returning immutable references.

        Returns:
            A reversed iterator of references to the string elements.
        """
        return _StringSliceIter[origin, forward=False](
            ptr=self.unsafe_ptr(), length=self.byte_length()
        )

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
        var buf = String._buffer_type(capacity=1)
        buf.append(self._slice[idx])
        buf.append(0)
        return String(buf^)

    fn __contains__(ref self, substr: StringSlice) -> Bool:
        """Returns True if the substring is contained within the current string.

        Args:
          substr: The substring to check.

        Returns:
          True if the string contains the substring.
        """
        return self.find(substr) != -1

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

        var len_self = self.byte_length()
        var count = len_self * n + 1
        var buf = String._buffer_type(capacity=count)
        buf.size = count
        var b_ptr = buf.unsafe_ptr()
        for i in range(n):
            memcpy(b_ptr + len_self * i, self.unsafe_ptr(), len_self)
        b_ptr[count - 1] = 0
        return String(buf^)

    # ===------------------------------------------------------------------===#
    # Methods
    # ===------------------------------------------------------------------===#

    @always_inline
    fn strip(self, chars: StringSlice) -> Self:
        """Return a copy of the string with leading and trailing characters
        removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no leading or trailing characters.

        Examples:

        ```mojo
        print("himojohi".strip("hi")) # "mojo"
        ```
        .
        """

        return self.lstrip(chars).rstrip(chars)

    @always_inline
    fn strip(self) -> Self:
        """Return a copy of the string with leading and trailing whitespaces
        removed. This only takes ASCII whitespace into account:
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

        Returns:
            A copy of the string with no leading or trailing whitespaces.

        Examples:

        ```mojo
        print("  mojo  ".strip()) # "mojo"
        ```
        .
        """
        return self.lstrip().rstrip()

    @always_inline
    fn rstrip(self, chars: StringSlice) -> Self:
        """Return a copy of the string with trailing characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no trailing characters.

        Examples:

        ```mojo
        print("mojohi".strip("hi")) # "mojo"
        ```
        .
        """

        var r_idx = self.byte_length()
        while r_idx > 0 and self[r_idx - 1] in chars:
            r_idx -= 1

        return Self(unsafe_from_utf8=self.as_bytes()[:r_idx])

    @always_inline
    fn rstrip(self) -> Self:
        """Return a copy of the string with trailing whitespaces removed. This
        only takes ASCII whitespace into account:
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

        Returns:
            A copy of the string with no trailing whitespaces.

        Examples:

        ```mojo
        print("mojo  ".strip()) # "mojo"
        ```
        .
        """
        var r_idx = self.byte_length()
        # TODO (#933): should use this once llvm intrinsics can be used at comp time
        # for s in self.__reversed__():
        #     if not s.isspace():
        #         break
        #     r_idx -= 1
        while r_idx > 0 and Char(self.as_bytes()[r_idx - 1]).is_posix_space():
            r_idx -= 1
        return Self(unsafe_from_utf8=self.as_bytes()[:r_idx])

    @always_inline
    fn lstrip(self, chars: StringSlice) -> Self:
        """Return a copy of the string with leading characters removed.

        Args:
            chars: A set of characters to be removed. Defaults to whitespace.

        Returns:
            A copy of the string with no leading characters.

        Examples:

        ```mojo
        print("himojo".strip("hi")) # "mojo"
        ```
        .
        """

        var l_idx = 0
        while l_idx < self.byte_length() and self[l_idx] in chars:
            l_idx += 1

        return Self(unsafe_from_utf8=self.as_bytes()[l_idx:])

    @always_inline
    fn lstrip(self) -> Self:
        """Return a copy of the string with leading whitespaces removed. This
        only takes ASCII whitespace into account:
        `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e"`.

        Returns:
            A copy of the string with no leading whitespaces.

        Examples:

        ```mojo
        print("  mojo".strip()) # "mojo"
        ```
        .
        """
        var l_idx = 0
        # TODO (#933): should use this once llvm intrinsics can be used at comp time
        # for s in self:
        #     if not s.isspace():
        #         break
        #     l_idx += 1
        while (
            l_idx < self.byte_length()
            and Char(self.as_bytes()[l_idx]).is_posix_space()
        ):
            l_idx += 1
        return Self(unsafe_from_utf8=self.as_bytes()[l_idx:])

    @always_inline
    fn chars(self) -> CharsIter[origin]:
        """Returns an iterator over the `Char`s encoded in this string slice.

        Returns:
            An iterator type that returns successive `Char` values stored in
            this string slice.

        # Examples

        Print the characters in a string:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var s = StringSlice("abc")
        var iter = s.chars()
        assert_equal(iter.__next__(), Char.ord("a"))
        assert_equal(iter.__next__(), Char.ord("b"))
        assert_equal(iter.__next__(), Char.ord("c"))
        assert_equal(iter.__has_next__(), False)
        ```

        `chars()` iterates over Unicode codepoints, and supports multibyte
        codepoints:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        # A visual character composed of a combining sequence of 2 codepoints.
        var s = StringSlice("á")
        assert_equal(s.byte_length(), 3)

        var iter = s.chars()
        assert_equal(iter.__next__(), Char.ord("a"))
         # U+0301 Combining Acute Accent
        assert_equal(iter.__next__().to_u32(), 0x0301)
        assert_equal(iter.__has_next__(), False)
        ```
        .
        """
        return CharsIter(self)

    fn char_slices(self) -> _StringSliceIter[origin]:
        """Iterate over the string, returning immutable references.

        Returns:
            An iterator of references to the string elements.
        """
        return _StringSliceIter[origin](
            ptr=self.unsafe_ptr(), length=self.byte_length()
        )

    @always_inline
    fn as_bytes(self) -> Span[Byte, origin]:
        """Get the sequence of encoded bytes of the underlying string.

        Returns:
            A slice containing the underlying sequence of encoded bytes.
        """
        return self._slice

    @always_inline
    fn unsafe_ptr(
        self,
    ) -> UnsafePointer[Byte, mut=mut, origin=origin]:
        """Gets a pointer to the first element of this string slice.

        Returns:
            A pointer pointing at the first element of this string slice.
        """
        return self._slice.unsafe_ptr()

    @always_inline
    fn byte_length(self) -> Int:
        """Get the length of this string slice in bytes.

        Returns:
            The length of this string slice in bytes.
        """

        return len(self.as_bytes())

    fn char_length(self) -> UInt:
        """Returns the length in Unicode codepoints.

        This returns the number of `Char` codepoint values encoded in the UTF-8
        representation of this string.

        Note: To get the length in bytes, use `StringSlice.byte_length()`.

        Returns:
            The length in Unicode codepoints.

        # Examples

        Query the length of a string, in bytes and Unicode codepoints:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var s = StringSlice("ನಮಸ್ಕಾರ")

        assert_equal(s.char_length(), 7)
        assert_equal(len(s), 21)
        ```

        Strings containing only ASCII characters have the same byte and
        Unicode codepoint length:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var s = StringSlice("abc")

        assert_equal(s.char_length(), 3)
        assert_equal(len(s), 3)
        ```

        The character length of a string with visual combining characters is
        the length in Unicode codepoints, not grapheme clusters:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_equal

        var s = StringSlice("á")
        assert_equal(s.char_length(), 2)
        assert_equal(s.byte_length(), 3)
        ```
        .
        """
        # Every codepoint is encoded as one leading byte + 0 to 3 continuation
        # bytes.
        # The total number of codepoints is equal the number of leading bytes.
        # So we can compute the number of leading bytes (and thereby codepoints)
        # by subtracting the number of continuation bytes length from the
        # overall length in bytes.
        # For a visual explanation of how this UTF-8 codepoint counting works:
        #   https://connorgray.com/ephemera/project-log#2025-01-13
        var continuation_count = _count_utf8_continuation_bytes(self)
        return self.byte_length() - continuation_count

    fn get_immutable(
        self,
    ) -> StringSlice[ImmutableOrigin.cast_from[origin].result]:
        """
        Return an immutable version of this string slice.

        Returns:
            A string slice covering the same elements, but without mutability.
        """
        return StringSlice[ImmutableOrigin.cast_from[origin].result](
            ptr=self._slice.unsafe_ptr(),
            length=len(self),
        )

    fn startswith(
        self, prefix: StringSlice, start: Int = 0, end: Int = -1
    ) -> Bool:
        """Verify if the `StringSlice` starts with the specified prefix between
        start and end positions.

        Args:
            prefix: The prefix to check.
            start: The start offset from which to check.
            end: The end offset from which to check.

        Returns:
            True if the `self[start:end]` is prefixed by the input prefix.
        """
        if end == -1:
            return self.find(prefix, start) == start
        # FIXME: use normalize_index
        return StringSlice[origin](
            ptr=self.unsafe_ptr() + start, length=end - start
        ).startswith(prefix)

    fn endswith(
        self, suffix: StringSlice, start: Int = 0, end: Int = -1
    ) -> Bool:
        """Verify if the `StringSlice` end with the specified suffix between
        start and end positions.

        Args:
            suffix: The suffix to check.
            start: The start offset from which to check.
            end: The end offset from which to check.

        Returns:
            True if the `self[start:end]` is suffixed by the input suffix.
        """
        if len(suffix) > len(self):
            return False
        if end == -1:
            return self.rfind(suffix, start) + len(suffix) == len(self)
        # FIXME: use normalize_index
        return StringSlice[origin](
            ptr=self.unsafe_ptr() + start, length=end - start
        ).endswith(suffix)

    fn _from_start(self, start: Int) -> Self:
        """Gets the `StringSlice` pointing to the substring after the specified
        slice start position. If start is negative, it is interpreted as the
        number of characters from the end of the string to start at.

        Args:
            start: Starting index of the slice.

        Returns:
            A `StringSlice` borrowed from the current string containing the
            characters of the slice starting at start.
        """
        # FIXME: use normalize_index

        var self_len = self.byte_length()

        var abs_start: Int
        if start < 0:
            # Avoid out of bounds earlier than the start
            # len = 5, start = -3,  then abs_start == 2, i.e. a partial string
            # len = 5, start = -10, then abs_start == 0, i.e. the full string
            abs_start = max(self_len + start, 0)
        else:
            # Avoid out of bounds past the end
            # len = 5, start = 2,   then abs_start == 2, i.e. a partial string
            # len = 5, start = 8,   then abs_start == 5, i.e. an empty string
            abs_start = min(start, self_len)

        debug_assert(
            abs_start >= 0, "strref absolute start must be non-negative"
        )
        debug_assert(
            abs_start <= self_len,
            "strref absolute start must be less than source String len",
        )

        # TODO: We assumes the StringSlice only has ASCII.
        # When we support utf-8 slicing, we should drop self._slice[abs_start:]
        # and use something smarter.
        return StringSlice(unsafe_from_utf8=self._slice[abs_start:])

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
        print("{0} {1} {0}".format("Mojo", 1.125)) # Mojo 1.125 Mojo
        # Automatic indexing:
        print("{} {}".format(True, "hello world")) # True hello world
        ```
        .
        """
        return _FormatCurlyEntry.format(self, args)

    fn find(ref self, substr: StringSlice, start: Int = 0) -> Int:
        """Finds the offset of the first occurrence of `substr` starting at
        `start`. If not found, returns `-1`.

        Args:
            substr: The substring to find.
            start: The offset from which to find.

        Returns:
            The offset of `substr` relative to the beginning of the string.
        """
        if not substr:
            return 0

        if self.byte_length() < substr.byte_length() + start:
            return -1

        # The substring to search within, offset from the beginning if `start`
        # is positive, and offset from the end if `start` is negative.
        var haystack_str = self._from_start(start)

        var loc = _memmem(
            haystack_str.unsafe_ptr(),
            haystack_str.byte_length(),
            substr.unsafe_ptr(),
            substr.byte_length(),
        )

        if not loc:
            return -1

        return Int(loc) - Int(self.unsafe_ptr())

    fn rfind(self, substr: StringSlice, start: Int = 0) -> Int:
        """Finds the offset of the last occurrence of `substr` starting at
        `start`. If not found, returns `-1`.

        Args:
            substr: The substring to find.
            start: The offset from which to find.

        Returns:
            The offset of `substr` relative to the beginning of the string.
        """
        if not substr:
            return len(self)

        if len(self) < len(substr) + start:
            return -1

        # The substring to search within, offset from the beginning if `start`
        # is positive, and offset from the end if `start` is negative.
        var haystack_str = self._from_start(start)

        var loc = _memrmem(
            haystack_str.unsafe_ptr(),
            len(haystack_str),
            substr.unsafe_ptr(),
            len(substr),
        )

        if not loc:
            return -1

        return Int(loc) - Int(self.unsafe_ptr())

    fn isspace(self) -> Bool:
        """Determines whether every character in the given StringSlice is a
        python whitespace String. This corresponds to Python's
        [universal separators](
        https://docs.python.org/3/library/stdtypes.html#str.splitlines):
         `" \\t\\n\\v\\f\\r\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Returns:
            True if the whole StringSlice is made up of whitespace characters
            listed above, otherwise False.

        Examples:

        Check if a string contains only whitespace:

        ```mojo
        from collections.string import StringSlice
        from testing import assert_true, assert_false

        # An empty string is not considered to contain only whitespace chars:
        assert_false(StringSlice("").isspace())

        # ASCII space characters
        assert_true(StringSlice(" ").isspace())
        assert_true(StringSlice("\t").isspace())

        # Contains non-space characters
        assert_false(StringSlice(" abc  ").isspace())
        ```
        .
        """

        if self.byte_length() == 0:
            return False

        for s in self.chars():
            if not s.is_python_space():
                return False

        return True

    fn isnewline[single_character: Bool = False](self) -> Bool:
        """Determines whether every character in the given StringSlice is a
        python newline character. This corresponds to Python's
        [universal newlines:](
        https://docs.python.org/3/library/stdtypes.html#str.splitlines)
        `"\\r\\n"` and `"\\t\\n\\v\\f\\r\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Parameters:
            single_character: Whether to evaluate the stringslice as a single
                unicode character (avoids overhead when already iterating).

        Returns:
            True if the whole StringSlice is made up of whitespace characters
                listed above, otherwise False.
        """

        var ptr = self.unsafe_ptr()
        var length = self.byte_length()

        @parameter
        if single_character:
            return length != 0 and _is_newline_char[include_r_n=True](
                ptr, 0, ptr[0], length
            )
        else:
            var offset = 0
            for s in self.char_slices():
                var b_len = s.byte_length()
                if not _is_newline_char(ptr, offset, ptr[offset], b_len):
                    return False
                offset += b_len
            return length != 0

    fn splitlines[
        O: ImmutableOrigin, //
    ](self: StringSlice[O], keepends: Bool = False) -> List[StringSlice[O]]:
        """Split the string at line boundaries. This corresponds to Python's
        [universal newlines:](
        https://docs.python.org/3/library/stdtypes.html#str.splitlines)
        `"\\r\\n"` and `"\\t\\n\\v\\f\\r\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"`.

        Parameters:
            O: The immutable origin.

        Args:
            keepends: If True, line breaks are kept in the resulting strings.

        Returns:
            A List of Strings containing the input split by line boundaries.
        """

        # highly performance sensitive code, benchmark before touching
        alias `\r` = UInt8(ord("\r"))
        alias `\n` = UInt8(ord("\n"))

        output = List[StringSlice[O]](capacity=128)  # guessing
        var ptr = self.unsafe_ptr()
        var length = self.byte_length()
        var offset = 0

        while offset < length:
            var eol_start = offset
            var eol_length = 0

            while eol_start < length:
                var b0 = ptr[eol_start]
                var char_len = _utf8_first_byte_sequence_length(b0)
                debug_assert(
                    eol_start + char_len <= length,
                    "corrupted sequence causing unsafe memory access",
                )
                var isnewline = unlikely(
                    _is_newline_char(ptr, eol_start, b0, char_len)
                )
                var char_end = Int(isnewline) * (eol_start + char_len)
                var next_idx = char_end * Int(char_end < length)
                var is_r_n = b0 == `\r` and next_idx != 0 and ptr[
                    next_idx
                ] == `\n`
                eol_length = Int(isnewline) * char_len + Int(is_r_n)
                if isnewline:
                    break
                eol_start += char_len

            var str_len = eol_start - offset + Int(keepends) * eol_length
            var s = StringSlice[O](ptr=ptr + offset, length=str_len)
            output.append(s)
            offset = eol_start + eol_length

        return output^

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


# ===-----------------------------------------------------------------------===#
# Utils
# ===-----------------------------------------------------------------------===#


fn _to_string_list[
    T: CollectionElement,  # TODO(MOCO-1446): Make `T` parameter inferred
    len_fn: fn (T) -> Int,
    unsafe_ptr_fn: fn (T) -> UnsafePointer[Byte],
](items: List[T]) -> List[String]:
    i_len = len(items)
    i_ptr = items.unsafe_ptr()
    out_ptr = UnsafePointer[String].alloc(i_len)

    for i in range(i_len):
        og_len = len_fn(i_ptr[i])
        f_len = og_len + 1  # null terminator
        p = UnsafePointer[Byte].alloc(f_len)
        og_ptr = unsafe_ptr_fn(i_ptr[i])
        memcpy(p, og_ptr, og_len)
        p[og_len] = 0  # null terminator
        buf = String._buffer_type(ptr=p, length=f_len, capacity=f_len)
        (out_ptr + i).init_pointee_move(String(buf^))
    return List[String](ptr=out_ptr, length=i_len, capacity=i_len)


@always_inline
fn _to_string_list[
    O: ImmutableOrigin, //
](items: List[StringSlice[O]]) -> List[String]:
    """Create a list of Strings **copying** the existing data.

    Parameters:
        O: The origin of the data.

    Args:
        items: The List of string slices.

    Returns:
        The list of created strings.
    """

    fn unsafe_ptr_fn(v: StringSlice[O]) -> UnsafePointer[Byte]:
        return v.unsafe_ptr()

    fn len_fn(v: StringSlice[O]) -> Int:
        return v.byte_length()

    return _to_string_list[items.T, len_fn, unsafe_ptr_fn](items)


@always_inline
fn _to_string_list[
    O: ImmutableOrigin, //
](items: List[Span[Byte, O]]) -> List[String]:
    """Create a list of Strings **copying** the existing data.

    Parameters:
        O: The origin of the data.

    Args:
        items: The List of Bytes.

    Returns:
        The list of created strings.
    """

    fn unsafe_ptr_fn(v: Span[Byte, O]) -> UnsafePointer[Byte]:
        return v.unsafe_ptr()

    fn len_fn(v: Span[Byte, O]) -> Int:
        return len(v)

    return _to_string_list[items.T, len_fn, unsafe_ptr_fn](items)


@always_inline
fn _is_newline_char[
    include_r_n: Bool = False
](p: UnsafePointer[Byte], eol_start: Int, b0: Byte, char_len: Int) -> Bool:
    """Returns whether the char is a newline char.

    Safety:
        This assumes valid utf-8 is passed.
    """
    # highly performance sensitive code, benchmark before touching
    alias `\r` = UInt8(ord("\r"))
    alias `\n` = UInt8(ord("\n"))
    alias `\t` = UInt8(ord("\t"))
    alias `\x1c` = UInt8(ord("\x1c"))
    alias `\x1e` = UInt8(ord("\x1e"))

    # here it's actually faster to have branching due to the branch predictor
    # "realizing" that the char_len == 1 path is often taken. Using the likely
    # intrinsic is to make the machine code be ordered to optimize machine
    # instruction fetching, which is an optimization for the CPU front-end.
    if likely(char_len == 1):
        return `\t` <= b0 <= `\x1e` and not (`\r` < b0 < `\x1c`)
    elif char_len == 2:
        var b1 = p[eol_start + 1]
        var is_next_line = b0 == 0xC2 and b1 == 0x85  # unicode next line \x85

        @parameter
        if include_r_n:
            return is_next_line or (b0 == `\r` and b1 == `\n`)
        else:
            return is_next_line
    elif char_len == 3:  # unicode line sep or paragraph sep: \u2028 , \u2029
        var b1 = p[eol_start + 1]
        var b2 = p[eol_start + 2]
        return b0 == 0xE2 and b1 == 0x80 and (b2 == 0xA8 or b2 == 0xA9)
    return False


@always_inline
fn _unsafe_strlen(owned ptr: UnsafePointer[Byte]) -> Int:
    """
    Get the length of a null-terminated string from a pointer.
    Note: the length does NOT include the null terminator.

    Args:
        ptr: The null-terminated pointer to the string.

    Returns:
        The length of the null terminated string without the null terminator.
    """
    var len = 0
    while ptr.load(len):
        len += 1
    return len
