//
//  TimeOfDay.swift: [M13] which part of the day it is, so the pet can greet you like it
//  noticed.
//
//  SPEC §5: no AppKit. SPEC §9: the date is a parameter, never a `Date()` read inside the
//  function. Otherwise the one greeting that only appears after midnight is a feature that
//  can be checked once a night, by hand, by somebody who is up after midnight.
//
//  Kept in its own file rather than folded into `Occasion`: that type answers "which day is
//  it" for the birthday and the once-a-day dedication, and both of those compare a date
//  stamp. This one throws the date away and keeps the clock, which is the opposite
//  question. One enum answering both would have to be named after neither.
//

import Foundation

/// The four parts of a day the pet can tell apart.
///
/// Four, not more. The greeting pools are hand written and have to stay distinct, and a
/// fifth part ("late morning") would either share its lines with the neighbours it sits
/// between, which is the thing this feature exists to stop, or thin every pool below the
/// two entries `Phrasebook.reply` needs in order to avoid repeating itself.
///
/// `String`-raw and `CaseIterable` for the same reasons `PetState` and `PetPrompt` are: the
/// raw value is what a log line can print, and `allCases` is what lets a test walk every
/// pool without keeping a list of its own that can fall out of step.
public enum TimeOfDay: String, CaseIterable {
    case morning, afternoon, evening, night

    /// Which part of the day `date` falls in.
    ///
    /// The boundaries, and why they sit where they do:
    ///
    ///   * **05:00** opens the morning. Anyone awake before it has not started the day.
    ///     They have not finished the previous one, and should be greeted accordingly.
    ///   * **12:00** opens the afternoon. Noon needs no argument.
    ///   * **17:00** opens the evening: the hour the working afternoon stops being one,
    ///     which is early enough that "you can put it down" is still worth saying.
    ///   * **22:00** opens the night, and the night runs through midnight to 04:59. Late
    ///     enough that "still up?" is an observation rather than a comment on somebody's
    ///     habits.
    ///
    /// Night is the only case that wraps past midnight, and that is exactly why it is the
    /// `default` branch rather than a clever piece of modular arithmetic. Written as a
    /// range it would be two ranges, and the second one is the easy one to forget: an hour
    /// of 0 through 4 is night that belongs to the evening before it, not to the morning
    /// whose date it happens to share.
    ///
    /// The calendar is a parameter, defaulted to `.current`, for the same reason the date
    /// is. `.current` reads the machine's time zone, so a test that wants 02:00 to exist
    /// can hand in a fixed UTC calendar and get the hour it asked for. On a machine whose
    /// local 02:00 is skipped by a daylight saving jump, the default would quietly have no
    /// such hour to test.
    public static func at(_ date: Date, calendar: Calendar = .current) -> TimeOfDay {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12:  return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default:      return .night
        }
    }
}
