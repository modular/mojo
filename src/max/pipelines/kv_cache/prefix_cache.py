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

"""Prefix cache to enable reuse of KV projections during context encoding with PagedAttention."""

from __future__ import annotations

from typing import Callable, Optional

import numpy as np
from max.driver import Device, Tensor
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import BufferType, DeviceRef, Graph, TensorType, ops

from .paged_cache_metadata import PagedCacheMetadata
from .radix_trie import RadixTrie, TrieNode


def construct_cow_strided_memcpy_graph(
    block_shape: list[int | str], dtype: DType, devices: list[Device]
) -> Graph:
    """
    Returns a graph for performing COW operations on the KV cache.
    """
    assert len(block_shape) == 6
    ds = [DeviceRef(device.label, device.id) for device in devices]
    blocks_ty = [BufferType(dtype, shape=block_shape, device=d) for d in ds]
    block_src_idx_ty = TensorType(DType.uint32, shape=[])
    block_dst_idx_ty = TensorType(DType.uint32, shape=[])
    num_tokens_ty = TensorType(DType.uint32, shape=[])

    with Graph(
        "mo.kv_collection_cow_strided_memcpy.paged",
        input_types=[
            block_dst_idx_ty,
            block_src_idx_ty,
            num_tokens_ty,
            *blocks_ty,
        ],
        output_types=[],
    ) as graph:
        block_dst_idx, block_src_idx, num_tokens, *all_blocks = graph.inputs
        for blocks in all_blocks:
            ops.inplace_custom(
                "mo.kv_collection_cow_strided_memcpy.paged",
                values=[blocks, block_dst_idx, block_src_idx, num_tokens],
                out_types=[],
            )
        graph.output()

    return graph


class PrefixCache:
    def __init__(
        self,
        session: InferenceSession,
        page_size: int,
        block_shape: list[int | str],
        dtype: DType,
        devices: list[Device],
        tensors: list[Tensor],
        enable_cow: bool = True,
    ):
        self.page_size = page_size
        self.enable_cow = enable_cow
        self.radix_trie = RadixTrie(page_size=self.page_size)
        self.tensors = tensors

        self.cow_count = 0
        if self.enable_cow and self.page_size > 1:
            # Load single op graph for performing memory transfers needed for COW
            self.cow_strided_memcpy_graph = session.load(
                construct_cow_strided_memcpy_graph(
                    block_shape,
                    dtype,
                    devices,
                ),
            )
        self.all_tokens = 0
        self.cache_hit_tokens = 0

        # This is a pointer into the radix trie indicating the prefix of the sequence
        # that has been committed into the radix trie.
        self.active_requests: dict[int, TrieNode] = {}

    def __contains__(self, block: int) -> bool:
        """Check if a block is owned by the prefix cache."""
        return block in self.radix_trie.get_all_blocks()

    def external_claim(self, seq_id: int) -> None:
        """Claim a sequence for use by the prefix cache.

        This initializes the cursor in the trie for the given sequence at the
        root, indicating that no blocks are committed for this sequence yet.
        """
        assert seq_id not in self.active_requests
        self.active_requests[seq_id] = self.radix_trie.root

    def release(self, seq_id: int) -> None:
        """Release a sequence from the prefix cache.

        This decrements the ref count of committed blocks used by the sequence.
        """
        assert seq_id in self.active_requests
        node = self.active_requests[seq_id]
        self.radix_trie.mark_not_in_use_by(node, seq_id)
        del self.active_requests[seq_id]

    @property
    def blocks(self) -> set[int]:
        """Returns all blocks owned by the prefix cache."""
        return self.radix_trie.get_all_blocks()

    @property
    def stale_blocks(self) -> set[int]:
        """Returns all blocks that are evictable/stale.

        Stale blocks are those that are not in use by any sequence (refcount == 0)
        """
        return self.radix_trie.get_evictable_blocks()

    @property
    def cache_hit_rate(self) -> float:
        """Returns the prefix cache hit rate."""
        if self.all_tokens == 0:
            return 0.0
        assert self.cache_hit_tokens <= self.all_tokens
        return self.cache_hit_tokens / self.all_tokens

    def validate_req_state_valid(
        self,
        seq_id: int,
        committed_tokens: np.ndarray,
        committed_blocks: list[int],
    ):
        """Check that the committed tokens and blocks match what was actually
        committed into the radix trie."""
        assert seq_id in self.active_requests
        node = self.active_requests[seq_id]
        # Climb up the trie from the given node, accumulating all the
        # prefix tokens and blocks.
        tokens, blocks = node.get_prefix_tokens_and_blocks()
        assert (tokens == committed_tokens).all()
        assert blocks == committed_blocks

    def get_cached_blocks(self, seq_id: int, prompt: np.ndarray) -> list[int]:
        """Returns the blocks from the prefix cache that can be reused for the given prompt."""
        node = self.active_requests.get(seq_id, self.radix_trie.root)
        # Attempt to match all but the last token in the prompt. This is
        # because the model expects a prompt of length at least 1.
        _, cached_blocks = self.radix_trie.match_prefix(prompt[:-1], node=node)
        return cached_blocks

    def get_num_cached_tokens(self, prompt: np.ndarray) -> int:
        """Returns the number of tokens in the CE prompt that are found in the prefix cache."""
        _, prefix_blocks = self.radix_trie.match_prefix(prompt[:-1])
        return len(prefix_blocks) * self.page_size

    def evict_blocks(self, blocks_to_evict: Optional[int] = None) -> list[int]:
        """Evict a percentage of all blocks according to a LRU policy on the trie leaves."""
        if blocks_to_evict is None:
            blocks_to_evict = len(self.blocks)
        return self.radix_trie.evict_blocks(desired_num_evicted=blocks_to_evict)

    def _release_partial_block(
        self,
        data: PagedCacheMetadata,
        free_block_fn: Callable[[int], None],
    ) -> None:
        """Release the partially cached and uncommitted block.

        There may be a partially cached block if the seq len was not a multiple
        of page size after the last `step` operation. We may want to release the
        partial block if we can retrieve KV projections for additional tokens
        in the block from the cache:

        e.g:
            - partial_block b0 = ["I", "love", "to", "dance"] (cached = 2 tokens)
            - we have block b1 = ["I", "love", "to", "sing"] (cached = 4 tokens)
              in the prefix cache
            - we can delete b0 and reuse b1 for the first three tokens for COW
        """
        assert data.committed_idx < data.cached_idx
        partial_blocks = data.committable_blocks
        assert len(partial_blocks) == 1
        free_block_fn(partial_blocks[0])
        data.blocks.pop()
        partial_tokens = data.cached_idx - data.committed_idx
        assert 0 < partial_tokens < self.page_size
        data.cached_idx -= partial_tokens
        assert data.committed_idx == data.cached_idx

    def fetch(
        self,
        seq_id: int,
        data: PagedCacheMetadata,
        free_block_fn: Callable[[int], None],
        alloc_block_fn: Callable[[], int],
    ) -> list[int]:
        """Extend the kv cache for given request with any cached prefixes.

        This will increment the committed_idx and cached_idx if there is a cache
        hit. The prompt will be trimmed in the event that cached_idx is bumped.
        """
        # If there is only one committable token, that means that the prompt
        # is one token. We cannot reduce the prompt length any further since
        # the model expects a prompt of length at least 1.
        committable_tokens = data.committable_tokens[:-1]
        if len(committable_tokens) == 0:
            return []

        # Query trie for all but last token.
        node = self.active_requests[seq_id]
        node, prefix_blocks = self.radix_trie.match_prefix(
            committable_tokens, node=node
        )
        self.active_requests[seq_id] = node

        # Mark the prefix blocks we retrieved from the radix trie cache as
        # in use by this sequence so they don't get evicted prematurely.
        self.radix_trie.mark_in_use_by(node, seq_id)

        # Update the cache hit rate metrics.
        num_cache_hit_tokens = len(prefix_blocks) * self.page_size
        self.cache_hit_tokens += num_cache_hit_tokens
        self.all_tokens += len(committable_tokens)

        # If there is a block with partially cached tokens, we should release it
        # if the cache hit blocks already contain these tokens and more
        if data.committed_idx < data.cached_idx and num_cache_hit_tokens > 0:
            assert data.committed_idx + num_cache_hit_tokens > data.cached_idx
            self._release_partial_block(data, free_block_fn)

        data.blocks.extend(prefix_blocks)
        # Bump the committed_idx since we got cache hits
        data.committed_idx += num_cache_hit_tokens
        data.cached_idx += num_cache_hit_tokens

        if self.enable_cow:
            self._fetch_cow(seq_id, data, free_block_fn, alloc_block_fn)

        return prefix_blocks

    def _fetch_cow(
        self,
        seq_id: int,
        data: PagedCacheMetadata,
        free_block_fn: Callable[[int], None],
        alloc_block_fn: Callable[[], int],
    ) -> None:
        """Extend the kv cache for given request with any cached prefixes by
        copying a portion of the tokens in a committed block to a fresh block.

        This will keep the committed_idx the same, but increment the cached_idx
        by between [1, page_size) tokens if we do perform a cow operation. The
        prompt will be trimmed in the event that cached_idx is bumped.
        """
        assert self.enable_cow

        # If page_size is 1, there is no need to perform COW
        if self.page_size == 1:
            return
        assert self.cow_strided_memcpy_graph is not None

        # Match page_size tokens in the radix trie
        committable_tokens = data.committable_tokens[:-1]
        if len(committable_tokens) == 0:
            return
        committable_tokens_cropped = list(committable_tokens[: self.page_size])
        node = self.active_requests[seq_id]
        res = node.find_block_with_largest_common_prefix(
            committable_tokens_cropped
        )
        if res is None:
            return
        partial_match_block, num_cache_hit_tokens = res
        assert 0 < num_cache_hit_tokens < self.page_size

        # No point in performing COW if we have more cached but uncommitted tokens
        # in the existing partial block than the matched prefix length.
        partial_tokens = data.cached_idx - data.committed_idx
        if num_cache_hit_tokens <= partial_tokens:
            return

        # If we have a partially cached block, we need to release it before
        # appending additional blocks.
        if partial_tokens > 0:
            assert data.committed_idx + num_cache_hit_tokens > data.cached_idx
            self._release_partial_block(data, free_block_fn)

        # Copy prefix_len tokens from partial_match_block to new_block.
        new_block = alloc_block_fn()
        self.cow_count += 1
        self.cow_strided_memcpy_graph.execute(
            new_block,
            partial_match_block,
            num_cache_hit_tokens,
            *self.tensors,
        )
        data.blocks.append(new_block)
        data.cached_idx += num_cache_hit_tokens
        assert len(data.prompt_tokens) > 0
        assert data.cached_idx < data.inflight_idx

    def step(
        self,
        seq_id: int,
        data: PagedCacheMetadata,
        free_block_fn: Callable[[int], None],
    ) -> None:
        """Now that we have written to the inflight blocks, we will try to commit
        them to the radix trie.

        This increments the committed_idx. We guarantee that the number of committed
        tokens will be a multiple of the page size. There may be some uncommitted
        tokens left over due to there being a partial page at the end. Thus the
        number of uncommitted tokens will always be less than the page size.
        """
        committable_tokens = data.committable_tokens_aligned
        node = self.active_requests[seq_id]
        node, existing_blocks = self.radix_trie.match_prefix(
            committable_tokens, node=node
        )
        self.active_requests[seq_id] = node

        # If we computed a kv entry for a token that was already cached,
        # we will just release that block we just computed.
        for b0, b1 in zip(existing_blocks, data.committable_blocks_aligned):
            if b0 != b1:
                free_block_fn(b1)

        # Replace the inflight blocks with the existing prefix blocks.
        committed_block_idx = data.committed_idx // self.page_size
        data.blocks[
            committed_block_idx : committed_block_idx + len(existing_blocks)
        ] = existing_blocks
        data.committed_idx += len(existing_blocks) * self.page_size

        committable_tokens = data.committable_tokens_aligned
        committable_blocks = data.committable_blocks_aligned
        assert len(committable_tokens) % self.page_size == 0
        assert (
            len(committable_tokens) == len(committable_blocks) * self.page_size
        )

        # If there are any tokens to commit, insert them into the prefix cache.
        node = self.radix_trie.insert(
            committable_tokens,
            committable_blocks,
            node=node,
        )
        self.active_requests[seq_id] = node
        data.committed_idx += len(committable_tokens)

        # Mark the recently committed blocks as in use by this sequence
        # so they don't get evicted prematurely.
        self.radix_trie.mark_in_use_by(node, seq_id)
