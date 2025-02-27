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

"""PagedAttention-specific metadata for a single sequence."""

from __future__ import annotations

import numpy as np


def ceildiv(n: int, d: int) -> int:
    """Compute ceil(n/d) using strictly integer arithmetic."""
    q, r = divmod(n, d)
    return q + bool(r)


class PagedCacheMetadata:
    """Metadata for a single sequence in the paged KV cache.

    Token array layout:

    - Committed tokens have been inserted into the prefix cache. This must be a
      multiple of the page size.
    - Cached tokens are tokens that have a backing KV projection in the cache.
      Uncached tokens will be written to the cache when the model is run.
    - Committable tokens are tokens that are not yet committed but have a known
      value (i.e. not inflight). We can query the prefix cache for such tokens.
    - Inflight tokens are slots allocated for tokens that have not been generated
      yet. Such tokens have a filler value of 0. After `fetch`, there should be
      `num_steps - 1` inflight tokens. They will be replaced with actual tokens
      in `step`.

                  committed_idx V                              seq_len V
       +----------------------------------------------------------------+
       | committed              | uncommitted                           |
       |----------------------------------------------------------------|
       |                        | committable            |              |
       |----------------------------------------------------------------|
       | cached                      | uncached                         |
       |----------------------------------------------------------------|
       |                             | prompt            | inflight     |
       +----------------------------------------------------------------+
                          cached_idx ^      inflight_idx ^
    """

    def __init__(self, page_size: int, max_seq_len: int) -> None:
        self.page_size = page_size
        self.committed_idx: int = 0
        self.cached_idx: int = 0
        self.inflight_idx: int = 0
        self.seq_len: int = 0
        self.blocks: list[int] = []
        self.tokens: np.ndarray = np.full((max_seq_len,), 0, dtype=np.int64)

    @property
    def committed_blocks(self) -> list[int]:
        return self.blocks[: self.committed_idx // self.page_size]

    @property
    def uncommitted_blocks(self) -> list[int]:
        return self.blocks[self.committed_idx // self.page_size : self.seq_len]

    @property
    def committed_tokens(self) -> np.ndarray:
        return self.tokens[: self.committed_idx]

    @property
    def uncached_tokens(self) -> np.ndarray:
        return self.tokens[self.cached_idx : self.seq_len]

    @property
    def prompt_tokens(self) -> np.ndarray:
        return self.tokens[self.cached_idx : self.inflight_idx]

    @property
    def inflight_tokens(self) -> np.ndarray:
        return self.tokens[self.inflight_idx : self.seq_len]

    @property
    def committable_tokens_aligned(self) -> np.ndarray:
        # Return all tokens that are committable and part of a block that only
        # contains committable tokens.
        inflight_idx = self.inflight_idx
        partial_tokens = inflight_idx % self.page_size
        if partial_tokens > 0:
            inflight_idx -= partial_tokens
        return self.tokens[self.committed_idx : inflight_idx]

    @property
    def committable_blocks_aligned(self) -> list[int]:
        # Returns all blocks that only contain committable tokens.
        return self.blocks[
            self.committed_idx // self.page_size : self.inflight_idx
            // self.page_size
        ]

    @property
    def committable_tokens(self) -> np.ndarray:
        # Returns all tokens that are committable.
        return self.tokens[self.committed_idx : self.inflight_idx]

    @property
    def committable_blocks(self) -> list[int]:
        # Returns any block that contains at least one committable token.
        return self.blocks[
            self.committed_idx // self.page_size : ceildiv(
                self.inflight_idx, self.page_size
            )
        ]

    def _validate_indices(self):
        assert (
            0
            <= self.committed_idx
            <= self.cached_idx
            <= self.inflight_idx
            <= self.seq_len
        ), "The indices must be in the correct order"
        assert self.seq_len <= len(self.tokens), (
            "Sequence has exceeded the max sequence length"
        )
        assert self.committed_idx % self.page_size == 0, (
            "The committed_idx must be a multiple of the page size since we "
            "can't commit a partial page into the prefix cache"
        )

    def fetch(self, prompt: np.ndarray, num_steps: int) -> None:
        """Add prompt to token array and reserve space for inflight tokens."""
        self._validate_indices()
        assert len(self.prompt_tokens) == 0, (
            "At the start of fetch, there should be no prompt tokens"
        )
        assert len(self.inflight_tokens) == 0, (
            "At the start of fetch, there should be no inflight tokens"
        )
        assert len(prompt) > 0, (
            "The prompt provided to fetch should be non-empty"
        )
        num_inflight_tokens = num_steps - 1
        self.inflight_idx += len(prompt)
        self.seq_len += len(prompt) + num_inflight_tokens
        self.tokens[self.cached_idx : self.inflight_idx] = prompt
        self._validate_indices()

    def step(self, new_tokens: np.ndarray) -> None:
        """Write new tokens into inflight token slots. Also update the cached_idx."""
        self._validate_indices()
        assert len(self.prompt_tokens) > 0, (
            "We could not have executed the model without at least one prompt token"
        )
        num_inflight_tokens = len(new_tokens) - 1
        assert len(self.inflight_tokens) == num_inflight_tokens, (
            "The existing slots for inflight tokens should correspond to all but the last newly generated token"
        )
        self.tokens[self.inflight_idx : self.seq_len] = new_tokens[:-1]
        self.cached_idx = self.seq_len
        self.inflight_idx = self.seq_len
        assert len(self.uncached_tokens) == 0, (
            "After step, all tokens should have a backing KV projection in the cache"
        )
        self._validate_indices()
