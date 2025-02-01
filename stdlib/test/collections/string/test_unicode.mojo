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
# RUN: %mojo %s

from collections import InlineArray
from collections.string._unicode import _get_uppercase_mapping

from testing import assert_equal


def test_uppercase_conversion():
    # a -> A
    count1, chars1 = _get_uppercase_mapping(Char(97)).value()
    assert_equal(count1, 1)
    assert_equal(chars1[0], Char(65))
    assert_equal(chars1[1], Char(0))
    assert_equal(chars1[2], Char(0))

    # ß -> SS
    count2, chars2 = _get_uppercase_mapping(Char.from_u32(0xDF).value()).value()
    assert_equal(count2, 2)
    assert_equal(chars2[0], Char.from_u32(0x53).value())
    assert_equal(chars2[1], Char.from_u32(0x53).value())
    assert_equal(chars2[2], Char(0))

    # ΐ -> Ϊ́
    count3, chars3 = _get_uppercase_mapping(
        Char.from_u32(0x390).value()
    ).value()
    assert_equal(count3, 3)
    assert_equal(chars3[0], Char.from_u32(0x0399).value())
    assert_equal(chars3[1], Char.from_u32(0x0308).value())
    assert_equal(chars3[2], Char.from_u32(0x0301).value())


def main():
    test_uppercase_conversion()
