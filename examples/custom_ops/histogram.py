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
from max.engine import InferenceSession
from max.graph import Graph, TensorType, ops

if __name__ == "__main__":
    # This is necessary only in specific build environments.
    if directory := os.getenv("BUILD_WORKSPACE_DIRECTORY"):
        os.chdir(directory)

    path = Path(__file__).parent / "kernels.mojopkg"

    n = 2**20

    # Configure our simple one-operation graph.
    graph = Graph(
        "histogram",
        # The custom Mojo operation is referenced by its string name, and we
        # need to provide inputs as a list as well as expected output types.
        forward=lambda x: ops.custom(
            name="histogram",
            values=[x],
            out_types=[TensorType(dtype=DType.int64, shape=[256])],
        )[0].tensor,
        input_types=[
            TensorType(DType.uint8, shape=[n]),
        ],
    )

    # Place the graph on a GPU, if available. Fall back to CPU if not.
    device = CPU() if accelerator_count() == 0 else Accelerator()

    # Set up an inference session for running the graph.
    session = InferenceSession(devices=[device], custom_extensions=path)

    # Compile the graph.
    model = session.load(graph)

    # Fill an input with random values.
    x_values = np.random.randint(0, 256, size=n, dtype=np.uint8)

    # Create a driver tensor from this, and move it to the accelerator.
    x = Tensor.from_numpy(x_values).to(device)

    # Perform the calculation on the target device.
    model_result = model.execute(x)[0]

    # Copy values back to the CPU to be read.
    assert isinstance(model_result, Tensor)

    print("Graph result:")
    result = model_result.to_numpy()
    print(result)
    print()

    print("Expected result:")
    expected = np.histogram(x_values, bins=256, range=(0, 256))[0]
    print(expected)

    assert all(result == expected), "Result does not match expected"
