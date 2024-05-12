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
# RUN: %mojo -debug-level full %s


from testing import assert_equal, assert_false, assert_raises, assert_true

from time import time

from datetime.datetime import DateTime as dt
from datetime.calendar import Calendar, PythonCalendar, UTCCalendar
from datetime.timezone import TimeZone
from datetime.dt_str import IsoFormat

alias TZ = TimeZone[iana=None, pyzoneinfo=False, native=False]
alias DateTime = dt[iana=None, pyzoneinfo=False, native=False]


fn test_add(
    pycal: Calendar, unixcal: Calendar, tz1_: TZ, tz_0_: TZ, tz_1: TZ
) raises:
    # test february leapyear
    var result = DateTime(2024, 3, 1, tz=tz_0_, calendar=pycal) + DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    var offset_0 = DateTime(2024, 2, 29, tz=tz_0_, calendar=unixcal)
    var offset_p_1 = DateTime(2024, 2, 29, tz=tz_1, calendar=unixcal)
    var offset_n_1 = DateTime(2024, 3, 1, tz=tz1_, calendar=unixcal)
    var add_seconds = DateTime(2024, 3, 1, tz=tz_0_, calendar=unixcal).add(
        seconds=24 * 3600
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == add_seconds)

    # test february not leapyear
    result = DateTime(2023, 3, 1, tz=tz_0_, calendar=pycal) + DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2023, 2, 28, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2023, 2, 28, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2023, 3, 1, tz=tz1_, calendar=unixcal)
    add_seconds = DateTime(2023, 3, 1, tz=tz_0_, calendar=unixcal).add(
        seconds=24 * 3600
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == add_seconds)

    # test normal month
    result = DateTime(2024, 5, 31, tz=tz_0_, calendar=pycal) + DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2024, 6, 1, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2024, 6, 1, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2024, 5, 31, tz=tz1_, calendar=unixcal)
    add_seconds = DateTime(2024, 5, 31, tz=tz_0_, calendar=unixcal).add(
        seconds=24 * 3600
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == add_seconds)

    # test december
    result = DateTime(2024, 12, 31, tz=tz_0_, calendar=pycal) + DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2025, 1, 1, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2025, 1, 1, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2024, 12, 31, tz=tz1_, calendar=unixcal)
    add_seconds = DateTime(2024, 12, 31, tz=tz_0_, calendar=unixcal).add(
        seconds=24 * 3600
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == add_seconds)

    # test year and month add
    result = DateTime(2022, 6, 1, tz=tz_0_, calendar=pycal) + DateTime(
        3, 6, 31, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2025, 1, 1, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2025, 1, 1, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2024, 12, 31, tz=tz1_, calendar=unixcal)
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1)

    # test positive overflow pycal
    result = DateTime(9999, 12, 31, tz=tz_0_, calendar=pycal) + DateTime(
        0, 0, 1, tz=tz_0_, calendar=pycal
    )
    offset_0 = DateTime(1, 1, 1, tz=tz_0_, calendar=pycal)
    offset_p_1 = DateTime(1, 1, 1, tz=tz_1, calendar=pycal)
    offset_n_1 = DateTime(1, 1, 1, tz=tz1_, calendar=pycal)
    add_seconds = DateTime(9999, 12, 31, tz=tz_0_, calendar=pycal).add(
        seconds=24 * 3600
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == add_seconds)

    # test positive overflow unixcal
    result = DateTime(9999, 12, 31, tz=tz_0_, calendar=unixcal) + DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(1970, 1, 1, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(1970, 1, 1, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(1970, 1, 1, tz=tz1_, calendar=unixcal)
    add_seconds = DateTime(9999, 12, 31, tz=tz_0_, calendar=unixcal).add(
        seconds=24 * 3600
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == add_seconds)


fn test_subtract(
    pycal: Calendar, unixcal: Calendar, tz1_: TZ, tz_0_: TZ, tz_1: TZ
) raises:
    # test february leapyear
    var result = DateTime(2024, 3, 1, tz=tz_0_, calendar=pycal) - DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    var offset_0 = DateTime(2024, 2, 29, tz=tz_0_, calendar=unixcal)
    var offset_p_1 = DateTime(2024, 2, 29, tz=tz_1, calendar=unixcal)
    var offset_n_1 = DateTime(2024, 3, 1, tz=tz1_, calendar=unixcal)
    var sub_seconds = DateTime(2024, 3, 1, tz=tz_0_, calendar=unixcal).subtract(
        seconds=1
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == sub_seconds)

    # test february not leapyear
    result = DateTime(2023, 3, 1, tz=tz_0_, calendar=pycal) - DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2023, 2, 28, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2023, 2, 28, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2023, 3, 1, tz=tz1_, calendar=unixcal)
    sub_seconds = DateTime(2023, 3, 1, tz=tz_0_, calendar=unixcal).subtract(
        seconds=1
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == sub_seconds)

    # test normal month
    result = DateTime(2024, 6, 1, tz=tz_0_, calendar=pycal) - DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2024, 5, 31, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2024, 5, 31, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2024, 6, 1, tz=tz1_, calendar=unixcal)
    sub_seconds = DateTime(2024, 6, 1, tz=tz_0_, calendar=unixcal).subtract(
        seconds=1
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == sub_seconds)

    # test december
    result = DateTime(2025, 1, 1, tz=tz_0_, calendar=pycal) - DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2024, 12, 31, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2024, 12, 31, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2025, 1, 1, tz=tz1_, calendar=unixcal)
    sub_seconds = DateTime(2025, 1, 1, tz=tz_0_, calendar=unixcal).subtract(
        seconds=1
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == sub_seconds)

    # test year and month subtract
    result = DateTime(2025, 1, 1, tz=tz_0_, calendar=pycal) - DateTime(
        3, 6, 31, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(2022, 6, 1, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(2022, 6, 1, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(2022, 5, 31, tz=tz1_, calendar=unixcal)
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1)

    # test negative overflow pycal
    result = DateTime(1, 1, 1, tz=tz_0_, calendar=pycal) - DateTime(
        0, 0, 1, tz=tz_0_, calendar=pycal
    )
    offset_0 = DateTime(9999, 12, 31, tz=tz_0_, calendar=pycal)
    offset_p_1 = DateTime(9999, 12, 31, tz=tz_1, calendar=pycal)
    offset_n_1 = DateTime(9999, 12, 31, tz=tz1_, calendar=pycal)
    sub_seconds = DateTime(1, 1, 1, tz=tz_0_, calendar=pycal).subtract(
        seconds=1
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == sub_seconds)

    # test negative overflow unixcal
    result = DateTime(1970, 1, 1, tz=tz_0_, calendar=unixcal) - DateTime(
        0, 0, 1, tz=tz_0_, calendar=unixcal
    )
    offset_0 = DateTime(9999, 12, 31, tz=tz_0_, calendar=unixcal)
    offset_p_1 = DateTime(9999, 12, 31, tz=tz_1, calendar=unixcal)
    offset_n_1 = DateTime(9999, 12, 31, tz=tz1_, calendar=unixcal)
    sub_seconds = DateTime(1970, 1, 1, tz=tz_0_, calendar=unixcal).subtract(
        seconds=1
    )
    assert_true(result == offset_0 and result == offset_p_1)
    assert_true(result == offset_n_1 and result == sub_seconds)


fn test_logic(
    pycal: Calendar, unixcal: Calendar, tz1_: TZ, tz_0_: TZ, tz_1: TZ
) raises:
    var ref = DateTime(1970, 1, 1, tz=tz_0_, calendar=pycal)
    assert_true(ref == DateTime(1970, 1, 1, tz=tz_0_, calendar=unixcal))
    assert_true(ref == DateTime(1970, 1, 1, tz=tz_1, calendar=unixcal))
    assert_true(ref == DateTime(1969, 12, 31, tz=tz1_, calendar=pycal))

    assert_true(ref < DateTime(1970, 1, 2, tz=tz_0_, calendar=pycal))
    assert_true(ref <= DateTime(1970, 1, 2, tz=tz_0_, calendar=pycal))
    assert_true(ref > DateTime(1969, 12, 31, tz=tz_0_, calendar=pycal))
    assert_true(ref >= DateTime(1969, 12, 31, tz=tz_0_, calendar=pycal))


fn test_bitwise(
    pycal: Calendar, unixcal: Calendar, tz1_: TZ, tz_0_: TZ, tz_1: TZ
) raises:
    var ref = DateTime(1970, 1, 1, tz=tz_0_, calendar=pycal)
    assert_true(ref & DateTime(1970, 1, 1, tz=tz_0_, calendar=unixcal) == 0)
    assert_true(ref & DateTime(1970, 1, 1, tz=tz_1, calendar=unixcal) == 0)
    assert_true(ref & DateTime(1969, 12, 31, tz=tz1_, calendar=pycal) == 0)

    assert_true(ref ^ DateTime(1970, 1, 2, tz=tz_0_, calendar=pycal) != 0)
    assert_true(
        ref | (DateTime(1970, 1, 2, tz=tz_0_, calendar=pycal) & 0) == hash(ref)
    )
    assert_true(ref & ~ref == 0)
    assert_true(ref ^ ~ref == UInt64.MAX_FINITE)


fn test_iso(pycal: Calendar, tz_0_: TZ) raises:
    var ref = DateTime(1970, 1, 1, tz=tz_0_, calendar=pycal)
    var iso_str = "1970-01-01T00:00:00+00:00"
    alias fmt1 = IsoFormat(IsoFormat.YYYY_MM_DD_T_HH_MM_SS_TZD)
    assert_true(ref == DateTime.from_iso[fmt1](iso_str).unsafe_take())
    assert_equal(iso_str, ref.to_iso[fmt1]())

    iso_str = "1970-01-01 00:00:00+00:00"
    alias fmt2 = IsoFormat(IsoFormat.YYYY_MM_DD___HH_MM_SS)
    assert_true(ref == DateTime.from_iso[fmt2](iso_str).unsafe_take())
    assert_equal(iso_str, ref.to_iso[fmt2]())

    iso_str = "1970-01-01T00:00:00"
    alias fmt3 = IsoFormat(IsoFormat.YYYY_MM_DD_T_HH_MM_SS)
    assert_true(ref == DateTime.from_iso[fmt3](iso_str).unsafe_take())
    assert_equal(iso_str, ref.to_iso[fmt3]())

    iso_str = "19700101000000"
    alias fmt4 = IsoFormat(IsoFormat.YYYYMMDDHHMMSS)
    assert_true(ref == DateTime.from_iso[fmt4](iso_str).unsafe_take())
    assert_equal(iso_str, ref.to_iso[fmt4]())

    iso_str = "00:00:00"
    alias fmt5 = IsoFormat(IsoFormat.HH_MM_SS)
    assert_true(ref == DateTime.from_iso[fmt5](iso_str).unsafe_take())
    assert_equal(iso_str, ref.to_iso[fmt5]())

    iso_str = "000000"
    alias fmt6 = IsoFormat(IsoFormat.HHMMSS)
    assert_true(ref == DateTime.from_iso[fmt6](iso_str).unsafe_take())
    assert_equal(iso_str, ref.to_iso[fmt6]())


fn test_time() raises:
    var start = DateTime.now()
    time.sleep(1e-9)  # nanosecond resolution
    var end = DateTime.now()
    assert_true(start != end)


fn test_hash() raises:
    var ref = DateTime(1970, 1, 1)
    var data = hash(ref)
    var parsed = DateTime.from_hash(data)
    assert_true(ref == parsed)


fn main() raises:
    var tz_0_ = TZ("", 0, 0)
    var tz_1 = TZ("", 1, 0)
    var tz1_ = TZ("", 1, 0, 1)
    # when using python and unix calendar there
    # should be no difference in results
    var pycal = PythonCalendar
    var unixcal = UTCCalendar
    test_add(pycal, unixcal, tz1_, tz_0_, tz_1)
    test_subtract(pycal, unixcal, tz1_, tz_0_, tz_1)
    test_logic(pycal, unixcal, tz1_, tz_0_, tz_1)
    test_bitwise(pycal, unixcal, tz1_, tz_0_, tz_1)
    test_iso(pycal, tz_0_)
    test_time()
    test_hash()
