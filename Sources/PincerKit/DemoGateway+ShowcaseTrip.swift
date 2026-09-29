import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Demo showcase: the Japan trip chat.
extension DemoGateway {
    // MARK: Demo showcase: Japan trip

    /// 151 exchanges: early planning cycles through a few ideas; the latest 60 (one history page) walk the
    /// actual route, so Find in Chat has real hits for "onsen", "Kyoto" and "ramen".
    static func seedTripTranscript() -> [JSONValue] {
        let ideas: [(ask: String, answer: String)] = [
            ("Another idea for a slow morning?", "a stroll through Yanaka's old lanes, with coffee at a sentō turned café"),
            ("Something for a rainy afternoon?", "a depachika food-hall crawl, sampling as you go"),
            ("Any good neighbourhoods for wandering?", "Kagurazaka's stone alleys, then dinner at a small French-Japanese bistro"),
            ("What about something outdoorsy?", "the Mount Takao hike, with soba at the top"),
            ("A cheap dinner idea?", "a late bowl of ramen at a counter near the hotel"),
            ("Somewhere for a view?", "Shibuya Sky around sunset — book the slot a week out"),
            ("A museum we shouldn't miss?", "the Ghibli Museum, if we can get tickets on the 10th of the month before"),
        ]
        var messages: [JSONValue] = []
        // Planned over about a month, newest a minute ago, so search results show realistic dates.
        let pairs = 91 + Self.tripRoute.count
        func pair(_ user: String, _ assistant: String, assistantId: String? = nil) {
            let ago = Double(pairs - 1 - messages.count / 2) * 5 * 3600 + 60
            messages.append(Self.message("user", [Self.text(user)], ago: ago + 60))
            messages.append(Self.message("assistant", [Self.text(assistant)], id: assistantId, ago: ago))
        }
        for index in 0..<91 {
            let idea = ideas[index % ideas.count]
            pair(idea.ask, "Idea #\(index + 1): \(idea.answer).")
        }
        for (user, assistant) in Self.tripRoute {
            pair(user, assistant, assistantId: user == DemoBookmarks.tripQuestion ? DemoBookmarks.tripMessageId : nil)
        }
        return messages
    }

    static let tripRoute: [(String, String)] = [
        ("Flights are booked — we land at Haneda at 6:40 am on the 3rd.",
         "Nice, an early arrival gives you a full first day. Pick up a Suica card at the airport for trains and konbini."),
        ("How do we get from Haneda to the hotel in Asakusa?",
         "The Keikyu line runs straight through to Asakusa in about 40 minutes, no transfers. Try to beat the 8 am rush."),
        ("Can we check in that early?",
         "Probably not before 3 pm, but the hotel will hold your bags. Drop them and head out light."),
        ("What should the first morning look like?",
         "Keep it easy: Sensō-ji before the crowds, melon pan on Nakamise-dōri, then a nap if the jet lag hits."),
        ("Is Tsukiji still worth it for breakfast?",
         "Yes — the wholesale market moved to Toyosu, but Tsukiji's outer market is still great in the morning: tamagoyaki, grilled scallops and a small bowl of fresh tuna over rice."),
        ("What time should we get there?",
         "Around 7:30. Most stalls open at 7 and the lanes are packed by 10."),
        ("Any tips for eating at the market?",
         "Carry cash and coins, eat at the stall where you buy, and don't eat while walking — there are usually standing spots."),
        ("Afternoon on day two?",
         "Walk from Tsukiji to Ginza, then take the Hibiya line up to Ueno Park for the museums if you still have energy."),
        ("We want one really good bowl of ramen in Tokyo.",
         "Try a shoyu counter in Ebisu, or the tsukemen shops on Tokyo Station's underground Ramen Street. Expect a queue at lunch; evenings are calmer."),
        ("Do we need reservations for dinner in Shibuya?",
         "For izakaya, usually not. For sushi counters and anywhere with fewer than ten seats, book a week or two ahead."),
        ("Is teamLab worth the ticket?",
         "If you like immersive art, yes. Book an early-evening slot and wear shorts — some rooms have ankle-deep water."),
        ("A rainy-day backup in Tokyo?",
         "The Tokyo National Museum, or an afternoon in Jimbōchō's secondhand bookshops."),
        ("Should we get the JR Pass?",
         "Probably not since the price went up. For Tokyo → Hakone → Kyoto → Osaka → Tokyo, single tickets come out a little cheaper."),
        ("How much would single tickets cost?",
         "Roughly ¥14,000 each for the long Shinkansen leg, plus local trains. I'll make a table once the dates are fixed."),
        ("Let's add a night in Hakone.",
         "Good call. It's 85 minutes from Shinjuku on the Romancecar, and one night is enough for the loop and a long soak."),
        ("Find us a ryokan with a private onsen.",
         "Look for rooms with an open-air bath of their own. Gōra and Sengokuhara have several in a mid-range budget, and dinner and breakfast are usually included."),
        ("Any onsen etiquette we should know?",
         "Wash thoroughly at the shower stools first, keep the small towel out of the water, and tie up long hair. Shared onsen can be strict about tattoos — another reason to book a private one."),
        ("What's the Hakone loop?",
         "Romancecar to Hakone-Yumoto, the switchback train to Gōra, cable car and ropeway over Ōwakudani, then a boat across Lake Ashi. It fills most of a day."),
        ("Will we see Mount Fuji?",
         "Only on clear days, and mornings are your best bet. Check the live cameras before heading up the ropeway."),
        ("What's a kaiseki dinner like?",
         "A long run of small seasonal courses, served in your room or a private dining room. Mention allergies when you book — they plan the menu ahead."),
        ("Can we send our big bags ahead?",
         "Yes, with takkyūbin from the hotel front desk. Send them two days early and they'll be waiting at the next hotel."),
        ("Hakone onward — what's the route west?",
         "Bus down to Odawara, then the Hikari Shinkansen. About two and a half hours door to door."),
        ("Which side of the Shinkansen has the Fuji view?",
         "Heading west, the right side — seat E in ordinary cars. The view only lasts a few minutes around Shin-Fuji."),
        ("Should we reserve seats?",
         "Yes, it's autumn. Reserved seats are cheap insurance, and oversized-luggage seats must be booked if you keep a big bag."),
        ("What should we grab for the train?",
         "An ekiben from Odawara station — aji sushi is the local speciality. Eating on the Shinkansen is completely normal."),
        ("Where should we stay in Kyoto?",
         "Near Shijō or Karasuma Oike: central, walkable to Gion, and on the subway line to the station."),
        ("Fushimi Inari at dawn — worth the early alarm?",
         "Absolutely. At 6 am the torii tunnels are nearly empty and the light is soft. Climb at least to Yotsutsuji for the view over the city."),
        ("How long is the full hike?",
         "Two to three hours to the summit and back. Most people turn around at Yotsutsuji, about 45 minutes up."),
        ("Breakfast after the shrine?",
         "Little is open at 8 am nearby, so bring onigiri from a konbini or ride one stop back toward the station."),
        ("Arashiyama bamboo grove — morning or afternoon?",
         "Morning, before 8 if you can; after that it's shoulder to shoulder. Pair it with Tenryū-ji's garden, which opens at 8:30."),
        ("What else is in Arashiyama?",
         "The Togetsukyō bridge, a riverside walk, the monkey park on the hill, and Ōkōchi Sansō villa, where matcha and a sweet come with admission."),
        ("Can we fit in a tea ceremony?",
         "Yes — small hosted ceremonies in Gion run about an hour. Book a morning slot and bring socks."),
        ("Where should we eat in Gion?",
         "Walk Pontochō at dusk and pick somewhere with a menu out front. For something special, book an obanzai counter a few days ahead."),
        ("Is Kinkaku-ji worth the crowds?",
         "It's busy but beautiful. Go right at opening, then walk on to Ryōan-ji's rock garden."),
        ("How do we get around between temples?",
         "Buses cover everything but get slow and packed. Mix the subway with taxis for short hops — they're reasonable split two ways."),
        ("Day trip to Nara?",
         "Easy: the Kintetsu line takes about 45 minutes from Kyoto. Tōdai-ji, the deer park and Kasuga Taisha fit in a relaxed half day."),
        ("Are the Nara deer friendly?",
         "Mostly, but they're bold. Buy shika senbei, bow and they'll often bow back, and keep the crackers hidden until you're ready — they nibble maps."),
        ("What should we eat in Nara?",
         "Kakinoha-zushi wrapped in persimmon leaves, and a mochi from Nakatanidō, where they pound it at startling speed."),
        ("Then on to Osaka?",
         "Yes, Nara to Namba is about 40 minutes. Staying there puts you right by Dōtonbori."),
        ("Best takoyaki in Osaka?",
         "Try a few stands along Dōtonbori and compare — crisp outside, molten inside. Give them a minute to cool."),
        ("And ramen in Osaka?",
         "Look for a rich tonkotsu or a light shio ramen around Namba. Many shops use ticket machines, so keep ¥1,000 notes handy."),
        ("What's okonomiyaki?",
         "A savoury cabbage pancake cooked on a griddle at your table. Osaka style is mixed; Hiroshima style is layered with noodles."),
        ("Is Osaka Castle worth visiting?",
         "The park and moat are lovely; the museum inside is modern. It makes a nice morning walk."),
        ("Should we do Universal Studios?",
         "Only if Super Nintendo World is a must — it's a full day with timed entry. Otherwise spend it in Shinsekai and Kuromon market."),
        ("What's good at Kuromon?",
         "Wagyu skewers, uni, strawberries on sticks and fresh oysters. It's pricier than it looks, so set a budget."),
        ("How do we get back to Tokyo at the end?",
         "Nozomi from Shin-Osaka, about two and a half hours. Book early afternoon so the last day isn't rushed."),
        ("Last night in Tokyo — anything special?",
         "A slow dinner in Shimokitazawa, then a nightcap in a tiny Golden Gai bar. Many charge a small seat fee."),
        ("Could we squeeze in one more onsen in Tokyo?",
         "A neighbourhood sentō or a big spa complex works for a quick soak, but nothing will match the Hakone ryokan."),
        ("Help me with a packing list.",
         "Layers for warm days and cool nights, slip-on shoes for temples, a small towel, a coin purse, a power bank and a foldable bag for souvenirs."),
        ("Do we need much cash?",
         "Some. Cards work in cities, but shrines, markets and small restaurants often want cash. 7-Eleven ATMs take foreign cards."),
        ("SIM or pocket Wi-Fi?",
         "An eSIM is easiest — install it before you fly and switch it on when you land. 20 GB is plenty for two weeks of maps."),
        ("Any apps we should install?",
         "A transit app for platforms and transfers, a maps app for walking, and a translator with camera mode for menus."),
        ("How does tipping work?",
         "It doesn't — there's no tipping. A sincere thank-you is all that's expected."),
        ("What should we bring back as gifts?",
         "Tea from Uji, a kitchen knife from Sennichimae Dōguyasuji, and boxed sweets from any station — they're beautifully wrapped."),
        ("Recap the route for me?",
         "Tokyo (4 nights) → Hakone (1) → Kyoto (4) → Osaka (2) → Tokyo (1). Twelve nights and two long Shinkansen legs."),
        ("Is that too much moving around?",
         "It's comfortable: three hotel changes plus the ryokan, with bags sent ahead twice. Most transfers are just a day pack."),
        ("What if it rains on our Hakone day?",
         "Skip the ropeway and linger in the onsen — rain on an open-air bath is lovely. Do the loop the next morning if it clears."),
        ("Rough budget per day?",
         "Around ¥25,000 each, not counting hotels: food, transport, temples and a little shopping. The ryokan night is the splurge."),
        ("Can you draft our first full day in Kyoto?",
         "Sure — an early start, the big sights before lunch, and an unhurried afternoon."),
        ("Go ahead, lay it out.",
         """
         ## Kyoto, day one

         - **6:00** Fushimi Inari before the crowds; turn back at Yotsutsuji.
         - **9:30** Kiyomizu-dera, then down the Sannenzaka and Ninenzaka lanes.
         - **12:30** Yudōfu lunch near Nanzen-ji.
         - **14:00** Rest at the hotel.
         - **16:30** The Philosopher's Path to Ginkaku-ji.
         - **19:00** Dinner in Pontochō, by the river.
         """),
    ]

    /// A small bar chart, drawn rather than bundled so the demo needs no assets.
    static func chartPNG() -> Data {
        let (width, height) = (640, 400)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let values: [CGFloat] = [0.46, 0.02, 0.31, 0.64, 0.18, 0.52]
        let slot = CGFloat(width - 80) / CGFloat(values.count)
        for (index, value) in values.enumerated() {
            let hue = CGFloat(index) / CGFloat(values.count)
            context.setFillColor(CGColor(red: 0.95 - hue * 0.5, green: 0.35 + hue * 0.4, blue: 0.30 + hue * 0.6, alpha: 1))
            let barHeight = max(6, value * CGFloat(height - 80))
            context.fill(CGRect(x: 40 + CGFloat(index) * slot + slot * 0.15, y: 40, width: slot * 0.7, height: barHeight))
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        context.fill(CGRect(x: 40, y: 38, width: width - 80, height: 2))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
