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
"""This module includes the inlined_assembly function."""

from sys.intrinsics import _mlirtype_is_eq
from builtin.builtin_list import _LITRefPackHelper

# ===----------------------------------------------------------------------===#
# 0-arg
# ===----------------------------------------------------------------------===#


@always_inline("nodebug")
fn inlined_assembly[
    asm: StringLiteral,
    result_type: AnyTrivialRegType,
    *types: AnyType,
    constraints: StringLiteral,
    has_side_effect: Bool = True,
](*arguments: *types) -> result_type:
    """Generates assembly via inline assembly."""
    var loaded_pack = _LITRefPackHelper(arguments._value).get_loaded_kgen_pack()

    @parameter
    if has_side_effect:
        return __mlir_op.`pop.inline_asm`[
            _type=result_type,
            assembly = asm.value,
            constraints = constraints.value,
            hasSideEffects = __mlir_attr.unit,
        ](loaded_pack)
    else:
        return __mlir_op.`pop.inline_asm`[
            _type=result_type,
            assembly = asm.value,
            constraints = constraints.value,
        ](loaded_pack)
