//! `datetime.fromisoformat`, as CPython 3.14's C implementation reads it.
//!
//! Note, catalog and ticket timestamps are validated with
//! `datetime.fromisoformat(value.replace("Z", "+00:00"))`, which accepts far
//! more than RFC 3339: basic and week dates, any single separator character,
//! `24:00`, comma fractions and offsets with seconds. This follows
//! `Modules/_datetimemodule.c` at python/cpython@5607950ef232dad16d75c0cf53101d9649d89115
//! (v3.14.5), which works on the UTF-8 bytes and reads a NUL past the end;
//! `at` stands in for that terminator.

use crate::{Error, ErrorKind, Result};

/// A parsed datetime; `offset_us` is the UTC offset when the text has one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DateTime {
    pub year: i32,
    pub month: i32,
    pub day: i32,
    pub hour: i32,
    pub minute: i32,
    pub second: i32,
    pub microsecond: i32,
    pub offset_us: Option<i64>,
}

const MICROS_PER_DAY: i64 = 86_400_000_000;

impl DateTime {
    /// The instant in microseconds since 0001-01-01T00:00:00Z, as
    /// `value.astimezone(timezone.utc)` would compare it. `None` for a naive
    /// value. An instant outside years 1 to 9999 is Python's `OverflowError`.
    pub fn utc_micros(&self) -> Option<Result<i64>> {
        let offset = self.offset_us?;
        let local = (i64::from(ordinal(self.year, self.month, self.day)) - 1) * MICROS_PER_DAY
            + i64::from(self.hour) * 3_600_000_000
            + i64::from(self.minute) * 60_000_000
            + i64::from(self.second) * 1_000_000
            + i64::from(self.microsecond);
        let utc = local - offset;
        let last = i64::from(ordinal(9999, 12, 31)) * MICROS_PER_DAY;
        Some(if (0..last).contains(&utc) {
            Ok(utc)
        } else {
            Err(Error::new(ErrorKind::Overflow, "date value out of range"))
        })
    }
}

fn invalid(text: &str) -> Error {
    Error::value(format!(
        "Invalid isoformat string: {}",
        crate::pystr::repr(text)
    ))
}

/// `datetime.fromisoformat(text)`.
pub fn fromisoformat(text: &str) -> Result<DateTime> {
    if text.chars().count() < 7 {
        return Err(invalid(text));
    }
    let bytes = text.as_bytes();
    let length = bytes.len();
    let separator = find_separator(bytes).ok_or_else(|| invalid(text))?;
    let (year, month, day) = parse_date(bytes, separator).map_err(|_| invalid(text))?;
    let mut time = Time::default();
    let mut zone = 0;
    if length > separator {
        let lead = bytes[separator];
        let start = separator
            + if lead & 0x80 == 0 {
                1
            } else {
                match lead & 0xf0 {
                    0xe0 => 3,
                    0xf0 => 4,
                    _ => 2,
                }
            };
        zone = parse_time(bytes, start, length.saturating_sub(start), &mut time);
        if zone < 0 {
            return Err(invalid(text));
        }
    }
    let offset_us = if zone == 1 {
        if time.zone_seconds == 0 {
            Some(0)
        } else {
            let offset =
                i64::from(time.zone_seconds) * 1_000_000 + i64::from(time.zone_microseconds);
            if offset.abs() >= MICROS_PER_DAY {
                return Err(Error::value(format!(
                    "offset must be a timedelta strictly between -timedelta(hours=24) and \
                     timedelta(hours=24), not {}",
                    timedelta_repr(offset)
                )));
            }
            Some(offset)
        }
    } else {
        None
    };
    let (mut year, mut month, mut day, mut hour) = (year, month, day, time.hour);
    if hour == 24 && month <= 12 {
        let month_days = days_in_month(year, month);
        if day <= month_days {
            if time.minute != 0 || time.second != 0 || time.microsecond != 0 {
                return Err(Error::value(
                    "minute, second, and microsecond must be 0 when hour is 24",
                ));
            }
            hour = 0;
            day += 1;
            if day > month_days {
                day = 1;
                month += 1;
                if month > 12 {
                    month = 1;
                    year += 1;
                }
            }
        }
    }
    // check_date_args and check_time_args.
    if !(1..=9999).contains(&year) {
        return Err(Error::value(format!("year must be in 1..9999, not {year}")));
    }
    if !(1..=12).contains(&month) {
        return Err(Error::value(format!("month must be in 1..12, not {month}")));
    }
    let days = days_in_month(year, month);
    if day < 1 || day > days {
        return Err(Error::value(format!(
            "day {day} must be in range 1..{days} for month {month} in year {year}"
        )));
    }
    if !(0..=23).contains(&hour) {
        return Err(Error::value(format!("hour must be in 0..23, not {hour}")));
    }
    if !(0..=59).contains(&time.minute) {
        return Err(Error::value(format!(
            "minute must be in 0..59, not {}",
            time.minute
        )));
    }
    if !(0..=59).contains(&time.second) {
        return Err(Error::value(format!(
            "second must be in 0..59, not {}",
            time.second
        )));
    }
    if !(0..=999_999).contains(&time.microsecond) {
        return Err(Error::value(format!(
            "microsecond must be in 0..999999, not {}",
            time.microsecond
        )));
    }
    Ok(DateTime {
        year,
        month,
        day,
        hour,
        minute: time.minute,
        second: time.second,
        microsecond: time.microsecond,
        offset_us,
    })
}

/// The byte C reads at `index`: the text's own, or the NUL terminator.
fn at(bytes: &[u8], index: usize) -> u8 {
    bytes.get(index).copied().unwrap_or(0)
}

fn is_digit(byte: u8) -> bool {
    byte.is_ascii_digit()
}

fn digits(bytes: &[u8], position: &mut usize, count: usize, value: &mut i32) -> bool {
    for _ in 0..count {
        let digit = at(bytes, *position).wrapping_sub(b'0');
        *position += 1;
        if digit > 9 {
            return false;
        }
        *value = *value * 10 + i32::from(digit);
    }
    true
}

/// `_find_isoformat_datetime_separator`; `None` stands for its -1.
fn find_separator(bytes: &[u8]) -> Option<usize> {
    let length = bytes.len();
    if length == 7 {
        return Some(7);
    }
    if at(bytes, 4) == b'-' {
        if at(bytes, 5) == b'W' {
            if length < 8 {
                return None;
            }
            if length > 8 && at(bytes, 8) == b'-' {
                if length == 9 {
                    return None;
                }
                if length > 10 && is_digit(at(bytes, 10)) {
                    return Some(8);
                }
                return Some(10);
            }
            return Some(8);
        }
        return Some(10);
    }
    if at(bytes, 4) == b'W' {
        let mut index = 7;
        while index < length && is_digit(bytes[index]) {
            index += 1;
        }
        if index < 9 {
            return Some(index);
        }
        return Some(if index % 2 == 0 { 7 } else { 8 });
    }
    Some(8)
}

/// `parse_isoformat_date`, with C's negative return codes as `Err`.
fn parse_date(bytes: &[u8], length: usize) -> std::result::Result<(i32, i32, i32), i32> {
    let mut position = 0;
    let mut year = 0;
    if !digits(bytes, &mut position, 4, &mut year) {
        return Err(-1);
    }
    let separated = at(bytes, position) == b'-';
    if separated {
        position += 1;
    }
    if at(bytes, position) == b'W' {
        position += 1;
        let mut week = 0;
        if !digits(bytes, &mut position, 2, &mut week) {
            return Err(-3);
        }
        let mut weekday = 0;
        if position < length {
            if separated {
                let separator = at(bytes, position);
                position += 1;
                if separator != b'-' {
                    return Err(-2);
                }
            }
            if !digits(bytes, &mut position, 1, &mut weekday) {
                return Err(-4);
            }
        } else {
            weekday = 1;
        }
        return iso_to_ymd(year, week, weekday);
    }
    let mut month = 0;
    if !digits(bytes, &mut position, 2, &mut month) {
        return Err(-1);
    }
    if separated {
        let separator = at(bytes, position);
        position += 1;
        if separator != b'-' {
            return Err(-2);
        }
    }
    let mut day = 0;
    if !digits(bytes, &mut position, 2, &mut day) {
        return Err(-1);
    }
    Ok((year, month, day))
}

#[derive(Default)]
struct Time {
    hour: i32,
    minute: i32,
    second: i32,
    microsecond: i32,
    zone_seconds: i32,
    zone_microseconds: i32,
}

/// `parse_hh_mm_ss_ff` over `bytes[start..end]`.
fn parse_clock(bytes: &[u8], start: usize, end: usize, values: &mut [i32; 4]) -> i32 {
    *values = [0; 4];
    let mut position = start;
    let mut separated = true;
    for (index, value) in values.iter_mut().take(3).enumerate() {
        if !digits(bytes, &mut position, 2, value) {
            return -3;
        }
        let character = at(bytes, position);
        position += 1;
        if index == 0 {
            separated = character == b':';
        }
        if position >= end {
            return i32::from(character != 0);
        } else if separated && character == b':' {
            if index == 2 {
                return -4;
            }
            continue;
        } else if character == b'.' || character == b',' {
            if index < 2 {
                return -3;
            }
            break;
        } else if !separated {
            position -= 1;
        } else {
            return -4;
        }
    }
    let remaining = end.saturating_sub(position);
    let count = remaining.min(6);
    if !digits(bytes, &mut position, count, &mut values[3]) {
        return -3;
    }
    if count < 6 {
        // C indexes its correction table with count - 1; count is never 0
        // here, since a decimal mark at the end returns above.
        values[3] *= 10_i32.pow(6 - count as u32);
    }
    while is_digit(at(bytes, position)) {
        position += 1;
    }
    i32::from(at(bytes, position) != 0)
}

/// `parse_isoformat_time`: 0 without an offset, 1 with one, negative on error.
fn parse_time(bytes: &[u8], start: usize, length: usize, time: &mut Time) -> i32 {
    let end = start + length;
    let mut zone = start;
    loop {
        if matches!(at(bytes, zone), b'Z' | b'+' | b'-') {
            break;
        }
        zone += 1;
        if zone >= end {
            break;
        }
    }
    let mut clock = [0; 4];
    let result = parse_clock(bytes, start, zone, &mut clock);
    [time.hour, time.minute, time.second, time.microsecond] = clock;
    if result < 0 {
        return result;
    }
    if zone == end {
        return if result == 1 { -5 } else { 0 };
    }
    if at(bytes, zone) == b'Z' {
        time.zone_seconds = 0;
        time.zone_microseconds = 0;
        return if at(bytes, zone + 1) != 0 { -5 } else { 1 };
    }
    let sign = if at(bytes, zone) == b'-' { -1 } else { 1 };
    let mut offset = [0; 4];
    let result = parse_clock(bytes, zone + 1, end, &mut offset);
    time.zone_seconds = sign * (offset[0] * 3600 + offset[1] * 60 + offset[2]);
    time.zone_microseconds = sign * offset[3];
    if result != 0 { -5 } else { 1 }
}

fn is_leap(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

/// `repr(timedelta(microseconds=micros))`: days, then seconds and
/// microseconds within the day, each shown only when nonzero.
fn timedelta_repr(micros: i64) -> String {
    let days = micros.div_euclid(MICROS_PER_DAY);
    let rest = micros.rem_euclid(MICROS_PER_DAY);
    let mut parts = Vec::new();
    for (name, value) in [
        ("days", days),
        ("seconds", rest / 1_000_000),
        ("microseconds", rest % 1_000_000),
    ] {
        if value != 0 {
            parts.push(format!("{name}={value}"));
        }
    }
    if parts.is_empty() {
        parts.push("0".to_string());
    }
    format!("datetime.timedelta({})", parts.join(", "))
}

fn days_in_month(year: i32, month: i32) -> i32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Proleptic Gregorian ordinal, 0001-01-01 being day 1 (`ymd_to_ord`).
fn ordinal(year: i32, month: i32, day: i32) -> i32 {
    let before_year = {
        let y = year - 1;
        y * 365 + y.div_euclid(4) - y.div_euclid(100) + y.div_euclid(400)
    };
    let before_month: i32 = (1..month).map(|m| days_in_month(year, m)).sum();
    before_year + before_month + day
}

/// `ord_to_ymd`, through the civil-from-days algorithm.
fn from_ordinal(value: i32) -> (i32, i32, i32) {
    // Days since 0000-03-01, the start of a 400-year era.
    let z = i64::from(value) + 305;
    let era = z.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year as i32, month as i32, day as i32)
}

/// `iso_to_ymd`, returning `parse_isoformat_date`'s code on failure.
fn iso_to_ymd(year: i32, week: i32, weekday: i32) -> std::result::Result<(i32, i32, i32), i32> {
    if !(1..=9999).contains(&year) {
        return Err(-7);
    }
    if week <= 0 || week >= 53 {
        let mut out_of_range = true;
        if week == 53 {
            // Monday is 0: a year starting on Thursday, or a leap year
            // starting on Wednesday, has 53 ISO weeks.
            let first_weekday = (ordinal(year, 1, 1) + 6) % 7;
            if first_weekday == 3 || (first_weekday == 2 && is_leap(year)) {
                out_of_range = false;
            }
        }
        if out_of_range {
            return Err(-5);
        }
    }
    if weekday <= 0 || weekday >= 8 {
        return Err(-6);
    }
    let first_day = ordinal(year, 1, 1);
    let first_weekday = (first_day + 6) % 7;
    let mut week1_monday = first_day - first_weekday;
    if first_weekday > 3 {
        week1_monday += 7;
    }
    Ok(from_ordinal(week1_monday + (week - 1) * 7 + weekday - 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    type Fields = (i32, i32, i32, i32, i32, i32, i32, Option<i64>);

    fn parsed(text: &str) -> Option<Fields> {
        fromisoformat(text).ok().map(|value| {
            (
                value.year,
                value.month,
                value.day,
                value.hour,
                value.minute,
                value.second,
                value.microsecond,
                value.offset_us,
            )
        })
    }

    #[test]
    fn reads_what_python_reads() {
        // Expected values from Python 3.14's datetime.fromisoformat.
        assert_eq!(
            parsed("2026-11-14T01:11:25.447357+00:00"),
            Some((2026, 11, 14, 1, 11, 25, 447_357, Some(0)))
        );
        assert_eq!(
            parsed("2026-11-14 01:11"),
            Some((2026, 11, 14, 1, 11, 0, 0, None))
        );
        assert_eq!(
            parsed("20261114T0111-0530"),
            Some((2026, 11, 14, 1, 11, 0, 0, Some(-19_800_000_000)))
        );
        assert_eq!(
            parsed("2026-W01-1T00:00Z"),
            Some((2025, 12, 29, 0, 0, 0, 0, Some(0)))
        );
        assert_eq!(parsed("2026W011"), Some((2025, 12, 29, 0, 0, 0, 0, None)));
        assert_eq!(
            parsed("2026-02-28T24:00+01:00"),
            Some((2026, 3, 1, 0, 0, 0, 0, Some(3_600_000_000)))
        );
        assert_eq!(
            parsed("2026-01-01T12:30:45,5"),
            Some((2026, 1, 1, 12, 30, 45, 500_000, None))
        );
        assert_eq!(
            parsed("2026-01-01T12:30:45.1234567"),
            Some((2026, 1, 1, 12, 30, 45, 123_456, None))
        );
        assert_eq!(
            parsed("2026-01-01é12:30"),
            Some((2026, 1, 1, 12, 30, 0, 0, None))
        );
        assert_eq!(
            parsed("2026-01-01T12:30:45.+00:00:01.5"),
            Some((2026, 1, 1, 12, 30, 45, 0, Some(1_500_000)))
        );
    }

    #[test]
    fn refuses_what_python_refuses() {
        for text in [
            "",
            "2026-1-1",
            "2026-01-01T",
            "2026-01-01T1",
            "2026-01-01T12:30:45.",
            "2026-01-01T12.5",
            "2026-01-01T12:30Z+",
            "2026-02-30",
            "2026-01-01T24:00:01",
            "2026-01-01T12:30+24:00",
            "0000-01-01",
            "2026-W54",
            "2026-W01-",
            "2026-01-01T12:30:45:00",
            "2026-0101",
        ] {
            assert!(fromisoformat(text).is_err(), "{text:?}");
        }
    }

    #[test]
    fn utc_instants_compare_across_offsets() {
        let a = fromisoformat("2026-01-01T00:00:00+01:00").unwrap();
        let b = fromisoformat("2025-12-31T23:00:00+00:00").unwrap();
        assert_eq!(a.utc_micros().unwrap(), b.utc_micros().unwrap());
        assert!(
            fromisoformat("2026-01-01T00:00:00")
                .unwrap()
                .utc_micros()
                .is_none()
        );
        let early = fromisoformat("0001-01-01T00:00:00+01:00").unwrap();
        assert_eq!(
            early.utc_micros().unwrap().unwrap_err().kind,
            ErrorKind::Overflow
        );
    }

    #[test]
    fn ordinals_round_trip() {
        for value in [1, 59, 60, 61, 365, 366, 719_163, 3_652_059] {
            let (year, month, day) = from_ordinal(value);
            assert_eq!(ordinal(year, month, day), value);
        }
        assert_eq!(from_ordinal(1), (1, 1, 1));
        assert_eq!(from_ordinal(719_163), (1970, 1, 1));
    }
}
