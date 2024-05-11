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
"""Defines the `InlineList` type.

You can import these APIs from the `collections` package. For example:

```mojo
from collections import InlineList
```
"""

from utils import InlineArray

# ===----------------------------------------------------------------------===#
# InlineList
# ===----------------------------------------------------------------------===#


# TODO: Provide a smarter default for the capacity.
struct InlineList[ElementType: CollectionElement, capacity: Int = 16](
    Sized, CollectionElement
):
    """A list allocated on the stack with a maximum size known at compile time.

    It is backed by an `InlineArray` and an `Int` to represent the size.
    This struct has the same API as a regular `List`, but it is not possible to change the
    capacity. In other words, it has a fixed maximum size.

    This is typically faster than a `List` as it is only stack-allocated and does not require
    any dynamic memory allocation.

    Parameters:
        ElementType: The type of the elements in the list.
        capacity: The maximum number of elements that the list can hold.
    """

    var _array: InlineArray[ElementType, capacity]
    var _size: Int

    @always_inline
    fn __init__(inout self):
        """This constructor creates an empty InlineList."""
        self._array = InlineArray[ElementType, capacity](uninitialized=True)
        self._size = 0

    fn __moveinit__(inout self, owned other: Self):
        """Move constructor.

        Args:
            other: The InlineList to move from.
        """
        self._array = other._array
        self._size = other._size

    fn __copyinit__(inout self, other: Self, /) -> None:
        """Copy constructor.

        Args:
            other: The InlineList to copy from.
        """
        self._array = other._array
        self._size = other._size

    @always_inline
    fn __len__(self) -> Int:
        """Returns the length of the list."""
        return self._size

    @always_inline
    fn append(inout self, owned value: ElementType):
        """Appends a value to the list.

        Args:
            value: The value to append.
        """
        debug_assert(self._size < capacity, "List is full.")
        self._array[self._size] = value^
        self._size += 1

    @always_inline
    fn __refitem__[
        IntableType: Intable,
    ](self: Reference[Self, _, _], index: IntableType) -> Reference[
        Self.ElementType, self.is_mutable, self.lifetime
    ]:
        """Get a `Reference` to the element at the given index.

        Args:
            index: The index of the item.

        Returns:
            A reference to the item at the given index.
        """
        var i = int(index)
        debug_assert(
            -self[]._size <= i < self[]._size, "Index must be within bounds."
        )

        if i < 0:
            i += len(self[])

        return self[]._array[i]

    @always_inline
    fn __del__(owned self):
        """Destroy all the elements in the list and free the memory."""
        for i in range(self._size):
            destroy_pointee(UnsafePointer(self._array[i]))

    @always_inline
    fn unsafe_ptr(self) -> UnsafePointer[ElementType]:
        """Returns a pointer to the first element in the list.

        Returns:
            A pointer to the first element in the list.
        """
        return self._array.unsafe_ptr()

    @always_inline
    fn resize(inout self, new_size: Int, value: ElementType):
        """Resizes the list to the new size.

        If the new size is greater than the current size, the list is extended with the given
        value. If the new size is smaller, the list is truncated.

        Args:
            new_size: The new size of the list.
            value: The value to append if the list is extended.
        """
        if new_size > self._size:
            for i in range(self._size, new_size):
                self.append(value)
        else:
            # Destroy in reverse order
            for i in range(new_size, self._size):
                _ = self.pop()
            self._size = new_size

    @always_inline
    fn pop(inout self) -> ElementType:
        """Removes and returns the last element from the list.

        Returns:
            The last element in the list.
        """
        debug_assert(self._size > 0, "pop from empty list")
        var value_to_pop = self._array[self._size - 1]
        self._size -= 1
        return value_to_pop
