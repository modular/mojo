# Mojo unreleased changelog

This is a list of UNRELEASED changes for the Mojo language and tools.

When we cut a release, these notes move to `changelog-released.md` and that's
what we publish.

[//]: # Here's the template to use when starting a new batch of notes:
[//]: ## UNRELEASED
[//]: ### ⭐️ New
[//]: ### 🦋 Changed
[//]: ### ❌ Removed
[//]: ### 🛠️ Fixed

## UNRELEASED

### ⭐️ New

- Mojo can now interpret simple LLVM intrinsics in parameter expressions,
  enabling things like `count_leading_zeros` to work at compile time:
  [Issue #933](https://github.com/modularml/mojo/issues/933).

- The VS Code Mojo Debugger now has a `buildArgs` JSON debug configuration
  setting that can be used in conjunction with `mojoFile` to define the build
  arguments when compiling the Mojo file.

- The VS Code extension now supports a `Configure Build and Run Args` command
  that helps set the build and run args for actions file `Run Mojo File` and
  `Debug Mojo File`. A corresponding button appears in `Run and Debug` selector
  in the top right corner of a Mojo File.

- Add the `Floatable` and `FloatableRaising` traits to denote types that can
  be converted to a `Float64` value using the builtin `float` function.
  - Make `SIMD` and `FloatLiteral` conform to the `Floatable` trait.

  ```mojo
  fn foo[F: Floatable](v: F):
    ...

  var f = float(Int32(45))
  ```

  ([PR #3163](https://github.com/modularml/mojo/pull/3163) by [@bgreni](https://github.com/bgreni))

- Add `DLHandle.get_symbol()`, for getting a pointer to a symbol in a dynamic
  library. This is more general purpose than the existing methods for getting
  function pointers.

- Introduce `TypedPythonObject` as a light-weight way to annotate `PythonObject`
  values with static type information. This design will likely evolve and
  change significantly.

  - Added `TypedPythonObject["Tuple].__getitem__` for accessing the elements of
    a Python tuple.

- Added `Python.unsafe_get_python_exception()`, as an efficient low-level
  utility to get the Mojo `Error` equivalent of the current CPython error state.

- The `__type_of(x)` and `__lifetime_of(x)` operators are much more general now:
  they allow arbitrary expressions inside of them, allow referring to dynamic
  values in parameter contexts, and even allow referring to raising functions
  in non-raising contexts.  These operations never evaluate their expression, so
  any side effects that occur in the expression are never evaluated at runtime,
  eliminating concerns about `__type_of(expensive())` being a problem.

- Add `PythonObject.from_borrowed_ptr()`, to simplify the construction of
  `PythonObject` values from CPython 'borrowed reference' pointers.

  The existing `PythonObject.__init__(PyObjectPtr)` should continue to be used
  for the more common case of constructing a `PythonObject` from a
  'strong reference' pointer.

- The `rebind` standard library function now works with memory-only types in
  addition to `@register_passable("trivial")` ones, without requiring a copy.

- Autoparameterization of parameters is now supported. Specifying a parameter
  type with unbound parameters causes them to be implicitly added to the
  function signature as inferred parameters.

  ```mojo
  fn foo[value: SIMD[DType.int32, _]]():
    pass

  # Equivalent to
  fn foo[size: Int, //, value: SIMD[DType.int32, size]]():
    pass
  ```

- Function types now accept a lifetime set parameter. This parameter represents
  the lifetimes of values captured by a parameter closure. The compiler
  automatically tags parameter closures with the right set of lifetimes. This
  enables lifetimes and parameter closures to correctly compose.

  ```mojo
  fn call_it[f: fn() capturing [_] -> None]():
      f()

  fn test():
      var msg = String("hello world")

      @parameter
      fn say_hi():
          print(msg)

      call_it[say_hi]()
      # no longer need to write `_ = msg^`!!
  ```

  Note that this only works for higher-order functions which have explicitly
  added `[_]` as the capture lifetimes. By default, the compiler still assumes
  a `capturing` closure does not reference any lifetimes. This will soon change.

- The VS Code extension now has the `mojo.run.focusOnTerminalAfterLaunch`
  setting, which controls whether to focus on the terminal used by the
  `Mojo: Run Mojo File` command or on the editor after launch.
  [Issue #3532](https://github.com/modularml/mojo/issues/3532).

- The VS Code extension now has the `mojo.SDK.additionalSDKs` setting, which
  allows the user to provide a list of MAX SDKs that the extension can use when
  determining a default SDK to use. The user can select the default SDK to use
  with the `Mojo: Select the default MAX SDK` command.

### 🦋 Changed

- More things have been removed from the auto-exported set of entities in the `prelude`
  module from the Mojo standard library.
  - `UnsafePointer` has been removed. Please explicitly import it via
    `from memory import UnsafePointer`.
  - `StringRef` has been removed. Please explicitly import it via
    `from utils import StringRef`.

- A new `as_noalias_ptr` method as been added to `UnsafePointer`. This method
  specifies to the compiler that the resultant pointer is a distinct
  identifiable object that does not alias any other memory in the local scope.

- The `AnyLifetime` type (useful for declaring lifetime types as parameters) has
  been renamed to `Lifetime`.

- Restore implicit copyability of `Tuple` and `ListLiteral`.

- The aliases for C FFI have been renamed: `C_int` -> `c_int`, `C_long` -> `c_long`
  and so on.

- The VS Code extension now allows selecting a default SDK when multiple are available.

- `String.as_bytes_slice()` is renamed to `String.as_bytes_span()` since it
  returns a `Span` and not a `StringSlice`.

### ❌ Removed

### 🛠️ Fixed

- Lifetime tracking is now fully field sensitive, which makes the uninitialized
  variable checker more precise.

- [Issue #3444](https://github.com/modularml/mojo/issues/3444) - Raising init
  causing use of uninitialized variable

- The VS Code extension now auto-updates its private copy of the MAX SDK.
