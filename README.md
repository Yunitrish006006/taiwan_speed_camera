# Taiwan Speed Camera

Flutter driving-session module for Taiwan Brawl. Embed
`SpeedCameraPage(apiBaseUrl: ...)` and pin this package to a reviewed commit.
The app owns routing and supplies the dataset API base URL. Only catalog
requests use the network. Location and trip alert state stay on the device.

The module uses NPA open data [dataset 7320](https://data.gov.tw/dataset/7320).
Location and source compass labels narrow down candidates. Nearby parallel
roads, ramps, elevated roads and carriageways still require verified road
geometry and road matching. Unknown source directions are shown as candidates
without voice alerts.

## Host setup

- Android manifest needs coarse and fine location plus `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_LOCATION` for the user-started foreground service. The
  Geolocator plugin declares the service. Declare an Android TTS service query
  for package visibility.
- iOS Info.plist needs `NSLocationWhenInUseUsageDescription` and
  `UIBackgroundModes` including `location`. Tracking starts while the UI is
  visible. Lock-screen continuation is opt-in before each page's driving session.
- Web requires a secure context for geolocation. It provides foreground
  candidates. Native voice and background tracking require Android or iOS.

Run `flutter analyze` and `flutter test` from the package root.

A host can inject a `SpeedCameraRoadMatcher` built with a local road graph and
reviewed camera-to-carriageway bindings. The matcher scores cross-track
distance and heading, and abstains when roads overlap or GPS uncertainty
allows multiple plausible roads. Without a graph, the app still reports
location and direction candidates. The current Taiwan Brawl dataset
integration supplies no road bindings.
