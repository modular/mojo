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
from max.driver import CPU, Accelerator, Device, Tensor, accelerator_count
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import Graph, TensorType, ops
from numpy.typing import NDArray


def matrix_multiplication(
    a: NDArray[np.float32],
    b: NDArray[np.float32],
    algorithm: str,
    session: InferenceSession,
    device: Device,
) -> Tensor:
    dtype = DType.float32

    # Create driver tensors from the input arrays, and move them to the
    # accelerator.
    a_tensor = Tensor.from_numpy(a).to(device)
    b_tensor = Tensor.from_numpy(b).to(device)

    # Configure our simple one-operation graph.
    with Graph(
        "matrix_multiplication_graph",
        input_types=[
            TensorType(dtype, shape=a_tensor.shape),
            TensorType(dtype, shape=b_tensor.shape),
        ],
    ) as graph:
        # Take in the two inputs to the graph.
        a_value, b_value = graph.inputs
        # The matrix multiplication custom operation takes in two matrices and
        # produces a result, with the specific algorithm that is used chosen
        # via compile-time parameterization.
        output = ops.custom(
            name="matrix_multiplication",
            values=[a_value, b_value],
            out_types=[
                TensorType(
                    dtype=a_value.tensor.dtype,
                    shape=[a_value.tensor.shape[0], b_value.tensor.shape[1]],
                )
            ],
            parameters={"algorithm": algorithm},
        )[0].tensor
        graph.output(output)

    # Compile the graph.
    print("Compiling...")
    model = session.load(graph)

    # Perform the calculation on the target device.
    print("Executing...")
    result = model.execute(a_tensor, b_tensor)[0]

    # Copy values back to the CPU to be read.
    assert isinstance(result, Tensor)
    return result.to(CPU())


if __name__ == "__main__":
    # This is necessary only in specific build environments.
    if directory := os.getenv("BUILD_WORKSPACE_DIRECTORY"):
        os.chdir(directory)

    path = Path(__file__).parent / "kernels.mojopkg"

    M = 256
    K = 256
    N = 256

    # Place the graph on a GPU, if available. Fall back to CPU if not.
    device = CPU() if accelerator_count() == 0 else Accelerator()

    # Set up an inference session for running the graph.
    session = InferenceSession(
        devices=[device],
        custom_extensions=path,
    )

    # Fill the input matrices with random values.
    a = np.random.uniform(size=(M, K)).astype(np.float32)
    b = np.random.uniform(size=(K, N)).astype(np.float32)

    # First, perform the matrix multiplication in NumPy.
    print("A:")
    print(a)
    print()

    print("B:")
    print(b)
    print()

    print("Expected result:")
    print(a @ b)
    print()

    if accelerator_count() > 0:
        # Then, test the various versions of matrix multiplication operations.
        naive_result = matrix_multiplication(a, b, "naive", session, device)
        print("Naive matrix multiplication:")
        print(naive_result.to_numpy())
        print()

        coalescing_result = matrix_multiplication(
            a, b, "coalescing", session, device
        )
        print("Coalescing matrix multiplication:")
        print(coalescing_result.to_numpy())
        print()

        tiled_result = matrix_multiplication(a, b, "tiled", session, device)
        print("Tiled matrix multiplication:")
        print(tiled_result.to_numpy())
        print()

        tiled_register_result = matrix_multiplication(
            a, b, "tiled_register", session, device
        )
        print("Shared memory and register tiling matrix multiplication:")
        print(tiled_register_result.to_numpy())
        print()

        block_tiled_result = matrix_multiplication(
            a, b, "block_tiled", session, device
        )
        print("2D block tiled matrix multiplication:")
        print(block_tiled_result.to_numpy())
        print()

        block_tiled_vectorized_result = matrix_multiplication(
            a, b, "block_tiled_vectorized", session, device
        )
        print("2D block tiled matrix multiplication (vectorized):")
        print(block_tiled_vectorized_result.to_numpy())
        print()

        tensor_core_result = matrix_multiplication(
            a, b, "tensor_core", session, device
        )
        print("Matrix multiplication using Tensor Cores:")
        print(tensor_core_result.to_numpy())
        print()
    else:
        print(
            "No MAX-compatible accelerator detected, only running a naive matrix multiplication:"
        )

        naive_result = matrix_multiplication(a, b, "naive", session, device)
        print("Naive matrix multiplication:")
        print(naive_result.to_numpy())
        print()
