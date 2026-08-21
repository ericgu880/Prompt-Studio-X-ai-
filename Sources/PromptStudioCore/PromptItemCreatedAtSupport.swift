import Foundation

/// Canonical conversion shared by item-sequence migration and every ready
/// item projection.  Raw prompt_items.createdAt remains an opaque compatibility
/// field; ready callers use the persisted signed epoch-microsecond key.
public enum PromptItemCreatedAtSupport {
    private static let microsecondsPerSecond = 1_000_000.0
    private static let strictRFC3339Pattern = try! NSRegularExpression(
        pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(Z|[+-][0-9]{2}:[0-9]{2})$"#
    )

    private struct ParsedTimestamp {
        let wholeSecond: Date
        let fraction: String?
    }

    /// One createdAt observation shared by the pre-ready loader and item
    /// migration. Canonical RFC3339 values use the exact decimal microsecond
    /// parser. Historical values that the legacy ISO8601DateFormatter accepted
    /// (including lenient offsets, UTC spellings, and other old data) retain
    /// that Date interpretation and derive their key from the same Date.
    struct LegacyObservation: Sendable, Equatable {
        let date: Date
        let sortKey: Int64
    }

    /// Classifies raw createdAt exactly once for both legacy consumers. A nil
    /// result means the old loader would have fallen back to Date().
    static func legacyObservation(from raw: String) -> LegacyObservation? {
        if let canonicalSortKey = sortKey(from: raw),
           let canonicalDate = date(from: raw) {
            return LegacyObservation(date: canonicalDate, sortKey: canonicalSortKey)
        }
        guard !raw.isEmpty,
              let legacyDate = ISO8601DateFormatter().date(from: raw) else {
            return nil
        }
        return LegacyObservation(date: legacyDate, sortKey: sortKey(for: legacyDate))
    }

    /// Parses a product-supported RFC3339 timestamp without changing the raw
    /// database value.  The structure and calendar components are validated
    /// before any Foundation parser runs because those parsers accept trailing
    /// junk and normalize out-of-range dates/times.  Fractional seconds have
    /// no fixed digit limit; the persisted sort-key helper performs
    /// microsecond quantization separately.  Four-digit year 0000 is rejected
    /// because the product's Gregorian Date range starts at year 0001.
    public static func date(from raw: String) -> Date? {
        guard let parsed = parsedTimestamp(from: raw) else { return nil }
        guard let fraction = parsed.fraction else { return parsed.wholeSecond }
        guard let fractionalSeconds = Double("0.\(fraction)"), fractionalSeconds.isFinite else {
            return nil
        }
        return parsed.wholeSecond.addingTimeInterval(fractionalSeconds)
    }

    private static func parsedTimestamp(from raw: String) -> ParsedTimestamp? {
        guard !raw.isEmpty else { return nil }
        let fullRange = NSRange(raw.startIndex..., in: raw)
        guard let match = strictRFC3339Pattern.firstMatch(in: raw, range: fullRange),
              match.range.location == fullRange.location,
              match.range.length == fullRange.length else { return nil }

        func capture(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: raw) else { return nil }
            return String(raw[swiftRange])
        }

        guard let year = capture(1).flatMap(Int.init),
              let month = capture(2).flatMap(Int.init),
              let day = capture(3).flatMap(Int.init),
              let hour = capture(4).flatMap(Int.init),
              let minute = capture(5).flatMap(Int.init),
              let second = capture(6).flatMap(Int.init),
              let timeZoneRaw = capture(8) else { return nil }
        guard (1...12).contains(month),
              (1...9999).contains(year),
              (0..<24).contains(hour),
              (0..<60).contains(minute),
              (0..<60).contains(second) else { return nil }

        let offsetSeconds: Int
        if timeZoneRaw == "Z" {
            offsetSeconds = 0
        } else {
            let sign = timeZoneRaw.first == "-" ? -1 : 1
            let offsetHour = Int(timeZoneRaw.dropFirst().prefix(2)) ?? -1
            let offsetMinute = Int(timeZoneRaw.suffix(2)) ?? -1
            guard (0...23).contains(offsetHour), (0..<60).contains(offsetMinute) else {
                return nil
            }
            offsetSeconds = sign * ((offsetHour * 60 + offsetMinute) * 60)
        }

        // Foundation's fixed-offset TimeZone rejects the legal RFC3339 edge
        // offsets ±23:59.  Build the local Gregorian components in UTC,
        // verify them there, then subtract the parsed offset directly.
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(
            calendar: calendar,
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let localDate = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: localDate)
        guard verified.year == year,
              verified.month == month,
              verified.day == day,
              verified.hour == hour,
              verified.minute == minute,
              verified.second == second else { return nil }

        let date = localDate.addingTimeInterval(-Double(offsetSeconds))
        guard date.timeIntervalSince1970.isFinite else { return nil }
        return ParsedTimestamp(wholeSecond: date, fraction: capture(7))
    }

    /// Converts a Date to signed epoch microseconds with nearest-microsecond
    /// quantization.  Values outside Int64's representable range clamp at the
    /// corresponding endpoint rather than trapping during migration.
    public static func sortKey(for date: Date) -> Int64 {
        let scaled = date.timeIntervalSince1970 * microsecondsPerSecond
        guard scaled.isFinite else {
            return scaled.sign == .minus ? Int64.min : Int64.max
        }

        let rounded = scaled.rounded()
        if rounded >= Double(Int64.max) { return Int64.max }
        if rounded <= Double(Int64.min) { return Int64.min }
        return Int64(rounded)
    }

    /// Converts raw RFC3339 text directly to signed epoch microseconds.
    /// Fractional digits are quantized as decimal text so values with more than
    /// six digits never pass through Date's Double representation before
    /// rounding.  Ties follow Date.timeIntervalSince1970.rounded(): a negative
    /// half-microsecond rounds away from zero while a positive tie rounds up.
    public static func sortKey(from raw: String) -> Int64? {
        guard let parsed = parsedTimestamp(from: raw) else { return nil }
        let wholeSecondsDouble = parsed.wholeSecond.timeIntervalSince1970
        guard wholeSecondsDouble.isFinite else { return nil }
        let wholeSecondsRounded = wholeSecondsDouble.rounded()
        guard wholeSecondsRounded >= Double(Int64.min), wholeSecondsRounded <= Double(Int64.max) else {
            return wholeSecondsRounded.sign == .minus ? Int64.min : Int64.max
        }
        let seconds = Int64(wholeSecondsRounded)
        let fraction = decimalMicroseconds(for: parsed.fraction)
        let (scaledSeconds, scaleOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !scaleOverflow else { return seconds < 0 ? Int64.min : Int64.max }
        let (truncated, addOverflow) = scaledSeconds.addingReportingOverflow(fraction.microseconds)
        guard !addOverflow else { return scaledSeconds < 0 ? Int64.min : Int64.max }
        guard let discardedDigit = fraction.discardedDigit else { return truncated }

        // Decimal digits after the sixth represent a remainder in microseconds.
        // A positive total uses the usual half-up rule.  For a negative total,
        // an exact half remains at the more-negative integer (away from zero),
        // while a value strictly above half moves toward zero.
        let strictlyAboveHalf = discardedDigit > 53 || (discardedDigit == 53 && fraction.discardedTailIsNonZero)
        let shouldRoundUp = truncated < 0 ? strictlyAboveHalf : discardedDigit >= 53
        guard shouldRoundUp else { return truncated }
        let (rounded, roundOverflow) = truncated.addingReportingOverflow(1)
        return roundOverflow ? Int64.max : rounded
    }

    private struct DecimalMicroseconds {
        let microseconds: Int64
        let discardedDigit: UInt8?
        let discardedTailIsNonZero: Bool
    }

    private static func decimalMicroseconds(for fraction: String?) -> DecimalMicroseconds {
        guard let fraction, !fraction.isEmpty else {
            return DecimalMicroseconds(microseconds: 0, discardedDigit: nil, discardedTailIsNonZero: false)
        }
        let bytes = Array(fraction.utf8)
        var microseconds: Int64 = 0
        var consumed = 0
        for byte in bytes {
            guard consumed < 6 else { break }
            microseconds = microseconds * 10 + Int64(byte - 48)
            consumed += 1
        }
        while consumed < 6 {
            microseconds *= 10
            consumed += 1
        }
        let discardedDigit = bytes.count > 6 ? bytes[6] : nil
        let discardedTailIsNonZero = bytes.dropFirst(7).contains { $0 != 48 }
        return DecimalMicroseconds(
            microseconds: microseconds,
            discardedDigit: discardedDigit,
            discardedTailIsNonZero: discardedTailIsNonZero
        )
    }

    /// Decodes a persisted epoch-microsecond key without consulting raw text.
    public static func date(forSortKey key: Int64) -> Date {
        Date(timeIntervalSince1970: Double(key) / microsecondsPerSecond)
    }

    /// Maximum observable error introduced by Date→microseconds→Date for a
    /// given value.  Product-range values are bounded by half a microsecond
    /// plus Foundation's Date floating-point representation error.
    public static func quantizationError(for value: Date) -> TimeInterval {
        abs(date(forSortKey: sortKey(for: value)).timeIntervalSince(value))
    }
}
