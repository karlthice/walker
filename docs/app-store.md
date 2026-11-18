# App Store submission notes

Everything App Store Connect asks for, drafted. Text in [brackets] needs your input.

## Still to do by hand

1. **Publish the privacy policy and a support page** on kringum.is, e.g. `https://kringum.is/walker/privacy` and `https://kringum.is/walker` [use whatever paths you choose, and put the same ones in App Store Connect and in the policy's contact line].
2. **Create the app record** in App Store Connect with the name **Walker - Explore your city** and bundle ID `com.karlthice.walker`. The name must be unique on the App Store; you'll find out when you create the record. Under the icon on the home screen the app stays "Walker" (`CFBundleDisplayName`).
3. **Bump the build number** (`CFBundleVersion` in `project.yml`, now 1) on every upload; the version is 1.0.
4. **Archive and upload** from Xcode (Product → Archive → Distribute App), then test through TestFlight on a real phone for a few days before submitting.
5. **Take screenshots** on a 6.9-inch iPhone (or its simulator) [check the current required sizes in App Store Connect].

## Already handled in the app

- Privacy manifest (`Walker/Resources/PrivacyInfo.xcprivacy`): no tracking, no collected data; UserDefaults declared with reason CA92.1.
- `ITSAppUsesNonExemptEncryption` is false, so uploads skip the export compliance question.
- A welcome screen explains the fog and why "Always" location is needed before iOS asks.
- Delete All Data in Settings.
- Credits for Natural Earth and OpenStreetMap in Settings; OpenStreetMap credit under each city list.

## Listing

**Name** (30 characters max): Walker - Explore your city

**Privacy policy URL:** [https://kringum.is/walker/privacy]

**Support URL:** [https://kringum.is/walker]

**Subtitle** (30 characters max): Clear the fog by exploring

**Primary category:** Travel. **Secondary:** Navigation.

**Age rating:** 4+ (no objectionable content; the only photos shown are your own).

**Keywords** (100 characters max, comma separated; the words in the name are already searched, so they aren't repeated here):
fog,map,walking,travel,countries,exploration,streets,discover,trip,wander,neighborhood,hiking,urban

**Promotional text** (can be changed without a new release):
See how much of your city you have really explored. Walk anywhere and the fog lifts behind you.

**Description:**

The map starts covered in fog. Wherever you walk, it lifts – street by street – leaving a picture of everywhere you have been.

Walker works in the background, so the fog clears on your commute, your walks and your travels without opening the app. Later, open the map to see the places you have uncovered, and the corners of your own neighbourhood you have never seen.

• A fog map of everywhere you go, down to single streets
• Stats for today, this week and this month, and new area per day
• How much of each country you have explored
• Over 300 major cities around the world, with the share of each you have uncovered
• Your photos on the map, where you took them
• Your raw path, fading by age

Private by design: your tracks and photos never leave your iPhone. No account, no ads, no tracking. Country and city boundaries are built into the app, so nothing about where you go is looked up online.

Walker uses your location in the background to clear the fog while the app is closed.

## App Privacy (the privacy label)

Answer **"No, we do not collect data from this app."** That results in **Data Not Collected**. This holds because nothing leaves the device: locations, the explored grid and photo locations stay in the app's own storage, and Apple Maps tiles are fetched by MapKit (Apple), not sent to you.

## Notes for App Review

> Walker draws a fog over the map and clears it wherever the user goes. It needs background location ("Always") so the fog clears while the app is closed; this is the app's core feature and is explained on the welcome screen before iOS asks. All data stays on the device: there is no account, no server and no network use other than Apple Maps tiles.
>
> To try it: allow location access, then walk or drive a short distance (or simulate a route in Xcode); the fog lifts along the path. The Stats tab shows explored area by day, country and city. The photo button on the map asks for Photos access and shows the user's photos where they were taken. The gear button opens Settings, including Delete All Data.
>
> No login is needed.

Also attach a short screen recording showing the fog clearing on a real walk, which helps with the background location review.
