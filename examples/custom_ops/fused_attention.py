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

import os
from pathlib import Path

import numpy as np
from max.driver import CPU, Accelerator, Tensor, accelerator_count
from max.dtype import DType
from max.engine.api import InferenceSession
from max.graph import Graph, TensorType, ops


def main():
    # This is necessary only for Modular internal CI.
    if directory := os.getenv("BUILD_WORKSPACE_DIRECTORY"):
        os.chdir(directory)

    path = Path(__file__).parent / "kernels.mojopkg"

    dtype = DType.float32
    N = 8
    D = 8
    BD = 4
    BN = 4
    with Graph(
        "fused_attention",
        input_types=[
            TensorType(dtype, shape=[N, D]),
            TensorType(dtype, shape=[N, D]),
            TensorType(dtype, shape=[N, D]),
        ],
    ) as graph:
        q, k, v, *_ = graph.inputs
        results = ops.custom(
            name="fused_attention_custom",
            parameters={"N": N, "D": D, "BD": BD, "BN": BN},
            values=[q, k, v],
            out_types=[TensorType(dtype, shape=[N, D])],
        )
        graph.output(*results)

    # Place the graph on a GPU, if available. Fall back to CPU if not.
    device = CPU() if accelerator_count() == 0 else Accelerator()

    # Set up an inference session for running the graph.
    session = InferenceSession(devices=[device], custom_extensions=path)

    # Compile the graph.
    model = session.load(graph)

    np.random.seed(123)
    Q = Tensor.from_numpy(np.random.randn(N, D).astype("f")).to(device)
    K = Tensor.from_numpy(np.random.randn(N, D).astype("f")).to(device)
    V = Tensor.from_numpy(np.random.randn(N, D).astype("f")).to(device)

    output = model.execute(Q, K, V)
    print(output)


if __name__ == "__main__":
    main()
