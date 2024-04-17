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
"""Provides the `str` function.

These are Mojo built-ins, so you don't need to import them.
"""

# ===----------------------------------------------------------------------=== #
# Stringable
# ===----------------------------------------------------------------------=== #
from ..collections.list import StringableCollectionElement


trait Stringable:
    """
    The `Stringable` trait describes a type that can be converted to a
    [`String`](https://docs.modular.com/mojo/stdlib/builtin/string.html).

    Any type that conforms to `Stringable` or
    [`StringableRaising`](/mojo/stdlib/builtin/str/stringableraising) works
    with the built-in [`print()`](/mojo/stdlib/builtin/io/print) and
    [`str()`](/mojo/stdlib/builtin/str.html) functions.

    The `Stringable` trait requires the type to define the `__str__()` method.
    For example:

    ```mojo
    @value
    struct Foo(Stringable):
        var s: String

        fn __str__(self) -> String:
            return self.s
    ```

    Now you can pass an instance of `Foo` to the `str()` function to get back a
    `String`:

    ```mojo
    var foo = Foo("test")
    print(str(foo) == "test")
    ```

    ```plaintext
    True
    ```

    **Note:** If the `__str__()` method might raise an error, use the
    [`StringableRaising`](/mojo/stdlib/builtin/str/stringableraising)
    trait, instead.
    """

    fn __str__(self) -> String:
        """Get the string representation of the type.

        Returns:
            The string representation of the type.
        """
        ...


trait StringableRaising:
    """The StringableRaising trait describes a type that can be converted to a
    [`String`](https://docs.modular.com/mojo/stdlib/builtin/string.html).

    Any type that conforms to
    [`Stringable`](/mojo/stdlib/builtin/str/stringable) or
    `StringableRaising` works with the built-in
    [`print()`](/mojo/stdlib/builtin/io/print) and
    [`str()`](/mojo/stdlib/builtin/str/str) functions.

    The `StringableRaising` trait requires the type to define the `__str__()`
    method, which can raise an error. For example:

    ```mojo
    @value
    struct Foo(StringableRaising):
        var s: String

        fn __str__(self) raises -> String:
            if self.s == "":
                raise Error("Empty String")
            return self.s
    ```

    Now you can pass an instance of `Foo` to the `str()` function to get back a
    `String`:

    ```mojo
    fn main() raises:
        var foo = Foo("test")
        print(str(foo) == "test")
    ```

    ```plaintext
    True
    ```
    """

    fn __str__(self) raises -> String:
        """Get the string representation of the type.

        Returns:
            The string representation of the type.

        Raises:
            If there is an error when computing the string representation of the type.
        """
        ...


# ===----------------------------------------------------------------------=== #
#  str
# ===----------------------------------------------------------------------=== #


@always_inline
fn str[T: Stringable](value: T) -> String:
    """Get the string representation of a value.

    Parameters:
        T: The type conforming to Stringable.

    Args:
        value: The object to get the string representation of.

    Returns:
        The string representation of the object.
    """
    return value.__str__()


@always_inline
fn str(value: None) -> String:
    """Get the string representation of the `None` type.

    Args:
        value: The object to get the string representation of.

    Returns:
        The string representation of the object.
    """
    return "None"


@always_inline
fn str[T: StringableRaising](value: T) raises -> String:
    """Get the string representation of a value.

    Parameters:
        T: The type conforming to Stringable.

    Args:
        value: The object to get the string representation of.

    Returns:
        The string representation of the object.

    Raises:
        If there is an error when computing the string representation of the type.
    """
    return value.__str__()


@always_inline
fn str[T: StringableCollectionElement](value: List[T]) -> String:
    """Get the string representation of a list of strings.

    Parameters:
        T: The type conforming to Stringable and a CollectionElement.

    Args:
        value: The object to get the string representation of.

    Returns:
        The string representation of the object.
    """
    return __type_of(value).__str__(value)
