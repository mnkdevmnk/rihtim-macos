import AppKit
import SwiftUI

/// Open-Meteo: no API key, no location permission; the city is picked in Settings.
struct WeatherNow: Equatable, Sendable {
    let temp: Double
    let feels: Double
    let code: Int
    let isDay: Bool
    let humidity: Double
    let wind: Double
}

struct WeatherHour: Identifiable, Equatable, Sendable {
    var id: Date { time }
    let time: Date
    let temp: Double
    let rainChance: Int
    let code: Int
}

struct WeatherDay: Equatable, Sendable {
    let sunrise: Date?
    let sunset: Date?
    let uvMax: Double?
    let high: Double?
    let low: Double?
}

struct GeoPlace: Equatable, Sendable, Identifiable {
    var id: String { "\(lat),\(lon)" }
    let name: String
    let detail: String
    let lat: Double
    let lon: Double
}

enum WeatherCode {
    static func symbol(_ c: Int, day: Bool = true) -> String {
        switch c {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func text(_ c: Int) -> String {
        switch c {
        case 0: return L("Clear")
        case 1: return L("Mostly clear")
        case 2: return L("Partly cloudy")
        case 3: return L("Overcast")
        case 45, 48: return L("Fog")
        case 51...57: return L("Drizzle")
        case 61, 80: return L("Light rain")
        case 63, 81: return L("Rain")
        case 65, 82: return L("Heavy rain")
        case 66, 67: return L("Freezing rain")
        case 71, 85: return L("Light snow")
        case 73, 75, 77, 86: return L("Snow")
        case 95: return L("Thunderstorm")
        case 96, 99: return L("Hail")
        default: return "—"
        }
    }

    static func color(_ c: Int, day: Bool) -> Color {
        switch c {
        case 0, 1: return day ? .yellow : .indigo
        case 61...67, 80...82, 51...57: return .cyan
        case 95...99: return .purple
        default: return .white
        }
    }
}

private enum OpenMeteo {
    struct Result: Sendable {
        let now: WeatherNow
        let hours: [WeatherHour]
        let day: WeatherDay
    }

    static func fetch(lat: Double, lon: Double) async throws -> Result {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "daily", value: "sunrise,sunset,uv_index_max,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let offset = obj["utc_offset_seconds"] as? Int ?? 0
        let tz = TimeZone(secondsFromGMT: offset) ?? .current

        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? Double) ?? Double(d[k] as? Int ?? 0) }
        let now = WeatherNow(temp: num(cur, "temperature_2m"), feels: num(cur, "apparent_temperature"),
                             code: cur["weather_code"] as? Int ?? 0, isDay: (cur["is_day"] as? Int ?? 1) == 1,
                             humidity: num(cur, "relative_humidity_2m"), wind: num(cur, "wind_speed_10m"))

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"

        var hours: [WeatherHour] = []
        if let h = obj["hourly"] as? [String: Any],
           let times = h["time"] as? [String],
           let temps = (h["temperature_2m"] as? [Any])?.map({ ($0 as? NSNumber)?.doubleValue ?? 0 }) {
            let rain: [Int?] = (h["precipitation_probability"] as? [Any])?.map { ($0 as? NSNumber)?.intValue } ?? []
            let codes = h["weather_code"] as? [Int] ?? []
            let from = Date().addingTimeInterval(-3600)
            for (i, t) in times.enumerated() {
                guard let d = df.date(from: t), d >= from, i < temps.count else { continue }
                hours.append(WeatherHour(time: d, temp: temps[i],
                                         rainChance: (i < rain.count ? rain[i] : nil) ?? 0,
                                         code: i < codes.count ? codes[i] : 0))
                if hours.count == 12 { break }
            }
        }

        var day = WeatherDay(sunrise: nil, sunset: nil, uvMax: nil, high: nil, low: nil)
        if let d = obj["daily"] as? [String: Any] {
            day = WeatherDay(sunrise: (d["sunrise"] as? [String])?.first.flatMap(df.date(from:)),
                             sunset: (d["sunset"] as? [String])?.first.flatMap(df.date(from:)),
                             uvMax: (d["uv_index_max"] as? [Double])?.first,
                             high: (d["temperature_2m_max"] as? [Double])?.first,
                             low: (d["temperature_2m_min"] as? [Double])?.first)
        }
        return Result(now: now, hours: hours, day: day)
    }

    static func search(_ name: String) async throws -> [GeoPlace] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "6"), .init(name: "language", value: L10n.code)]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let n = r["name"] as? String, let la = r["latitude"] as? Double, let lo = r["longitude"] as? Double else { return nil }
            let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return GeoPlace(name: n, detail: detail, lat: la, lon: lo)
        }
    }
}

@MainActor
final class WeatherMonitor: ObservableObject {
    @Published private(set) var now: WeatherNow?
    @Published private(set) var hours: [WeatherHour] = []
    @Published private(set) var day: WeatherDay?
    @Published private(set) var error: String?
    @Published private(set) var place: GeoPlace

    private var timer: Timer?
    private var inFlight = false
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        if let name = d.string(forKey: "weatherCity"), d.object(forKey: "weatherLat") != nil {
            place = GeoPlace(name: name, detail: d.string(forKey: "weatherDetail") ?? "",
                             lat: d.double(forKey: "weatherLat"), lon: d.double(forKey: "weatherLon"))
        } else {
            place = Self.defaultPlace
        }
    }

    /// Until a city is picked: a big city for the UI language.
    private static var defaultPlace: GeoPlace {
        switch L10n.code {
        case "tr": return GeoPlace(name: "İstanbul", detail: "İstanbul, Türkiye", lat: 41.0082, lon: 28.9784)
        case "de": return GeoPlace(name: "Berlin", detail: "Berlin, Deutschland", lat: 52.5200, lon: 13.4050)
        default: return GeoPlace(name: "London", detail: "England, United Kingdom", lat: 51.5072, lon: -0.1276)
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setPlace(_ p: GeoPlace) {
        place = p
        defaults.set(p.name, forKey: "weatherCity")
        defaults.set(p.detail, forKey: "weatherDetail")
        defaults.set(p.lat, forKey: "weatherLat")
        defaults.set(p.lon, forKey: "weatherLon")
        refresh()
    }

    func search(_ name: String) async -> [GeoPlace] {
        (try? await OpenMeteo.search(name)) ?? []
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let p = place
        Task { [weak self] in
            do {
                let r = try await OpenMeteo.fetch(lat: p.lat, lon: p.lon)
                self?.now = r.now
                self?.hours = r.hours
                self?.day = r.day
                self?.error = nil
            } catch {
                self?.error = error.localizedDescription
            }
            self?.inFlight = false
        }
    }
}

// MARK: - Views

struct WeatherPill: View {
    @ObservedObject var weather: WeatherMonitor
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let n = weather.now {
                Image(systemName: WeatherCode.symbol(n.code, day: n.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
                    .frame(width: height - 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(n.temp.rounded()))°").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(L("Feels like %d°", Int(n.feels.rounded())) + " · \(WeatherCode.text(n.code))")
                        .font(.system(size: 9.5)).foregroundColor(.secondary).lineLimit(1)
                }
            } else {
                Image(systemName: "cloud").font(.system(size: 20)).foregroundColor(.secondary)
                Text(weather.error == nil ? L("Loading…") : L("Couldn't get the weather")).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
    }
}

struct WeatherPopover: View {
    @ObservedObject var weather: WeatherMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(weather.place.name).font(.system(size: 14, weight: .semibold))
                if let n = weather.now {
                    Text("\(Int(n.temp.rounded()))° · \(WeatherCode.text(n.code))")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                if let d = weather.day, let hi = d.high, let lo = d.low {
                    Text("↑\(Int(hi.rounded()))°  ↓\(Int(lo.rounded()))°").font(.system(size: 11, weight: .medium))
                }
            }
            HStack(spacing: 0) {
                ForEach(weather.hours) { h in
                    VStack(spacing: 4) {
                        Text(h.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(L10n.locale)))
                            .font(.system(size: 9.5)).foregroundColor(.secondary)
                        Image(systemName: WeatherCode.symbol(h.code))
                            .symbolRenderingMode(.multicolor).font(.system(size: 13)).frame(height: 16)
                        Text("\(Int(h.temp.rounded()))°").font(.system(size: 11, weight: .semibold))
                        Text(h.rainChance > 0 ? Fmt.pct(h.rainChance) : " ")
                            .font(.system(size: 8.5)).foregroundColor(.cyan)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Divider().opacity(0.4)
            if let n = weather.now {
                HStack(spacing: 14) {
                    stat("humidity.fill", Fmt.pct(Int(n.humidity)))
                    stat("wind", "\(Int(n.wind.rounded())) km/h")
                    if let uv = weather.day?.uvMax { stat("sun.max", "UV \(Int(uv.rounded()))") }
                    if let r = weather.day?.sunrise { stat("sunrise.fill", Fmt.clock(r)) }
                    if let s = weather.day?.sunset { stat("sunset.fill", Fmt.clock(s)) }
                }
            }
            if let e = weather.error { Text(e).font(.system(size: 10)).foregroundColor(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PanelBackground())
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundColor(.secondary)
            Text(text).font(.system(size: 11, weight: .medium))
        }
    }
}
