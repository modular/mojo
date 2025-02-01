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
"""Implements the utils package."""

from .index import Index, IndexList, product
from collections.string.inline_string import InlineString
from .lock import BlockingScopedLock, BlockingSpinLock, SpinWaiter
from .loop import unroll
from .static_tuple import StaticTuple
from collections.string.string_slice import StaticString, StringSlice
from .stringref import StringRef
from .variant import Variant
from .write import Writable, Writer, write_args, write_buffered
