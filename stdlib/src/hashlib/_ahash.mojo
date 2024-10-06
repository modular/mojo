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

from bit import byte_swap
from bit import rotate_bits_left
from memory import UnsafePointer

alias U256 = SIMD[DType.uint64, 4]
alias U128 = SIMD[DType.uint64, 2]
alias MULTIPLE = 6364136223846793005
alias ROT = 23


@always_inline
fn _folded_multiply(lhs: UInt64, rhs: UInt64) -> UInt64:
    """A fast function to emulate a folded multiply of two 64 bit uints.
    Used because we don't have UInt128 type.

    Args:
        lhs: 64 bit uint.
        rhs: 64 bit uint.

    Returns:
        A value which is similar in its bitpattern to result of a folded multply.
    """
    var b1 = lhs * byte_swap(rhs)
    var b2 = byte_swap(lhs) * (~rhs)
    return b1 ^ byte_swap(b2)


@always_inline
fn read_small(data: UnsafePointer[UInt8], length: Int) -> U128:
    """Produce a `SIMD[DType.uint64, 2]` value from data which is smaller than or equal to `8` bytes.

    Args:
        data: Pointer to the byte array.
        length: The byte array length.

    Returns:
        Returns a SIMD[DType.uint64, 2] value.
    """
    if length >= 2:
        if length >= 4:
            # len 4-8
            var a = data.bitcast[DType.uint32]().load().cast[DType.uint64]()
            var b = data.offset(length - 4).bitcast[DType.uint32]().load().cast[
                DType.uint64
            ]()
            return U128(a, b)
        else:
            # len 2-3
            var a = data.bitcast[DType.uint16]().load().cast[DType.uint64]()
            var b = data.offset(length - 1).load().cast[DType.uint64]()
            return U128(a, b)
    else:
        # len 0-1
        if length > 0:
            var a = data.load().cast[DType.uint64]()
            return U128(a, a)
        else:
            return U128(0, 0)


struct AHasher:
    var buffer: UInt64
    var pad: UInt64
    var extra_keys: U128

    fn __init__(inout self, key: U256):
        """Initialize the hasher with a key.

        Args:
            key: Modifier for the computation of the final hash value.
        """
        var pi_key = key ^ U256(
            0x243F_6A88_85A3_08D3,
            0x1319_8A2E_0370_7344,
            0xA409_3822_299F_31D0,
            0x082E_FA98_EC4E_6C89,
        )
        self.buffer = pi_key[0]
        self.pad = pi_key[1]
        self.extra_keys = U128(pi_key[2], pi_key[3])

    @always_inline
    fn large_update(inout self, new_data: U128):
        """Update the buffer value with new data.

        Args:
            new_data: Value used for update.
        """
        var xored = new_data ^ self.extra_keys
        var combined = _folded_multiply(xored[0], xored[1])
        self.buffer = rotate_bits_left[ROT]((self.buffer + self.pad) ^ combined)

    @always_inline
    fn finish(self) -> UInt64:
        """Computes the hash value based on all the previously provided data.

        Returns:
            Final hash value.
        """
        var rot = self.buffer & 63
        var folded = _folded_multiply(self.buffer, self.pad)
        return (folded << rot) | (folded >> (64 - rot))

    @always_inline
    fn write(inout self, data: UnsafePointer[UInt8], length: Int):
        """Consume provided data to update the internal buffer.

        Args:
            data: Pointer to the byte array.
            length: The length of the byte array.
        """
        self.buffer = (self.buffer + length) * MULTIPLE
        if length > 8:
            if length > 16:
                var tail = data.offset(length - 16).bitcast[
                    DType.uint64
                ]().load[width=2]()
                self.large_update(tail)
                var offset = 0
                while length - offset > 16:
                    var block = data.offset(offset).bitcast[
                        DType.uint64
                    ]().load[width=2]()
                    self.large_update(block)
                    offset += 16
            else:
                var a = data.bitcast[DType.uint64]().load()
                var b = data.offset(length - 8).bitcast[DType.uint64]().load()
                self.large_update(U128(a, b))
        else:
            var value = read_small(data, length)
            self.large_update(value)


fn hash[
    key: U256 = U256(0, 0, 0, 0)
](bytes: UnsafePointer[UInt8], n: Int) -> UInt:
    """Hash a byte array using an adopted AHash algorithm.

    References:

    - [Pointer Implementation in Rust](https://github.com/tkaitchuck/aHash)

    ```mojo
    from random import rand
    var n = 64
    var rand_bytes = UnsafePointer[UInt8].alloc(n)
    rand(rand_bytes, n)
    _ = hash(rand_bytes, n)
    ```

    Parameters:
        key: A key to modify the result of the hash function, defaults to [0, 0, 0, 0].

    Args:
        bytes: The byte array to hash.
        n: The length of the byte array.

    Returns:
        A 64-bit integer hash. This hash is _not_ suitable for
        cryptographic purposes, but will have good low-bit
        hash collision statistical properties for common data structures.
    """

    var hasher = AHasher(key)
    hasher.write(bytes, n)
    return UInt(int(hasher.finish()))
