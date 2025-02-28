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
from collections.string import StringSlice
from sys.ffi import c_char, external_call

from memory import UnsafePointer

from .pwd import Passwd

alias uid_t = Int32
alias gid_t = Int32
alias time_t = Int
alias char = UnsafePointer[c_char]


@register_passable("trivial")
struct _C_Passwd:
    var pw_name: char
    var pw_passwd: char
    var pw_uid: uid_t
    var pw_gid: gid_t
    var pw_change: time_t  # Always 0
    var pw_class: char  # Always empty
    var pw_gecos: char
    var pw_dir: char
    var pw_shell: char
    var pw_expire: time_t  # Always 0


fn _build_pw_struct(passwd_ptr: UnsafePointer[_C_Passwd]) raises -> Passwd:
    var c_pwuid = passwd_ptr[]
    var passwd = Passwd(
        pw_name=String(
            StringSlice[__origin_of(c_pwuid)](
                unsafe_from_utf8_cstr_ptr=c_pwuid.pw_name
            )
        ),
        pw_passwd=String(
            StringSlice[__origin_of(c_pwuid)](
                unsafe_from_utf8_cstr_ptr=c_pwuid.pw_passwd
            )
        ),
        pw_uid=Int(c_pwuid.pw_uid),
        pw_gid=Int(c_pwuid.pw_gid),
        pw_gecos=String(
            StringSlice[__origin_of(c_pwuid)](
                unsafe_from_utf8_cstr_ptr=c_pwuid.pw_gecos
            )
        ),
        pw_dir=String(
            StringSlice[__origin_of(c_pwuid)](
                unsafe_from_utf8_cstr_ptr=c_pwuid.pw_dir
            )
        ),
        pw_shell=String(
            StringSlice[__origin_of(c_pwuid)](
                unsafe_from_utf8_cstr_ptr=c_pwuid.pw_shell
            )
        ),
    )
    return passwd


fn _getpw_macos(uid: UInt32) raises -> Passwd:
    var passwd_ptr = external_call["getpwuid", UnsafePointer[_C_Passwd]](uid)
    if not passwd_ptr:
        raise Error("user ID not found in the password database: ", uid)
    return _build_pw_struct(passwd_ptr)


fn _getpw_macos(name: String) raises -> Passwd:
    var passwd_ptr = external_call["getpwnam", UnsafePointer[_C_Passwd]](name)
    if not passwd_ptr:
        raise Error("user name not found in the password database: ", name)
    return _build_pw_struct(passwd_ptr)
