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
# RUN: %bare-mojo -D ASSERT=warn %s | FileCheck %s

from collections._index_normalization import normalize_index

from testing import assert_equal


@no_inline
def _test[branchless: Bool]():
    alias t = "TestContainer"
    container = List[Int](1, 1, 1, 1)
    # test no clamp
    alias no_clamp = normalize_index[
        t, clamp_to_container_length=False, branchless=branchless
    ]
    assert_equal(no_clamp(-4, container), 0)
    assert_equal(no_clamp(-3, container), 1)
    assert_equal(no_clamp(-2, container), 2)
    assert_equal(no_clamp(-1, container), 3)
    assert_equal(no_clamp(0, container), 0)
    assert_equal(no_clamp(1, container), 1)
    assert_equal(no_clamp(2, container), 2)
    assert_equal(no_clamp(3, container), 3)
    # test clamp to container length
    alias clamp = normalize_index[
        t, clamp_to_container_length=True, branchless=branchless
    ]
    assert_equal(clamp(-4, container), 0)
    assert_equal(clamp(-3, container), 1)
    assert_equal(clamp(-2, container), 2)
    assert_equal(clamp(-1, container), 3)
    assert_equal(clamp(0, container), 0)
    assert_equal(clamp(1, container), 1)
    assert_equal(clamp(2, container), 2)
    assert_equal(clamp(3, container), 3)
    alias ign_zero_clamp = normalize_index[
        t,
        ignore_zero_length=True,
        clamp_to_container_length=True,
        branchless=branchless,
    ]
    assert_equal(ign_zero_clamp(-8, container), 0)
    assert_equal(ign_zero_clamp(-7, container), 0)
    assert_equal(ign_zero_clamp(-6, container), 0)
    assert_equal(ign_zero_clamp(-5, container), 0)
    assert_equal(ign_zero_clamp(4, container), 0)
    assert_equal(ign_zero_clamp(5, container), 0)
    assert_equal(ign_zero_clamp(6, container), 0)
    assert_equal(ign_zero_clamp(7, container), 0)
    # test container with zero length no clamp
    alias ign_zero_no_clamp = normalize_index[
        t,
        ignore_zero_length=True,
        clamp_to_container_length=False,
        branchless=branchless,
    ]
    assert_equal(ign_zero_no_clamp(-8, container), 0)
    assert_equal(ign_zero_no_clamp(-7, container), 0)
    assert_equal(ign_zero_no_clamp(-6, container), 0)
    assert_equal(ign_zero_no_clamp(-5, container), 0)
    assert_equal(ign_zero_no_clamp(-4, container), 0)
    assert_equal(ign_zero_no_clamp(-3, container), 0)
    assert_equal(ign_zero_no_clamp(-2, container), 0)
    assert_equal(ign_zero_no_clamp(-1, container), 0)
    assert_equal(ign_zero_no_clamp(0, container), 0)
    assert_equal(ign_zero_no_clamp(1, container), 0)
    assert_equal(ign_zero_no_clamp(2, container), 0)
    assert_equal(ign_zero_no_clamp(3, container), 0)
    assert_equal(ign_zero_no_clamp(4, container), 0)
    assert_equal(ign_zero_no_clamp(5, container), 0)
    assert_equal(ign_zero_no_clamp(6, container), 0)
    assert_equal(ign_zero_no_clamp(7, container), 0)


def test_normalize_index_branchless():
    _test[True]()
    alias t = "TestContainer"
    container = List[Int](1, 1, 1, 1)
    alias no_clamp = normalize_index[
        t, clamp_to_container_length=False, branchless=True
    ]
    alias clamp = normalize_index[
        t, clamp_to_container_length=True, branchless=True
    ]
    # test clamp to container length overflow
    # CHECK: TestContainer has length: 4. Index out of bounds: -8 should be between -4 and 3
    assert_equal(clamp(-8, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: -7 should be between -4 and 3
    assert_equal(clamp(-7, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: -6 should be between -4 and 3
    assert_equal(clamp(-6, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: -5 should be between -4 and 3
    assert_equal(clamp(-5, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: 4 should be between -4 and 3
    assert_equal(clamp(4, container), 3)
    # CHECK: TestContainer has length: 4. Index out of bounds: 5 should be between -4 and 3
    assert_equal(clamp(5, container), 3)
    # CHECK: TestContainer has length: 4. Index out of bounds: 6 should be between -4 and 3
    assert_equal(clamp(6, container), 3)
    # CHECK: TestContainer has length: 4. Index out of bounds: 7 should be between -4 and 3
    assert_equal(clamp(7, container), 3)
    # test container with zero length
    container = List[Int]()
    # CHECK: Indexing into a TestContainer that has 0 elements
    _ = clamp(-8, container)
    # CHECK: Indexing into a TestContainer that has 0 elements
    _ = no_clamp(-8, container)


def test_normalize_index_branchy():
    _test[False]()
    alias t = "TestContainer"
    container = List[Int](1, 1, 1, 1)
    alias no_clamp = normalize_index[
        t, clamp_to_container_length=False, branchless=False
    ]
    alias clamp = normalize_index[
        t, clamp_to_container_length=True, branchless=False
    ]
    # test clamp to container length overflow
    # CHECK: TestContainer has length: 4. Index out of bounds: -8 should be between -4 and 3
    assert_equal(clamp(-8, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: -7 should be between -4 and 3
    assert_equal(clamp(-7, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: -6 should be between -4 and 3
    assert_equal(clamp(-6, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: -5 should be between -4 and 3
    assert_equal(clamp(-5, container), 0)
    # CHECK: TestContainer has length: 4. Index out of bounds: 4 should be between -4 and 3
    assert_equal(clamp(4, container), 3)
    # CHECK: TestContainer has length: 4. Index out of bounds: 5 should be between -4 and 3
    assert_equal(clamp(5, container), 3)
    # CHECK: TestContainer has length: 4. Index out of bounds: 6 should be between -4 and 3
    assert_equal(clamp(6, container), 3)
    # CHECK: TestContainer has length: 4. Index out of bounds: 7 should be between -4 and 3
    assert_equal(clamp(7, container), 3)
    # test container with zero length
    container = List[Int]()
    # CHECK: Indexing into a TestContainer that has 0 elements
    _ = clamp(-8, container)
    # CHECK: Indexing into a TestContainer that has 0 elements
    _ = no_clamp(-8, container)


def main():
    test_normalize_index_branchless()
    test_normalize_index_branchy()
