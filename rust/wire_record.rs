//! Zero-copy parser for Meridian settlement wire records.
//!
//! Banks deliver settlement files as fixed-layout text: one record per line,
//! a three-letter tag, then `|`-separated fields. A day's file can run to
//! millions of lines, so the parser never allocates per record: every field
//! is a `&str` borrowed from the input buffer, and the iterator yields
//! records lazily.
//!
//! ```text
//! HDR|MERIDIAN|2026-11-06|EUR|v2
//! PAY|btc_7Q2M|mrc_harbourline|12500|2026-11-10|Net settlement week 45
//! PAY|btc_7Q2N|mrc_tidewater|-3150|2026-11-10|Debit: refunds exceeded captures
//! TRL|2|9350
//! ```

use std::fmt;
use std::num::ParseIntError;

/// A parsed line. Every string borrows from the original buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Record<'a> {
    Header(Header<'a>),
    Payment(Payment<'a>),
    Trailer { count: u32, total_minor: i64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header<'a> {
    pub sender: &'a str,
    pub business_date: Date,
    pub currency: &'a str,
    pub layout: &'a str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Payment<'a> {
    pub batch_id: &'a str,
    pub merchant_id: &'a str,
    pub amount_minor: i64,
    pub value_date: Date,
    /// Free text, may contain anything except a newline, including `|`.
    pub narrative: &'a str,
}

/// A calendar date without the weight of a date-time library.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date {
    pub year: u16,
    pub month: u8,
    pub day: u8,
}

impl fmt::Display for Date {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

impl Date {
    fn parse(s: &str) -> Result<Self, ErrorKind> {
        let bytes = s.as_bytes();
        if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
            return Err(ErrorKind::BadDate);
        }
        let num = |range: std::ops::Range<usize>| -> Result<u16, ErrorKind> {
            s[range].parse::<u16>().map_err(|_| ErrorKind::BadDate)
        };
        let (year, month, day) = (num(0..4)?, num(5..7)?, num(8..10)?);
        let max_day = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if is_leap(year) => 29,
            2 => 28,
            _ => return Err(ErrorKind::BadDate),
        };
        if day == 0 || day > max_day {
            return Err(ErrorKind::BadDate);
        }
        Ok(Date { year, month: month as u8, day: day as u8 })
    }
}

const fn is_leap(year: u16) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    UnknownTag(String),
    MissingField(&'static str),
    BadAmount(ParseIntError),
    BadDate,
    HeaderNotFirst,
    TrailerMismatch { declared: (u32, i64), seen: (u32, i64) },
}

/// An error with the one-based line it happened on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    pub line: usize,
    pub kind: ErrorKind,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: ", self.line)?;
        match &self.kind {
            ErrorKind::UnknownTag(tag) => write!(f, "unknown record tag {tag:?}"),
            ErrorKind::MissingField(name) => write!(f, "missing field `{name}`"),
            ErrorKind::BadAmount(e) => write!(f, "amount is not an integer: {e}"),
            ErrorKind::BadDate => f.write_str("date is not a valid YYYY-MM-DD"),
            ErrorKind::HeaderNotFirst => f.write_str("HDR must be the first record"),
            ErrorKind::TrailerMismatch { declared, seen } => write!(
                f,
                "trailer declares {} records totalling {}, file holds {} totalling {}",
                declared.0, declared.1, seen.0, seen.1
            ),
        }
    }
}

impl std::error::Error for ParseError {}

/// Splits a line into fields, handing out borrowed slices on demand.
struct Fields<'a> {
    rest: Option<&'a str>,
}

impl<'a> Fields<'a> {
    fn new(line: &'a str) -> Self {
        Self { rest: Some(line) }
    }

    fn next(&mut self, name: &'static str) -> Result<&'a str, ErrorKind> {
        let rest = self.rest.ok_or(ErrorKind::MissingField(name))?;
        match rest.split_once('|') {
            Some((head, tail)) => {
                self.rest = Some(tail);
                Ok(head)
            }
            None => {
                self.rest = None;
                Ok(rest)
            }
        }
    }

    /// The remainder of the line, separators included: used for free text.
    fn remainder(&mut self, name: &'static str) -> Result<&'a str, ErrorKind> {
        self.rest.take().ok_or(ErrorKind::MissingField(name))
    }
}

fn parse_line(line: &str) -> Result<Record<'_>, ErrorKind> {
    let mut f = Fields::new(line);
    match f.next("tag")? {
        "HDR" => Ok(Record::Header(Header {
            sender: f.next("sender")?,
            business_date: Date::parse(f.next("business_date")?)?,
            currency: f.next("currency")?,
            layout: f.next("layout")?,
        })),
        "PAY" => Ok(Record::Payment(Payment {
            batch_id: f.next("batch_id")?,
            merchant_id: f.next("merchant_id")?,
            amount_minor: f.next("amount")?.parse().map_err(ErrorKind::BadAmount)?,
            value_date: Date::parse(f.next("value_date")?)?,
            narrative: f.remainder("narrative")?,
        })),
        "TRL" => Ok(Record::Trailer {
            count: f.next("count")?.parse().map_err(ErrorKind::BadAmount)?,
            total_minor: f.next("total")?.parse().map_err(ErrorKind::BadAmount)?,
        }),
        other => Err(ErrorKind::UnknownTag(other.to_owned())),
    }
}

/// Lazily parses records and checks the trailer against what it has seen.
pub struct Records<'a> {
    lines: std::iter::Enumerate<std::str::Lines<'a>>,
    seen_count: u32,
    seen_total: i64,
    first: bool,
}

pub fn parse(input: &str) -> Records<'_> {
    Records { lines: input.lines().enumerate(), seen_count: 0, seen_total: 0, first: true }
}

impl<'a> Iterator for Records<'a> {
    type Item = Result<Record<'a>, ParseError>;

    fn next(&mut self) -> Option<Self::Item> {
        let (index, raw) = self.lines.by_ref().find(|(_, l)| !l.trim().is_empty())?;
        let line = index + 1;
        let fail = |kind| Some(Err(ParseError { line, kind }));

        let record = match parse_line(raw.trim_end_matches('\r')) {
            Ok(r) => r,
            Err(kind) => return fail(kind),
        };

        let was_first = std::mem::replace(&mut self.first, false);
        match record {
            Record::Header(_) if !was_first => return fail(ErrorKind::HeaderNotFirst),
            Record::Payment(p) => {
                self.seen_count += 1;
                self.seen_total += p.amount_minor;
            }
            Record::Trailer { count, total_minor }
                if (count, total_minor) != (self.seen_count, self.seen_total) =>
            {
                return fail(ErrorKind::TrailerMismatch {
                    declared: (count, total_minor),
                    seen: (self.seen_count, self.seen_total),
                });
            }
            _ => {}
        }
        Some(Ok(record))
    }
}

/// Convenience: the payments of a whole file, or the first error.
pub fn payments(input: &str) -> Result<Vec<Payment<'_>>, ParseError> {
    parse(input)
        .filter_map(|r| match r {
            Ok(Record::Payment(p)) => Some(Ok(p)),
            Ok(_) => None,
            Err(e) => Some(Err(e)),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
HDR|MERIDIAN|2026-11-06|EUR|v2
PAY|btc_7Q2M|mrc_harbourline|12500|2026-11-10|Net settlement week 45
PAY|btc_7Q2N|mrc_tidewater|-3150|2026-11-10|Debit | refunds exceeded captures

TRL|2|9350
";

    #[test]
    fn parses_a_well_formed_file() {
        let records: Vec<_> = parse(SAMPLE).collect::<Result<_, _>>().unwrap();
        assert_eq!(records.len(), 4);
        let Record::Header(h) = records[0] else { panic!("expected a header") };
        assert_eq!(h.currency, "EUR");
        assert_eq!(h.business_date.to_string(), "2026-11-06");
    }

    #[test]
    fn narrative_keeps_its_separators() {
        let pays = payments(SAMPLE).unwrap();
        assert_eq!(pays[1].narrative, "Debit | refunds exceeded captures");
        assert_eq!(pays[1].amount_minor, -3150);
    }

    #[test]
    fn fields_borrow_from_the_input() {
        let pays = payments(SAMPLE).unwrap();
        let range = SAMPLE.as_bytes().as_ptr_range();
        assert!(range.contains(&pays[0].batch_id.as_ptr()));
    }

    #[test]
    fn trailer_mismatch_names_both_totals() {
        let bad = SAMPLE.replace("TRL|2|9350", "TRL|2|9351");
        let err = payments(&bad).unwrap_err();
        assert_eq!(err.line, 5);
        assert!(err.to_string().contains("totalling 9351"), "{err}");
    }

    #[test]
    fn rejects_impossible_dates() {
        for date in ["2026-02-29", "2026-13-01", "2026-04-31", "26-11-06"] {
            assert_eq!(Date::parse(date), Err(ErrorKind::BadDate), "{date}");
        }
        assert!(Date::parse("2028-02-29").is_ok());
    }

    #[test]
    fn header_must_come_first() {
        let input = "PAY|b|m|1|2026-11-10|x\nHDR|MERIDIAN|2026-11-06|EUR|v2\n";
        let err = parse(input).nth(1).unwrap().unwrap_err();
        assert_eq!(err, ParseError { line: 2, kind: ErrorKind::HeaderNotFirst });
    }

    #[test]
    fn missing_field_is_reported_by_name() {
        let err = parse("PAY|btc_1|mrc_1").next().unwrap().unwrap_err();
        assert_eq!(err.kind, ErrorKind::MissingField("amount"));
    }
}
