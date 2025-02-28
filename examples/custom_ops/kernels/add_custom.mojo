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

import compiler
from max.tensor import ManagedTensorSlice, foreach
from runtime.asyncrt import DeviceContextPtr

from utils.index import IndexList


@compiler.register("add_constant_custom", num_dps_outputs=1)
struct AddConstantCustom[value: Int]:
    @staticmethod
    fn execute[
        # e.g. "CUDA" or "CPU"
        target: StringLiteral,
    ](
        # as num_dps_outputs=1, the first argument is the "output"
        out: ManagedTensorSlice,
        # starting here are the list of inputs
        x: ManagedTensorSlice[type = out.type, rank = out.rank],
        # the context is needed for some GPU calls
        ctx: DeviceContextPtr,
    ):
        @parameter
        @always_inline
        fn add_constant[
            width: Int
        ](idx: IndexList[x.rank]) -> SIMD[x.type, width]:
            return x.load[width](idx) + value

        foreach[add_constant, target=target](out, ctx)

    # You only need to implement this if you do not manually annotate
    # output shapes in the graph.
    @staticmethod
    fn shape(
        x: ManagedTensorSlice,
    ) raises -> IndexList[x.rank]:
        raise "NotImplemented"


@compiler.register("add_one_custom", num_dps_outputs=1)
struct AddOneCustom:
    @staticmethod
    fn execute[
        # The kind of device this will be run on: "cpu" or "gpu"
        target: StringLiteral,
    ](
        # as num_dps_outputs=1, the first argument is the "output"
        out: ManagedTensorSlice,
        # starting here are the list of inputs
        x: ManagedTensorSlice[type = out.type, rank = out.rank],
        # the context is needed for some GPU calls
        ctx: DeviceContextPtr,
    ):
        @parameter
        @always_inline
        fn elementwise_add_one[
            width: Int
        ](idx: IndexList[x.rank]) -> SIMD[x.type, width]:
            return x.load[width](idx) + 1

        foreach[elementwise_add_one, target=target](out, ctx)

    # You only need to implement this if you do not manually annotate
    # output shapes in the graph.
    @staticmethod
    fn shape(
        x: ManagedTensorSlice,
    ) raises -> IndexList[x.rank]:
        raise "NotImplemented"
