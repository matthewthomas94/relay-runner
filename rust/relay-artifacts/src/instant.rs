//! A timezone-aware UTC instant, as the part 2 modules use Python's
//! `datetime` objects: parsed with `datetime.fromisoformat`, compared in UTC
//! and written back with `isoformat()`.
//!
//! The value is microseconds since 0001-01-01T00:00:00Z, the same scale
//! `isotime::DateTime::utc_micros` returns, so years 1 to 9999 are the range.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::isotime;
use crate::{Error, ErrorKind, Result};

const MICROS_PER_SECOND: i64 = 1_000_000;
const MICROS_PER_DAY: i64 = 86_400 * MICROS_PER_SECOND;
/// Days from 0001-01-01 to 1970-01-01.
const UNIX_EPOCH_DAYS: i64 = 719_162;

/// One UTC instant with microsecond precision.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Instant(pub i64);

impl Instant {
    /// `datetime.now(timezone.utc)`.
    pub fn now() -> Self {
        let elapsed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_micros() as i64);
        Self::from_unix_micros(elapsed)
    }

    /// `datetime.fromtimestamp(micros / 1e6, tz=timezone.utc)`.
    pub fn from_unix_micros(micros: i64) -> Self {
        Instant(micros + UNIX_EPOCH_DAYS * MICROS_PER_DAY)
    }

    /// Microseconds since the Unix epoch.
    pub fn unix_micros(self) -> i64 {
        self.0 - UNIX_EPOCH_DAYS * MICROS_PER_DAY
    }

    /// `datetime.timestamp()`, as a float of seconds.
    pub fn timestamp(self) -> f64 {
        self.unix_micros() as f64 / 1e6
    }

    /// `datetime.fromisoformat(text)`: `Ok(None)` for a naive value, the
    /// `ValueError` for text it refuses, `OverflowError` when the UTC
    /// instant leaves years 1 to 9999.
    pub fn fromisoformat(text: &str) -> Result<Option<Self>> {
        match isotime::fromisoformat(text)?.utc_micros() {
            None => Ok(None),
            Some(micros) => micros.map(|micros| Some(Instant(micros))),
        }
    }

    /// `datetime.fromisoformat(text.replace("Z", "+00:00"))`.
    pub fn fromisoformat_z(text: &str) -> Result<Option<Self>> {
        Self::fromisoformat(&text.replace('Z', "+00:00"))
    }

    /// The instant plus `micros` microseconds; `OverflowError` out of range.
    pub fn add_micros(self, micros: i64) -> Result<Self> {
        let last = ordinal_days(9999, 12, 31) * MICROS_PER_DAY;
        match self.0.checked_add(micros) {
            Some(value) if (0..last).contains(&value) => Ok(Instant(value)),
            _ => Err(Error::new(ErrorKind::Overflow, "date value out of range")),
        }
    }

    /// `(year, month, day, hour, minute, second, microsecond)` in UTC.
    pub fn fields(self) -> (i64, i64, i64, i64, i64, i64, i64) {
        let days = self.0.div_euclid(MICROS_PER_DAY);
        let rest = self.0.rem_euclid(MICROS_PER_DAY);
        let (year, month, day) = civil_from_days(days);
        let seconds = rest / MICROS_PER_SECOND;
        (
            year,
            month,
            day,
            seconds / 3600,
            seconds / 60 % 60,
            seconds % 60,
            rest % MICROS_PER_SECOND,
        )
    }

    /// `value.isoformat(timespec="microseconds")` in UTC: always six
    /// fractional digits, offset `+00:00`.
    pub fn isoformat_micros(self) -> String {
        let (year, month, day, hour, minute, second, micro) = self.fields();
        format!(
            "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{micro:06}+00:00"
        )
    }

    /// `value.isoformat()` in UTC: the fraction only when it is not zero.
    pub fn isoformat(self) -> String {
        let (year, month, day, hour, minute, second, micro) = self.fields();
        let mut text =
            format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}");
        if micro != 0 {
            text.push_str(&format!(".{micro:06}"));
        }
        text.push_str("+00:00");
        text
    }

    /// `isoformat_micros().replace("+00:00", "Z")`.
    pub fn isoformat_micros_z(self) -> String {
        self.isoformat_micros().replace("+00:00", "Z")
    }

    /// `isoformat().replace("+00:00", "Z")`.
    pub fn isoformat_z(self) -> String {
        self.isoformat().replace("+00:00", "Z")
    }
}

fn is_leap(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

/// Days from 0001-01-01 to the given date.
fn ordinal_days(year: i64, month: i64, day: i64) -> i64 {
    const BEFORE: [i64; 12] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    let previous = year - 1;
    let mut days = previous * 365 + previous / 4 - previous / 100 + previous / 400;
    days += BEFORE[(month - 1) as usize];
    if month > 2 && is_leap(year) {
        days += 1;
    }
    days + day - 1
}

/// The proleptic Gregorian date `days` after 0001-01-01.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    // Howard Hinnant's algorithm, shifted from the Unix epoch.
    let z = days - UNIX_EPOCH_DAYS + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_round_trip() {
        let parsed = Instant::fromisoformat_z("2026-08-04T05:00:00.000120Z")
            .unwrap()
            .unwrap();
        assert_eq!(parsed.isoformat_micros_z(), "2026-08-04T05:00:00.000120Z");
        assert_eq!(parsed.isoformat(), "2026-08-04T05:00:00.000120+00:00");
        let whole = Instant::fromisoformat("2026-08-04T07:00:00+02:00")
            .unwrap()
            .unwrap();
        assert_eq!(whole.isoformat_z(), "2026-08-04T05:00:00Z");
        assert_eq!(whole.isoformat_micros(), "2026-08-04T05:00:00.000000+00:00");
        assert!(Instant::fromisoformat("2026-08-04T05:00:00").unwrap().is_none());
    }

    #[test]
    fn unix_epoch_and_leap_days() {
        let epoch = Instant::from_unix_micros(0);
        assert_eq!(epoch.isoformat_z(), "1970-01-01T00:00:00Z");
        assert_eq!(epoch.unix_micros(), 0);
        for (text, days) in [("2024-02-29", 0), ("2000-03-01", 0), ("0001-01-01", 0)] {
            let value = Instant::fromisoformat(&format!("{text}T00:00:00+00:00"))
                .unwrap()
                .unwrap();
            let _ = days;
            assert!(value.isoformat().starts_with(text));
        }
        assert_eq!(
            Instant::fromisoformat("0001-01-01T00:00:00+00:00")
                .unwrap()
                .unwrap()
                .0,
            0
        );
    }
}
