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
"""An opaque KV Cache optimized attention mechanism with Rope."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable, List, Optional, Union

from max.dtype import DType
from max.graph import (
    BufferValue,
    DeviceRef,
    TensorValue,
    Weight,
    ops,
)
from max.graph.quantization import QuantizationConfig, QuantizationEncoding
from max.pipelines.kv_cache import (
    ContinuousBatchingKVCacheCollection,
    KVCacheParams,
    PagedKVCacheCollection,
)

from ..clamp import clamp
from ..kernels import (
    MHAMaskVariant,
    flash_attention_ragged,
    fused_qk_ragged_rope,
    fused_qkv_ragged_matmul,
    fused_qkv_ragged_matmul_quantized,
)
from ..layer import LayerV2
from ..linear import LinearV2
from ..rotary_embedding import OptimizedRotaryEmbedding
from .interfaces import (
    AttentionImpl,
    AttentionImplQKV,
    AttentionImplV2,
    DistributedAttentionImpl,
)


@dataclass
class AttentionWithRope(AttentionImpl):
    # This class will not use the RotaryEmbedding to
    # calculate rope, but it already includes a freqs_cis
    # calculation, which we will borrow

    rope: OptimizedRotaryEmbedding
    bias: Optional[TensorValue] = None
    perm_idx: Optional[TensorValue] = None
    quantization_config: Optional[QuantizationConfig] = None

    def __call__(
        self,
        x: TensorValue,
        kv_collection: Union[
            ContinuousBatchingKVCacheCollection, PagedKVCacheCollection
        ],
        **kwargs,
    ) -> TensorValue:
        # Get attributes from input.
        total_seq_len = x.shape[0]

        # Call into fused qkv ragged matmul.
        if self.quantization_config:
            xq = fused_qkv_ragged_matmul_quantized(
                self.kv_params,
                input=x,
                wqkv=self.wqkv,
                input_row_offsets=kwargs["input_row_offsets"],
                kv_collection=kv_collection,
                layer_idx=self.layer_idx,
                n_heads=self.n_heads,
                bias=self.bias,
                perm_idx=self.perm_idx,
                quantization_config=self.quantization_config,
            )
        else:
            xq = fused_qkv_ragged_matmul(
                self.kv_params,
                input=x,
                wqkv=self.wqkv,
                input_row_offsets=kwargs["input_row_offsets"],
                kv_collection=kv_collection,
                layer_idx=self.layer_idx,
                n_heads=self.n_heads,
                bias=self.bias,
            )

        # Apply rope.
        xq = xq.reshape((-1, self.n_heads, self.kv_params.head_dim))

        if xq.device is not None:
            freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype).to(xq.device)
        else:
            freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype)

        xq = fused_qk_ragged_rope(
            self.kv_params,
            xq,
            kwargs["input_row_offsets"],
            kv_collection,
            freqs_cis,
            self.layer_idx,
            interleaved=self.rope.interleaved,
        )

        # Calculate Flash Attention.
        attn_out = flash_attention_ragged(
            self.kv_params,
            input=xq,
            kv_collection=kv_collection,
            layer_idx=self.layer_idx,
            input_row_offsets=kwargs["input_row_offsets"],
            mask_variant=MHAMaskVariant.CAUSAL_MASK,
            scale=self.scale,
        )

        attn_out = ops.reshape(attn_out, shape=[total_seq_len, -1])

        return self.wo(attn_out)


class AttentionWithRopeV2(AttentionImplV2):
    """Implementation of attention that uses the rope frequency.

    `AttentionWithRopeV2` will replace `AttentionWithRope` as we roll out
    the new Layer API.
    """

    # This class will not use the RotaryEmbedding to
    # calculate rope, but it already includes a freqs_cis
    # calculation, which we will borrow
    rope: OptimizedRotaryEmbedding

    def __init__(
        self,
        *,
        rope: OptimizedRotaryEmbedding,
        num_attention_heads: int,
        num_key_value_heads: int,
        hidden_size: int,
        kv_params: KVCacheParams,
        layer_idx: int,
        dtype: DType = DType.float32,
        device: DeviceRef = DeviceRef.CPU(),
        linear_cls: Callable[..., LinearV2] = LinearV2,
        stacked_qkv: bool = False,
        scale: float | None = None,
        has_bias: bool = False,
        clip_qkv: float | None = None,
    ):
        """Initializes the attention layer.

        Args:
            rope: The rope layer to borrow the freq_cis value from.
            num_attention_heads: The number of attention heads.
            num_key_value_heads: Number of key/value heads.
            hidden_size: The dimension of the hidden states.
            kv_params: KV Cache Params, including the number of kv heads, the head dim, and data type.
            layer_idx: The layer number associated with this Attention block.
            dtype: DType of the
            device: Device to place the weights and run the computation.
            linear_cls: Linear class to use for the outputs dense layer.
            stacked_qkv: Whether the weights are stacked together.
            scale: Value used to scale the results of the attention output.
            has_bias: Whether to use an attention bias.
            clip_qkv: If provided, the QKV weights are clamped between
                `[-clip_qkv, clip_qkv]`
        """

        super().__init__()
        self.rope = rope
        self.n_heads = num_attention_heads
        self.layer_idx = layer_idx
        self.kv_params = kv_params
        self.has_bias = has_bias
        self.scale = (
            scale if scale else math.sqrt(1.0 / self.kv_params.head_dim)
        )
        self.clip_qkv = clip_qkv

        if stacked_qkv and clip_qkv:
            raise ValueError(
                "`clip_qkv` not yet supported when `stack_qkv=True`."
            )

        if not self.kv_params.cache_strategy.uses_opaque():
            raise ValueError(
                f"{self.kv_params.cache_strategy} cache strategy, not supported"
                " in Attention layer."
            )

        kv_weight_dim = (
            hidden_size // num_attention_heads
        ) * num_key_value_heads

        self.stacked_qkv = stacked_qkv

        if stacked_qkv:
            # To keep the weight names consistent with the transformers attention,
            # the names are suffixed ".weight".
            self.qkv_proj = Weight(
                name="qkv_proj.weight",
                dtype=dtype,
                shape=[hidden_size + 2 * kv_weight_dim, hidden_size],
            )
        else:
            self.q_proj = Weight(
                name="q_proj.weight",
                dtype=dtype,
                shape=[hidden_size, hidden_size],
            )
            self.k_proj = Weight(
                name="k_proj.weight",
                dtype=dtype,
                shape=[kv_weight_dim, hidden_size],
            )
            self.v_proj = Weight(
                name="v_proj.weight",
                dtype=dtype,
                shape=[kv_weight_dim, hidden_size],
            )

        if has_bias:
            assert not stacked_qkv, "Bias is not supported with stacked qkv."

            self.bias_q = Weight(
                name="q_proj.bias", dtype=dtype, shape=[hidden_size]
            )
            self.bias_k = Weight(
                name="k_proj.bias", dtype=dtype, shape=[kv_weight_dim]
            )
            self.bias_v = Weight(
                name="v_proj.bias", dtype=dtype, shape=[kv_weight_dim]
            )

        self.o_proj = linear_cls(
            in_dim=hidden_size, out_dim=hidden_size, dtype=dtype, device=device
        )

    @property
    def wqkv(self) -> TensorValue:
        """The concatenation of q, k, and v weight vectors."""
        if self.stacked_qkv:
            return self.qkv_proj
        else:
            wq: TensorValue = self.q_proj
            wk: TensorValue = self.k_proj
            wv: TensorValue = self.v_proj
            if self.clip_qkv:
                wq = clamp(wq, min=-self.clip_qkv, max=self.clip_qkv)
                wk = clamp(wk, min=-self.clip_qkv, max=self.clip_qkv)
                wv = clamp(wv, min=-self.clip_qkv, max=self.clip_qkv)
            return ops.concat((wq, wk, wv))

    @property
    def wqkv_bias(self) -> TensorValue | None:
        """The concatenation of q, k, and v bias weight vectors."""
        if not self.has_bias:
            return None

        return ops.concat((self.bias_q, self.bias_k, self.bias_v))

    def __call__(
        self,
        x: TensorValue,
        kv_collection: Union[
            ContinuousBatchingKVCacheCollection, PagedKVCacheCollection
        ],
        **kwargs,
    ) -> TensorValue:
        # Get attributes from input.
        total_seq_len = x.shape[0]

        layer_idx = ops.constant(self.layer_idx, DType.uint32)
        # Call into fused qkv ragged matmul.
        xq = fused_qkv_ragged_matmul(
            self.kv_params,
            input=x,
            wqkv=self.wqkv,
            bias=self.wqkv_bias,
            input_row_offsets=kwargs["input_row_offsets"],
            kv_collection=kv_collection,
            layer_idx=layer_idx,
            n_heads=self.n_heads,
        )

        # Apply rope.
        xq = xq.reshape((-1, self.n_heads, self.kv_params.head_dim))

        if xq.device is not None:
            freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype).to(xq.device)
        else:
            freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype)

        xq = fused_qk_ragged_rope(
            self.kv_params,
            xq,
            kwargs["input_row_offsets"],
            kv_collection,
            freqs_cis,
            layer_idx,
            interleaved=self.rope.interleaved,
        )

        # Calculate Flash Attention.
        attn_out = flash_attention_ragged(
            self.kv_params,
            input=xq,
            kv_collection=kv_collection,
            layer_idx=layer_idx,
            input_row_offsets=kwargs["input_row_offsets"],
            mask_variant=MHAMaskVariant.CAUSAL_MASK,
            scale=self.scale,
        )

        attn_out = ops.reshape(attn_out, shape=[total_seq_len, -1])

        return self.o_proj(attn_out)


class GPTQAttentionWithRope(AttentionWithRopeV2):
    """Implementation of the GPT-Q attention layer."""

    def __init__(
        self,
        quantization_config: QuantizationConfig,
        rope: OptimizedRotaryEmbedding,
        num_attention_heads: int,
        num_key_value_heads: int,
        hidden_size: int,
        kv_params: KVCacheParams,
        layer_idx: int,
        dtype: DType = DType.float32,
        device: DeviceRef | None = None,
        scale: float | None = None,
        linear_cls: Callable[..., LinearV2] = LinearV2,
    ):
        # Skip AttentionWithRopeV2.__init__ because the weights are created
        # differently.
        LayerV2.__init__(self)
        self.quantization_config = quantization_config
        self.rope = rope
        self.n_heads = num_attention_heads
        self.layer_idx = layer_idx
        self.kv_params = kv_params
        self.hidden_size = hidden_size
        self.device = device
        self.scale = (
            scale if scale else math.sqrt(1.0 / self.kv_params.head_dim)
        )
        if not self.kv_params.cache_strategy.uses_opaque():
            raise ValueError(
                f"{self.kv_params.cache_strategy} cache strategy, not supported"
                " in Attention layer."
            )

        self.kv_weight_dim = (
            hidden_size // num_attention_heads
        ) * num_key_value_heads

        self.q_proj_qweight = Weight(
            name="q_proj.qweight",
            dtype=DType.uint8,
            shape=(1, 1),  # Shape will be overridden at load_state_dict.
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )
        self.k_proj_qweight = Weight(
            name="k_proj.qweight",
            dtype=DType.uint8,
            shape=(1, 1),  # Shape will be overridden at load_state_dict.
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )
        self.v_proj_qweight = Weight(
            name="v_proj.qweight",
            dtype=DType.uint8,
            shape=(1, 1),  # Shape will be overridden at load_state_dict.
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )

        self.q_proj_scales = Weight(
            name="q_proj.scales",
            dtype=DType.uint8,
            shape=(1, 1),  # Shape will be overridden at load_state_dict.
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )
        self.k_proj_scales = Weight(
            name="k_proj.scales",
            dtype=DType.uint8,
            shape=(1, 1),  # Shape will be overridden at load_state_dict.
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )
        self.v_proj_scales = Weight(
            name="v_proj.scales",
            dtype=DType.uint8,
            shape=(1, 1),  # Shape will be overridden at load_state_dict.
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )
        self.o_proj = linear_cls(
            in_dim=hidden_size,
            out_dim=hidden_size,
            dtype=dtype,
            # device=device,
            quantization_encoding=QuantizationEncoding.GPTQ,
        )

        self.perm_idx = None
        if quantization_config.desc_act:
            self.perm_idx = Weight(
                name="q_proj.perm_idx",
                dtype=DType.int32,
                shape=[hidden_size],
                # device=device,
            )

    @property
    def wqkv(self) -> TensorValue:
        """The concatenation of q, k, and v weight vectors."""

        # fmt: off
        # the `qweight` tensor for a QuantLinear is of type uint32. When allocated as bytes, we reshape the
        # uint8 tensor to [cols, rows * 4] so concatenating the uint8 tensors along axis=1 is equivalent to
        # concatenating the original uint32 tensors along axis=1.
        wq_qweight = ops.reshape(self.q_proj_qweight, (-1, self.hidden_size * 4))
        wk_qweight = ops.reshape(self.k_proj_qweight, (-1, self.kv_weight_dim * 4))
        wv_qweight = ops.reshape(self.v_proj_qweight, (-1, self.kv_weight_dim * 4))

        wqkv_qweight = ops.reshape(
            ops.concat((wq_qweight, wk_qweight, wv_qweight), axis=1),
            (-1, self.hidden_size + 2 * self.kv_weight_dim),
        )
        # `scales` tensor is in f16/bf16 type, so we reshape the uint8 tensor to [cols, rows * 2].
        wq_scales = ops.reshape(self.q_proj_scales, (-1, self.hidden_size * 2))
        wk_scales = ops.reshape(self.k_proj_scales, (-1, self.kv_weight_dim * 2))
        wv_scales = ops.reshape(self.v_proj_scales, (-1, self.kv_weight_dim * 2))

        wqkv_scales = ops.reshape(
            ops.concat((wq_scales, wk_scales, wv_scales), axis=1),
            (-1, self.hidden_size + 2 * self.kv_weight_dim),
        )
        # fmt: on
        return ops.concat((wqkv_qweight, wqkv_scales), axis=0)

    def __call__(
        self,
        x: TensorValue,
        kv_collection: Union[
            ContinuousBatchingKVCacheCollection, PagedKVCacheCollection
        ],
        **kwargs,
    ) -> TensorValue:
        layer_idx = ops.constant(self.layer_idx, DType.uint32)

        # Get attributes from input.
        total_seq_len = x.shape[0]

        wqkv = self.wqkv
        if self.device:
            wqkv = wqkv.to(self.device)

        # Call into fused qkv ragged matmul.
        xq = fused_qkv_ragged_matmul_quantized(
            self.kv_params,
            input=x,
            wqkv=wqkv,
            input_row_offsets=kwargs["input_row_offsets"],
            kv_collection=kv_collection,
            layer_idx=layer_idx,
            n_heads=self.n_heads,
            perm_idx=self.perm_idx,
            quantization_config=self.quantization_config,
        )

        # Apply rope.
        xq = xq.reshape((-1, self.n_heads, self.kv_params.head_dim))

        if xq.device is not None:
            freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype).to(xq.device)
        else:
            freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype)

        xq = fused_qk_ragged_rope(
            self.kv_params,
            xq,
            kwargs["input_row_offsets"],
            kv_collection,
            freqs_cis,
            layer_idx,
            interleaved=self.rope.interleaved,
        )

        # Calculate Flash Attention.
        attn_out = flash_attention_ragged(
            self.kv_params,
            input=xq,
            kv_collection=kv_collection,
            layer_idx=layer_idx,
            input_row_offsets=kwargs["input_row_offsets"],
            mask_variant=MHAMaskVariant.CAUSAL_MASK,
            scale=self.scale,
        )
        attn_out = ops.reshape(attn_out, shape=[total_seq_len, -1])

        return self.o_proj(attn_out)


def distribute_value(
    v: TensorValue, devices: List[DeviceRef]
) -> List[TensorValue]:
    return [v.to(device) for device in devices]


@dataclass
class DistributedAttentionWithRope(DistributedAttentionImpl):
    list_of_attentions: List[AttentionWithRope]
    devices: list[DeviceRef]

    def __call__(
        self,
        x: List[TensorValue],
        signal_buffers: List[BufferValue],
        kv_collections: List[
            ContinuousBatchingKVCacheCollection | PagedKVCacheCollection
        ],
        **kwargs,
    ) -> List[TensorValue]:
        input_row_offsets = kwargs["input_row_offsets"]
        assert isinstance(input_row_offsets, TensorValue)
        input_row_offsets_ = distribute_value(input_row_offsets, self.devices)

        return list(
            ops.allreduce.sum(
                inputs=[
                    self.list_of_attentions[i](
                        x[i],
                        kv_collections[i],
                        input_row_offsets=input_row_offsets_[i],
                    )
                    for i in range(len(self.devices))
                ],
                signal_buffers=signal_buffers,
            )
        )


@dataclass
class AttentionWithRopeQKV(AttentionImplQKV):
    # This class will not use the RotaryEmbedding to
    # calculate rope, but it already includes a freqs_cis
    # calculation, which we will borrow
    rope: OptimizedRotaryEmbedding

    def __call__(
        self,
        x: TensorValue,
        kv_collection: Union[
            ContinuousBatchingKVCacheCollection, PagedKVCacheCollection
        ],
        **kwargs,
    ) -> TensorValue:
        # Get attributes from input.
        total_seq_len = x.shape[0]

        wqkv = ops.concat((self.wq, self.wk, self.wv))

        # Call into fused qkv ragged matmul.
        xq = fused_qkv_ragged_matmul(
            self.kv_params,
            input=x,
            wqkv=wqkv,
            input_row_offsets=kwargs["input_row_offsets"],
            kv_collection=kv_collection,
            layer_idx=ops.constant(self.layer_idx, DType.uint32),
            n_heads=self.n_heads,
        )

        # Apply rope.
        xq = xq.reshape((-1, self.n_heads, self.kv_params.head_dim))

        # Cast freqs_cis to xq's dtype to match the fused_qk_ragged_rope kernel.
        freqs_cis = ops.cast(self.rope.freqs_cis, xq.dtype)

        xq = fused_qk_ragged_rope(
            self.kv_params,
            xq,
            kwargs["input_row_offsets"],
            kv_collection,
            freqs_cis,
            ops.constant(self.layer_idx, DType.uint32),
            interleaved=self.rope.interleaved,
        )

        # Calculate Flash Attention.
        attn_out = flash_attention_ragged(
            self.kv_params,
            input=xq,
            kv_collection=kv_collection,
            layer_idx=ops.constant(self.layer_idx, DType.uint32),
            input_row_offsets=kwargs["input_row_offsets"],
            mask_variant=MHAMaskVariant.CAUSAL_MASK,
            scale=self.scale,
        )

        attn_out = ops.reshape(attn_out, shape=[total_seq_len, -1])

        return self.wo(attn_out)
