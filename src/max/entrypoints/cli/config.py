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


"""Utilities for working with Config objects in Click."""

from __future__ import annotations

import functools
import inspect
import pathlib
from dataclasses import MISSING, Field, fields
from enum import Enum
from pathlib import Path
from typing import Any, Union, get_args, get_origin, get_type_hints

import click
from max.driver import DeviceSpec
from max.pipelines import PipelineConfig

from .device_options import DevicesOptionType

VALID_CONFIG_TYPES = [str, bool, Enum, Path, DeviceSpec, int, float]


def get_interior_type(type_hint: Union[type, str, Any]) -> type[Any]:
    interior_args = set(get_args(type_hint)) - set([type(None)])
    if len(interior_args) > 1:
        msg = (
            "Parsing does not currently supported Union type, with more than"
            " one non-None type: {type_hint}"
        )
        raise ValueError(msg)

    return get_args(type_hint)[0]


def is_optional(type_hint: Union[type, str, Any]) -> bool:
    return get_origin(type_hint) is Union and type(None) in get_args(type_hint)


def is_flag(field_type: Any) -> bool:
    return field_type is bool


def validate_field_type(field_type: Any) -> bool:
    if is_optional(field_type):
        test_type = get_args(field_type)[0]
    elif get_origin(field_type) is list:
        test_type = get_interior_type(field_type)
    else:
        test_type = field_type

    for valid_type in VALID_CONFIG_TYPES:
        if valid_type == test_type:
            return True

        if get_origin(valid_type) is None and inspect.isclass(test_type):
            if issubclass(test_type, valid_type):
                return True
    msg = f"type '{test_type}' not supported in config."
    raise ValueError(msg)


def get_field_type(field_type: Any):
    validate_field_type(field_type)

    # Get underlying core field type, is Optional or list.
    if is_optional(field_type):
        field_type = get_interior_type(field_type)
    elif get_origin(field_type) is list:
        field_type = get_interior_type(field_type)

    # Update the field_type to be format specific.
    if field_type == Path:
        field_type = click.Path(path_type=pathlib.Path)
    elif inspect.isclass(field_type):
        if issubclass(field_type, Enum):
            field_type = click.Choice(list(field_type))

    return field_type


def get_default(dataclass_field: Field) -> Any:
    if dataclass_field.default_factory != MISSING:
        default = dataclass_field.default_factory()
    elif dataclass_field.default != MISSING:
        default = dataclass_field.default
    else:
        default = None

    return default


def is_multiple(field_type: Any) -> bool:
    return get_origin(field_type) is list


def create_click_option(
    help_for_fields: dict[str, str],
    dataclass_field: Field,
    field_type: Any,
) -> click.option:  # type: ignore
    # Get name.
    normalized_name = dataclass_field.name.lower().replace("_", "-")

    # Get Help text.
    help_text = help_for_fields.get(dataclass_field.name, None)

    # Get help field.
    return click.option(
        f"--{normalized_name}",
        show_default=True,
        help=help_text,
        is_flag=is_flag(field_type),
        default=get_default(dataclass_field),
        multiple=is_multiple(field_type),
        type=get_field_type(field_type),
    )


def config_to_flag(cls):
    options = []
    if hasattr(cls, "help"):
        help_text = cls.help()
    else:
        help_text = {}
    field_types = get_type_hints(cls)
    for _field in fields(cls):
        # Skip private config fields.
        # We also skip device_specs as it should not be used directly via the CLI entrypoint.
        if _field.name.startswith("_") or _field.name == "device_specs":
            continue

        new_option = create_click_option(
            help_text, _field, field_types[_field.name]
        )
        options.append(new_option)

    def apply_flags(func):
        for option in reversed(options):
            func = option(func)  # type: ignore
        return func

    return apply_flags


def pipeline_config_options(func):
    @config_to_flag(PipelineConfig)
    @click.option(
        "--devices",
        is_flag=False,
        type=DevicesOptionType(),
        show_default=False,
        default="",
        flag_value="0",
        help=(
            "Whether to run the model on CPU (--devices=cpu), GPU (--devices=gpu)"
            " or a list of GPUs (--devices=gpu:0,1) etc. An ID value can be"
            " provided optionally to indicate the device ID to target. If not"
            " provided, the model will run on the first available GPU (--devices=gpu),"
            " or CPU if no GPUs are available (--devices=cpu)."
        ),
    )
    # Kept for backwards compatibility.
    @click.option(
        "--use-gpu",
        is_flag=False,
        type=DevicesOptionType(),
        show_default=False,
        default="",
        flag_value="0",
        help=(
            "Whether to run the model on the available GPU. An ID value can be"
            " provided optionally to indicate the device ID to target."
        ),
    )
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        # Remove the options from kwargs and replace with unified device_specs.
        devices: str | list[int] = kwargs.pop("devices")
        legacy_use_gpu = kwargs.pop("use_gpu", None)

        # Apply legacy flag if no modern devices specified.
        if not devices and legacy_use_gpu:
            devices = legacy_use_gpu

        kwargs["device_specs"] = DevicesOptionType.device_specs(devices)

        return func(*args, **kwargs)

    return wrapper
