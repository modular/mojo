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
"""Implement a generic unsafe pointer type.

You can import these APIs from the `memory` package. For example:

```mojo
from memory import UnsafePointer
```
"""

from sys import alignof, sizeof
from sys.intrinsics import _mlirtype_is_eq, _type_is_eq

from memory.memory import _free, _malloc


# ===----------------------------------------------------------------------=== #
# UnsafePointer
# ===----------------------------------------------------------------------=== #


@register_passable("trivial")
struct UnsafePointer[
    T: AnyType,
    address_space: AddressSpace = AddressSpace.GENERIC,
    exclusive: Bool = False,
](
    ImplicitlyBoolable,
    CollectionElement,
    CollectionElementNew,
    Stringable,
    Formattable,
    Intable,
    Comparable,
):
    """This is a pointer type that can point to any generic value that is movable.

    Parameters:
        T: The type the pointer points to.
        address_space: The address space associated with the UnsafePointer allocated memory.
        exclusive: The underlying memory allocation of the pointer is known only to be accessible through this pointer.
    """

    # Fields
    alias _mlir_type = __mlir_type[
        `!kgen.pointer<`,
        T,
        `, `,
        address_space._value.value,
        ` exclusive(`,
        exclusive.value,
        `)>`,
    ]

    alias type = T

    """The underlying pointer type."""
    var address: Self._mlir_type
    """The underlying pointer."""

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn __init__() -> Self:
        """Create a null pointer.

        Returns:
            A null pointer.
        """
        return Self {
            address: __mlir_attr[`#interp.pointer<0> : `, Self._mlir_type]
        }

    @always_inline
    fn __init__(value: Self._mlir_type) -> Self:
        """Create a pointer with the input value.

        Args:
            value: The MLIR value of the pointer to construct with.

        Returns:
            The pointer.
        """
        return Self {address: value}

    @always_inline
    fn __init__(other: UnsafePointer[T, address_space, _]) -> Self:
        """Exclusivity parameter cast a pointer.

        Args:
            other: Pointer to cast.

        Returns:
            Constructed UnsafePointer object.
        """
        return Self {
            address: __mlir_op.`pop.pointer.bitcast`[_type = Self._mlir_type](
                other.address
            )
        }

    @always_inline
    fn __init__(*, other: Self) -> Self:
        """Copy the object.

        Args:
            other: The value to copy.

        Returns:
            A copy of the object.
        """
        return Self {address: other.address}

    # ===-------------------------------------------------------------------===#
    # Factory methods
    # ===-------------------------------------------------------------------===#

    @staticmethod
    @always_inline("nodebug")
    fn address_of(ref [_, address_space._value.value]arg: T) -> Self:
        """Gets the address of the argument.

        Args:
            arg: The value to get the address of.

        Returns:
            An UnsafePointer which contains the address of the argument.
        """
        return Self(__mlir_op.`lit.ref.to_pointer`(__get_mvalue_as_litref(arg)))

    @staticmethod
    fn _from_dtype_ptr[
        dtype: DType,
    ](ptr: DTypePointer[dtype, address_space]) -> UnsafePointer[
        Scalar[dtype], address_space
    ]:
        return ptr.address.address

    @staticmethod
    @always_inline
    fn alloc[alignment: Int = alignof[T]()](count: Int) -> Self:
        """Allocate an array with specified or default alignment.

        Parameters:
            alignment: The alignment in bytes of the allocated memory.

        Args:
            count: The number of elements in the array.

        Returns:
            The pointer to the newly allocated array.
        """
        alias sizeof_t = sizeof[T]()

        constrained[sizeof_t > 0, "size must be greater than zero"]()
        constrained[alignment > 0, "alignment must be greater than zero"]()
        constrained[
            sizeof_t % alignment == 0, "size must be a multiple of alignment"
        ]()

        return _malloc[T, address_space=address_space](
            sizeof_t * count, alignment=alignment
        )

    # ===-------------------------------------------------------------------===#
    # Operator dunders
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn __getitem__(
        self,
    ) -> ref [MutableStaticLifetime, address_space._value.value] T:
        """Return a reference to the underlying data.

        Returns:
            A reference to the value.
        """

        # We're unsafe, so we can have unsafe things. References we make have
        # an immortal mutable lifetime, since we can't come up with a meaningful
        # lifetime for them anyway.
        alias _ref_type = Reference[T, MutableStaticLifetime, address_space]
        return __get_litref_as_mvalue(
            __mlir_op.`lit.ref.from_pointer`[_type = _ref_type._mlir_type](
                UnsafePointer[T, address_space, False](self).address
            )
        )

    @always_inline
    fn offset(self, idx: Int) -> Self:
        """Returns a new pointer shifted by the specified offset.

        Args:
            idx: The offset of the new pointer.

        Returns:
            The new constructed DTypePointer.
        """
        return __mlir_op.`pop.offset`(self.address, idx.value)

    @always_inline
    fn __getitem__(
        self, offset: Int
    ) -> ref [MutableStaticLifetime, address_space._value.value] T:
        """Return a reference to the underlying data, offset by the given index.

        Args:
            offset: The offset index.

        Returns:
            An offset reference.
        """
        return (self + offset)[]

    @always_inline
    fn __add__(self, offset: Int) -> Self:
        """Return a pointer at an offset from the current one.

        Args:
            offset: The offset index.

        Returns:
            An offset pointer.
        """
        return self.offset(offset)

    @always_inline
    fn __sub__(self, offset: Int) -> Self:
        """Return a pointer at an offset from the current one.

        Args:
            offset: The offset index.

        Returns:
            An offset pointer.
        """
        return self + (-offset)

    @always_inline
    fn __iadd__(inout self, offset: Int):
        """Add an offset to this pointer.

        Args:
            offset: The offset index.
        """
        self = self + offset

    @always_inline
    fn __isub__(inout self, offset: Int):
        """Subtract an offset from this pointer.

        Args:
            offset: The offset index.
        """
        self = self - offset

    @always_inline("nodebug")
    fn __eq__(self, rhs: Self) -> Bool:
        """Returns True if the two pointers are equal.

        Args:
            rhs: The value of the other pointer.

        Returns:
            True if the two pointers are equal and False otherwise.
        """
        return int(self) == int(rhs)

    @always_inline("nodebug")
    fn __ne__(self, rhs: Self) -> Bool:
        """Returns True if the two pointers are not equal.

        Args:
            rhs: The value of the other pointer.

        Returns:
            True if the two pointers are not equal and False otherwise.
        """
        return not (self == rhs)

    @always_inline("nodebug")
    fn __lt__(self, rhs: Self) -> Bool:
        """Returns True if this pointer represents a lower address than rhs.

        Args:
            rhs: The value of the other pointer.

        Returns:
            True if this pointer represents a lower address and False otherwise.
        """
        return int(self) < int(rhs)

    @always_inline("nodebug")
    fn __le__(self, rhs: Self) -> Bool:
        """Returns True if this pointer represents a lower than or equal
           address than rhs.

        Args:
            rhs: The value of the other pointer.

        Returns:
            True if this pointer represents a lower address and False otherwise.
        """
        return int(self) <= int(rhs)

    @always_inline("nodebug")
    fn __gt__(self, rhs: Self) -> Bool:
        """Returns True if this pointer represents a higher address than rhs.

        Args:
            rhs: The value of the other pointer.

        Returns:
            True if this pointer represents a higher than or equal address and False otherwise.
        """
        return int(self) > int(rhs)

    @always_inline("nodebug")
    fn __ge__(self, rhs: Self) -> Bool:
        """Returns True if this pointer represents a higher than or equal
           address than rhs.

        Args:
            rhs: The value of the other pointer.

        Returns:
            True if this pointer represents a higher than or equal address and False otherwise.
        """
        return int(self) >= int(rhs)

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn __bool__(self) -> Bool:
        """Return true if the pointer is non-null.

        Returns:
            Whether the pointer is null.
        """
        return int(self) != 0

    @always_inline
    fn __as_bool__(self) -> Bool:
        """Return true if the pointer is non-null.

        Returns:
            Whether the pointer is null.
        """
        return self.__bool__()

    @always_inline
    fn __int__(self) -> Int:
        """Returns the pointer address as an integer.

        Returns:
          The address of the pointer as an Int.
        """
        return __mlir_op.`pop.pointer_to_index`(self.address)

    @no_inline
    fn __str__(self) -> String:
        """Gets a string representation of the pointer.

        Returns:
            The string representation of the pointer.
        """
        return hex(int(self))

    @no_inline
    fn format_to(self, inout writer: Formatter):
        """
        Formats this pointer address to the provided formatter.

        Args:
            writer: The formatter to write to.
        """

        # TODO: Avoid intermediate String allocation.
        writer.write(str(self))

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn initialize_pointee_explicit_copy[
        T: ExplicitlyCopyable, //
    ](self: UnsafePointer[T], value: T):
        """Emplace a copy of `value` into this pointer location.

        The pointer memory location is assumed to contain uninitialized data,
        and consequently the current contents of this pointer are not destructed
        before writing `value`. Similarly, ownership of `value` is logically
        transferred into the pointer location.

        When compared to `init_pointee_move`, this avoids an extra move on
        the callee side when the value must be copied.

        Parameters:
            T: The type the pointer points to, which must be
               `ExplicitlyCopyable`.

        Args:
            value: The value to emplace.
        """
        __get_address_as_uninit_lvalue(self.address) = T(other=value)

    @always_inline
    fn free(self):
        """Free the memory referenced by the pointer."""
        _free(self)

    @always_inline("nodebug")
    fn bitcast[
        T: AnyType = Self.T,
        /,
        address_space: AddressSpace = Self.address_space,
    ](self) -> UnsafePointer[T, address_space]:
        """Bitcasts a UnsafePointer to a different type.

        Parameters:
            T: The target type.
            address_space: The address space of the result.

        Returns:
            A new UnsafePointer object with the specified type and the same address,
            as the original UnsafePointer.
        """
        return __mlir_op.`pop.pointer.bitcast`[
            _type = UnsafePointer[T, address_space]._mlir_type,
        ](self.address)

    @always_inline
    fn destroy_pointee(self: UnsafePointer[_]):
        """Destroy the pointed-to value.

        The pointer must not be null, and the pointer memory location is assumed
        to contain a valid initialized instance of `T`.  This is equivalent to
        `_ = self.take_pointee()` but doesn't require `Movable` and is
        more efficient because it doesn't invoke `__moveinit__`.

        """
        _ = __get_address_as_owned_value(self.address)

    @always_inline
    fn take_pointee[
        T: Movable, //,
    ](self: UnsafePointer[T]) -> T:
        """Move the value at the pointer out, leaving it uninitialized.

        The pointer must not be null, and the pointer memory location is assumed
        to contain a valid initialized instance of `T`.

        This performs a _consuming_ move, ending the lifetime of the value stored
        in this pointer memory location. Subsequent reads of this pointer are
        not valid. If a new valid value is stored using `init_pointee_move()`, then
        reading from this pointer becomes valid again.

        Parameters:
            T: The type the pointer points to, which must be `Movable`.

        Returns:
            The value at the pointer.
        """
        return __get_address_as_owned_value(self.address)

    # TODO: Allow overloading on more specific traits
    @always_inline
    fn init_pointee_move[
        T: Movable, //,
    ](self: UnsafePointer[T], owned value: T):
        """Emplace a new value into the pointer location, moving from `value`.

        The pointer memory location is assumed to contain uninitialized data,
        and consequently the current contents of this pointer are not destructed
        before writing `value`. Similarly, ownership of `value` is logically
        transferred into the pointer location.

        When compared to `init_pointee_copy`, this avoids an extra copy on
        the caller side when the value is an `owned` rvalue.

        Parameters:
            T: The type the pointer points to, which must be `Movable`.

        Args:
            value: The value to emplace.
        """
        __get_address_as_uninit_lvalue(self.address) = value^

    @always_inline
    fn init_pointee_copy[
        T: Copyable, //,
    ](self: UnsafePointer[T], value: T):
        """Emplace a copy of `value` into the pointer location.

        The pointer memory location is assumed to contain uninitialized data,
        and consequently the current contents of this pointer are not destructed
        before writing `value`. Similarly, ownership of `value` is logically
        transferred into the pointer location.

        When compared to `init_pointee_move`, this avoids an extra move on
        the callee side when the value must be copied.

        Parameters:
            T: The type the pointer points to, which must be `Copyable`.

        Args:
            value: The value to emplace.
        """
        __get_address_as_uninit_lvalue(self.address) = value

    @always_inline
    fn move_pointee_into[
        T: Movable, //,
    ](self: UnsafePointer[T], dst: UnsafePointer[T]):
        """Moves the value `self` points to into the memory location pointed to by
        `dst`.

        This performs a consuming move (using `__moveinit__()`) out of the
        memory location pointed to by `self`. Subsequent reads of this
        pointer are not valid unless and until a new, valid value has been
        moved into this pointer's memory location using `init_pointee_move()`.

        This transfers the value out of `self` and into `dest` using at most one
        `__moveinit__()` call.

        Safety:
            * `self` must be non-null
            * `self` must contain a valid, initialized instance of `T`
            * `dst` must not be null
            * The contents of `dst` should be uninitialized. If `dst` was
                previously written with a valid value, that value will be be
                overwritten and its destructor will NOT be run.

        Parameters:
            T: The type the pointer points to, which must be `Movable`.

        Args:
            dst: Destination pointer that the value will be moved into.
        """
        __get_address_as_uninit_lvalue(
            dst.address
        ) = __get_address_as_owned_value(self.address)
