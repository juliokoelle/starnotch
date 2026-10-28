import Testing
import TestSupport
@testable import NotchCore

@Suite struct DailyTests {
    // MARK: Weather

    @Test func forecastParsesNowHighLowAndHours() throws {
        let json = """
        {"current":{"time":1793167200,"interval":900,"temperature_2m":8.6,"weather_code":3,"is_day":1},
         "hourly":{"time":[1793163600,1793167200,1793170800,1793174400],
                   "temperature_2m":[7.2,8.6,9.1,null],"weather_code":[3,3,61,61],
                   "precipitation_probability":[0,0,23,60],"is_day":[1,1,1,0]},
         "daily":{"time":[1793142000,1793228400],"temperature_2m_max":[13.0,11.4],"temperature_2m_min":[6.9,6.1]}}
        """
        let fetched = UTC.date("2026-10-28 06:00")
        let report = try OpenMeteo.parseForecast(Bytes.data(json), unit: .celsius, fetched: fetched, place: "Berlin")
        #expect(report.temperature == 8.6)
        #expect(report.condition == .overcast)
        #expect(report.high == 13.0 && report.low == 6.9)
        // The hour without a temperature is left out.
        #expect(report.hours.count == 3)
        #expect(report.hours[2].condition == .rain && report.hours[2].precipitation == 23)
        #expect(report.range == "H 13° L 7°")
        #expect(report.place == "Berlin")
    }

    @Test func unreadableForecastThrows() {
        #expect(throws: OpenMeteo.Failure.self) {
            try OpenMeteo.parseForecast(Bytes.data("{\"error\":true}"), unit: .celsius, fetched: UTC.date("2026-10-28 06:00"))
        }
    }

    @Test func upcomingStartsWithTheCurrentHour() throws {
        let start = UTC.date("2026-10-28 06:00")
        let hours = (0..<6).map { WeatherHour(time: start.addingTimeInterval(Double($0) * 3600), temperature: Double($0), code: 0, isDay: true) }
        let report = WeatherReport(temperature: 1, code: 0, isDay: true, high: 5, low: 0, hours: hours, unit: .celsius, fetched: start)
        let upcoming = report.upcoming(from: UTC.date("2026-10-28 07:40"), count: 3)
        #expect(upcoming.map(\.temperature) == [1, 2, 3])
    }

    @Test func freshnessAndAge() {
        let fetched = UTC.date("2026-10-28 06:00")
        let report = WeatherReport(temperature: 1, code: 0, isDay: true, high: 5, low: 0, hours: [], unit: .celsius, fetched: fetched)
        #expect(report.isFresh(at: UTC.date("2026-10-28 06:29")))
        #expect(!report.isFresh(at: UTC.date("2026-10-28 06:31")))
        #expect(report.isUsable(at: UTC.date("2026-10-28 17:59")))
        #expect(!report.isUsable(at: UTC.date("2026-10-28 18:01")))
    }

    @Test func weatherCodesMapToConditions() {
        #expect(WeatherCondition(code: 0).symbol(isDay: true) == "sun.max.fill")
        #expect(WeatherCondition(code: 0).symbol(isDay: false) == "moon.stars.fill")
        #expect(WeatherCondition(code: 45) == .fog)
        #expect(WeatherCondition(code: 65) == .heavyRain)
        #expect(WeatherCondition(code: 81) == .showers)
        #expect(WeatherCondition(code: 99) == .thunderstorm)
        #expect(WeatherCondition(code: 1234) == .overcast)
        #expect(WeatherReport.degrees(-0.4) == "0°")
        #expect(WeatherReport.degrees(17.5) == "18°")
    }

    @Test func forecastURLRoundsTheLocation() {
        let url = OpenMeteo.forecastURL(latitude: 52.520_008, longitude: 13.404_954, unit: .fahrenheit).absoluteString
        #expect(url.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        #expect(url.contains("latitude=52.520") && url.contains("longitude=13.405"))
        #expect(url.contains("temperature_unit=fahrenheit"))
        #expect(!OpenMeteo.forecastURL(latitude: 1, longitude: 1, unit: .celsius).absoluteString.contains("temperature_unit"))
    }

    @Test func geocodingResults() {
        let json = """
        {"results":[{"id":1,"name":"Hamburg","latitude":53.55,"longitude":9.99,"country":"Germany","admin1":"Hamburg"},
                    {"id":2,"name":"Hamburg","latitude":33.2,"longitude":-91.8,"country":"United States","admin1":"Arkansas"}]}
        """
        let places = OpenMeteo.parsePlaces(Bytes.data(json))
        #expect(places.count == 2)
        #expect(places[0].label == "Hamburg, Germany")
        #expect(places[0].fullLabel == "Hamburg, Germany")
        #expect(places[1].fullLabel == "Hamburg, Arkansas, United States")
        #expect(OpenMeteo.parsePlaces(Bytes.data("{\"generationtime_ms\":0.1}")).isEmpty)
    }

    // MARK: Day progress

    @Test func workDayPhases() {
        let day = WorkDay(start: 9 * 60, end: 17 * 60)
        let calendar = UTC.calendar
        // 2026-10-28 is a Wednesday.
        #expect(day.phase(at: UTC.date("2026-10-28 08:59"), calendar: calendar) == .before)
        #expect(day.progress(at: UTC.date("2026-10-28 13:00"), calendar: calendar) == 0.5)
        #expect(day.minutesLeft(at: UTC.date("2026-10-28 13:00"), calendar: calendar) == 240)
        #expect(day.phase(at: UTC.date("2026-10-28 17:00"), calendar: calendar) == .after)
        #expect(day.progress(at: UTC.date("2026-10-28 18:00"), calendar: calendar) == 1)
    }

    @Test func weekendsAreOffUnlessTheyCount() {
        let calendar = UTC.calendar
        let saturday = UTC.date("2026-10-31 12:00")
        #expect(WorkDay().phase(at: saturday, calendar: calendar) == .off)
        #expect(WorkDay(weekends: true).progress(at: saturday, calendar: calendar) > 0.3)
    }

    @Test func nightShiftWrapsPastMidnight() {
        let night = WorkDay(start: 22 * 60, end: 6 * 60)
        let calendar = UTC.calendar
        #expect(night.length == 480)
        #expect(night.progress(at: UTC.date("2026-10-28 02:00"), calendar: calendar) == 0.5)
        #expect(night.phase(at: UTC.date("2026-10-28 23:00"), calendar: calendar) == .during(done: 0.125))
        #expect(night.phase(at: UTC.date("2026-10-28 12:00"), calendar: calendar) == .before)
    }

    @Test func clockAndDuration() {
        #expect(WorkDay.clock(9 * 60 + 5) == "09:05")
        #expect(WorkDay.clock(24 * 60 + 30) == "00:30")
        #expect(WorkDay.duration(190) == "3 h 10 min")
        #expect(WorkDay.duration(120) == "2 h")
        #expect(WorkDay.duration(45) == "45 min")
    }

    // MARK: Notes

    @Test func noteTitleAndPreview() {
        #expect(NoteNaming.title(of: "\n\n## Groceries  \n- milk\n- bread") == "Groceries")
        #expect(NoteNaming.title(of: "   \n") == "")
        #expect(NoteNaming.preview(of: "# Groceries\n- milk\n\n- bread") == "- milk - bread")
        let long = String(repeating: "a", count: 80)
        #expect(NoteNaming.title(of: long).count == 60)
    }

    @Test func noteFileNames() {
        #expect(NoteNaming.safeName("Plan: Q1/Q2 *draft*") == "Plan Q1 Q2 draft")
        #expect(NoteNaming.safeName("..hidden") == "hidden")
        #expect(NoteNaming.safeName("###") == "")
        #expect(NoteNaming.unique("Groceries", taken: ["groceries", "Groceries 2"]) == "Groceries 3")
        #expect(NoteNaming.unique("Ideas", taken: ["Groceries"]) == "Ideas")
        let placeholder = NoteNaming.placeholder(created: UTC.date("2026-10-28 14:32"), calendar: UTC.calendar)
        #expect(placeholder == "Note 2026-10-28 1432")
        #expect(NoteNaming.isPlaceholder(placeholder))
        #expect(NoteNaming.isPlaceholder(placeholder + " 2"))
        #expect(!NoteNaming.isPlaceholder("Note to self"))
    }

    // MARK: Health

    @Test func ouraLatestScore() {
        let json = """
        {"data":[{"id":"a","day":"2026-10-27","score":78},{"id":"b","day":"2026-10-28","score":84},
                 {"id":"c","day":"2026-10-29","score":null}],"next_token":null}
        """
        let latest = OuraAPI.latestScore(Bytes.data(json))
        #expect(latest?.day == "2026-10-28" && latest?.score == 84)
        #expect(OuraAPI.latestScore(Bytes.data("{\"data\":[]}")) == nil)
        let url = OuraAPI.url("daily_sleep", from: "2026-10-26", to: "2026-10-29").absoluteString
        #expect(url == "https://api.ouraring.com/v2/usercollection/daily_sleep?start_date=2026-10-26&end_date=2026-10-29")
    }

    @Test func whoopRecoveryAndSleep() {
        let recovery = """
        {"records":[{"cycle_id":1,"created_at":"2026-10-28T06:25:44.774Z","score_state":"PENDING_SCORE"},
                    {"cycle_id":2,"created_at":"2026-10-27T06:25:44.774Z","score_state":"SCORED",
                     "score":{"user_calibrating":false,"recovery_score":71.6,"resting_heart_rate":52,"hrv_rmssd_milli":68.2}}]}
        """
        let parsed = WhoopAPI.parseRecovery(Bytes.data(recovery))
        #expect(parsed?.recovery == 72 && parsed?.restingHeartRate == 52 && parsed?.day == "2026-10-27")
        let sleep = """
        {"records":[{"id":"n","nap":true,"score_state":"SCORED","score":{"sleep_performance_percentage":40}},
                    {"id":"s","nap":false,"score_state":"SCORED","score":{"sleep_performance_percentage":91}}]}
        """
        #expect(WhoopAPI.parseSleep(Bytes.data(sleep)) == 91)
    }

    @Test func whoopTokenAndRequests() {
        let now = UTC.date("2026-10-28 06:00")
        let token = WhoopAPI.parseToken(Bytes.data(#"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"bearer"}"#), now: now)
        #expect(token?.access == "a" && token?.refresh == "r")
        #expect(token?.isValid(at: now.addingTimeInterval(3000)) == true)
        #expect(token?.isValid(at: now.addingTimeInterval(3570)) == false)
        let url = WhoopAPI.authorize(clientID: "id 1", redirect: "starnotch://oauth/whoop", state: "abcdefgh", challenge: "xyz").absoluteString
        #expect(url.hasPrefix("https://api.prod.whoop.com/oauth/oauth2/auth?"))
        #expect(url.contains("code_challenge_method=S256") && url.contains("state=abcdefgh") && url.contains("client_id=id%201"))
        let body = Bytes.string(WhoopAPI.tokenBody(code: "c/1", verifier: "v", clientID: "id", secret: nil, redirect: "starnotch://oauth/whoop"))
        #expect(body == "grant_type=authorization_code&code=c%2F1&code_verifier=v&client_id=id&redirect_uri=starnotch%3A%2F%2Foauth%2Fwhoop")
    }

    @Test func pkceChallengeMatchesSHA256() {
        // Computed with: printf '<verifier>' | openssl dgst -sha256 -binary | base64 (url-safe, unpadded).
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mJ92K9TJM2-91Tr3yO3lEf_9vkj0gk") == "UiYjBpzM6bB43u5TOoO-2B9qB6PGcqLpuZKPpsdQzEI")
        let verifier = PKCE.verifier()
        #expect(verifier.count == 43 && !verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
        #expect(PKCE.state().count >= 8)
    }

    @Test func healthLinesAndLevels() {
        let now = UTC.date("2026-10-28 06:00")
        let oura = HealthDay(source: .oura, day: "2026-10-28", sleep: 84, readiness: 80, fetched: now)
        #expect(oura.line == "Readiness 80 · Sleep 84")
        #expect(oura.headline == 80 && oura.headlineTitle == "Readiness")
        let whoop = HealthDay(source: .whoop, day: "2026-10-28", sleep: 91, recovery: 72, fetched: now)
        #expect(whoop.line == "Recovery 72 % · Sleep 91 %")
        #expect(whoop.headlineTitle == "Recovery")
        #expect(HealthDay.level(72, source: .whoop) == .good)
        #expect(HealthDay.level(40, source: .whoop) == .fair)
        #expect(HealthDay.level(80, source: .oura) == .fair)
        #expect(HealthDay.level(60, source: .oura) == .low)
    }

    @Test func morningLineOncePerDayFromFive() {
        let calendar = UTC.calendar
        #expect(!MorningLine.isDue(lastShown: nil, now: UTC.date("2026-10-28 04:59"), calendar: calendar))
        #expect(MorningLine.isDue(lastShown: "2026-10-27", now: UTC.date("2026-10-28 07:10"), calendar: calendar))
        #expect(!MorningLine.isDue(lastShown: "2026-10-28", now: UTC.date("2026-10-28 09:00"), calendar: calendar))
    }

    // MARK: Settings

    @Test func dailySettingsDecodeTolerantly() throws {
        let settings = try DailySettingsCodec.decode(#"{"weatherInEar":true,"unit":"kelvin","workDay":{"start":480,"end":1020,"weekends":false}}"#)
        #expect(settings.weatherInEar)
        #expect(settings.unit == .celsius)
        #expect(settings.workDay.start == 480)
        #expect(settings.morningLine)
        #expect(settings.healthSource == nil)
    }

    @Test func dailyToolsStartOffAndLiveWhereTheyBelong() {
        let settings = SwitcherSettings()
        for feature in [ToolFeature.weather, .dayProgress, .notes, .health] { #expect(!ToolSwitches.isOn(feature, in: settings)) }
        #expect(ToolFeature.notes.module == .tools)
        #expect(ToolFeature.weather.module == nil && ToolFeature.health.module == nil)
        var switched = SwitcherSettings()
        ToolSwitches.set(.notes, on: true, in: &switched)
        #expect(!switched.disabledModules.contains(.tools))
        #expect(!ToolSwitches.isOn(.clipboard, in: switched))
    }
}
