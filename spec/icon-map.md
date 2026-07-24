# Icon Map — Lucide → SF Symbols / Material Symbols

**Status:** Layer-0 spec (plan §7 note). Covers every icon name that appears in the
system prompt (`src/genos/generated/system-prompt.ts`), the contract descriptions
(`ui/contract.tsx`), `apps.ts`, and the shell/renderer code. Proposed equivalents are
for SwiftUI (`Image(systemName:)`, SF Symbols 5+) and Compose
(Material Symbols, rounded/filled per design language). Names marked ⚠ have no exact
counterpart — the listed symbol is the recommended nearest match; revisit in Phase 3/6.

## 1. How icon names flow through the system

The model emits **Lucide kebab-case names** as plain strings in three prop slots:
`ListItem.leading` (string variant), `Toggle.icon`, `StatTiles.items[].icon`.
The renderer resolves them via `LucideIcon` (`ui/icons.tsx`):

1. `kebabToPascal`: trim, split on `[-_ ]+`, capitalize each word, join —
   `"credit-card"` → `CreditCard`, so `credit_card` and `credit card` also resolve.
2. Look up that export in `lucide-react-native`.

### Unknown-name degradation (must be reproduced)

If the lookup fails, the renderer draws a **placeholder dot**: an 8×8 view,
`borderRadius 4`, background = the caller-passed tint color, `opacity 0.6`.
No error, no fallback glyph, no text. Native ports MUST degrade to an equivalent
neutral dot (or design-approved placeholder), never crash or hide the row.
*Source: `ui/icons.tsx` `LucideIcon`.*

### Badge tinting (must be ported byte-exact)

`iconTint(name)`: lower-case the name; if in the hand-picked table below, use that
color; otherwise hash `h = (h * 31 + charCodeAt(i)) | 0` (32-bit signed overflow
semantics) over the lower-cased name and pick `BADGE_COLORS[abs(h) % 9]`.

`BADGE_COLORS` (in order): `#0a84ff` `#34c759` `#ff9f0a` `#af52de` `#ff3b30`
`#5ac8fa` `#5e5ce6` `#ff2d55` `#30b0c7`.

Hand-picked tints: wifi `#0a84ff`, bluetooth `#0a84ff`, plane `#ff9f0a`,
battery-full `#34c759`, battery `#34c759`, battery-charging `#34c759`,
moon `#5e5ce6`, bell `#ff3b30`, bell-ring `#ff3b30`, heart `#ff2d55`,
heart-pulse `#ff2d55`, flame `#ff9f0a`, credit-card `#34c759`, wallet `#34c759`,
map-pin `#ff3b30`, music `#ff2d55`, camera `#8e8e93`, settings `#8e8e93`,
lock `#8e8e93`, shield-check `#34c759`, sun `#ff9f0a`, cloud-rain `#5ac8fa`,
cloud `#5ac8fa`, droplets `#5ac8fa`, wind `#30b0c7`, message-circle `#34c759`,
phone `#34c759`, mail `#0a84ff`, calendar `#ff3b30`, clock `#ff9f0a`,
alarm-clock `#ff9f0a`, volume-2 `#ff2d55`.
*Source: `ui/icons.tsx` `ICON_TINT`, `BADGE_COLORS`, `iconTint`.*

## 2. Model-facing icon vocabulary (the prompt's "reliable names", 73)

These are the names the system prompt explicitly promises. Native renderers MUST
resolve all 73.

| Lucide (prompt) | SF Symbol | Material Symbol |
|---|---|---|
| `wifi` | `wifi` | `wifi` |
| `bluetooth` | ⚠ `wave.3.right` (no Bluetooth mark in SF Symbols — consider custom asset) | `bluetooth` |
| `signal` | `cellularbars` | `signal_cellular_alt` |
| `moon` | `moon.fill` | `dark_mode` |
| `sun` | `sun.max.fill` | `light_mode` |
| `sun-dim` | `sun.min.fill` | `brightness_low` |
| `battery-full` | `battery.100percent` | `battery_full` |
| `hard-drive` | `internaldrive.fill` | `hard_drive` |
| `bell` | `bell.fill` | `notifications` |
| `lock` | `lock.fill` | `lock` |
| `shield-check` | `checkmark.shield.fill` | `verified_user` |
| `map-pin` | `mappin` | `location_on` |
| `navigation` | `location.north.fill` | `navigation` |
| `plane` | `airplane` | `flight` |
| `train` | `tram.fill` | `train` |
| `bus` | `bus.fill` | `directions_bus` |
| `car` | `car.fill` | `directions_car` |
| `utensils` | `fork.knife` | `restaurant` |
| `coffee` | `cup.and.saucer.fill` | `local_cafe` |
| `pizza` | ⚠ `takeoutbag.and.cup.and.straw.fill` (no pizza in SF) | `local_pizza` |
| `wine` | `wineglass.fill` | `wine_bar` |
| `cake` | `birthday.cake.fill` | `cake` |
| `dumbbell` | `dumbbell.fill` | `fitness_center` |
| `heart-pulse` | `waveform.path.ecg` | `monitor_heart` |
| `flame` | `flame.fill` | `local_fire_department` |
| `footprints` | `shoeprints.fill` | `footprint` |
| `credit-card` | `creditcard.fill` | `credit_card` |
| `banknote` | `banknote.fill` | `payments` |
| `piggy-bank` | ⚠ `banknote.fill` (no piggy bank in SF) | `savings` |
| `wallet` | `wallet.pass.fill` | `wallet` |
| `receipt` | `receipt` | `receipt_long` |
| `trending-up` | `chart.line.uptrend.xyaxis` | `trending_up` |
| `trending-down` | `chart.line.downtrend.xyaxis` | `trending_down` |
| `arrow-up-right` | `arrow.up.right` | `north_east` |
| `arrow-down-right` | `arrow.down.right` | `south_east` |
| `calendar` | `calendar` | `calendar_today` |
| `clock` | `clock.fill` | `schedule` |
| `alarm-clock` | `alarm.fill` | `alarm` |
| `music` | `music.note` | `music_note` |
| `headphones` | `headphones` | `headphones` |
| `mic` | `mic.fill` | `mic` |
| `play` | `play.fill` | `play_arrow` |
| `camera` | `camera.fill` | `photo_camera` |
| `image` | `photo.fill` | `image` |
| `film` | `film` | `movie` |
| `message-circle` | `message.fill` | `chat_bubble` |
| `phone` | `phone.fill` | `call` |
| `mail` | `envelope.fill` | `mail` |
| `send` | `paperplane.fill` | `send` |
| `user` | `person.fill` | `person` |
| `users` | `person.2.fill` | `group` |
| `home` | `house.fill` | `home` |
| `building` | `building.2.fill` | `apartment` |
| `star` | `star.fill` | `star` |
| `gift` | `gift.fill` | `redeem` |
| `search` | `magnifyingglass` | `search` |
| `settings` | `gearshape.fill` | `settings` |
| `zap` | `bolt.fill` | `bolt` |
| `cloud` | `cloud.fill` | `cloud` |
| `cloud-rain` | `cloud.rain.fill` | `rainy` |
| `snowflake` | `snowflake` | `ac_unit` |
| `wind` | `wind` | `air` |
| `droplets` | `drop.fill` | `water_drop` |
| `thermometer` | `thermometer.medium` | `device_thermostat` |
| `umbrella` | `umbrella.fill` | `umbrella` |
| `leaf` | `leaf.fill` | `eco` |
| `package` | `shippingbox.fill` | `package_2` |
| `shopping-bag` | `bag.fill` | `shopping_bag` |
| `shopping-cart` | `cart.fill` | `shopping_cart` |
| `truck` | `truck.box.fill` | `local_shipping` |
| `book` | `book.fill` | `menu_book` |
| `pen` | `pencil` | `edit` |
| `notebook` | `book.closed.fill` | ⚠ `auto_stories` |

All names used in the prompt's four worked examples (`wifi`, `bluetooth`, `signal`,
`moon`, `sun-dim`, `sun`, `hard-drive`, `battery-full`, `coffee`, `banknote`,
`music`, `arrow-down-right`, `piggy-bank`) are members of this list.
Contract descriptions cite `wifi` and `credit-card` (also members).

## 3. Additional names the RN app special-cases (`ICON_TINT` extras)

Not promised by the prompt, but tinted deliberately — the model may plausibly emit
them, so native ports should map them too:

| Lucide | SF Symbol | Material Symbol |
|---|---|---|
| `battery` | `battery.75percent` | `battery_std` |
| `battery-charging` | `battery.100percent.bolt` | `battery_charging_full` |
| `bell-ring` | `bell.badge.fill` | `notifications_active` |
| `heart` | `heart.fill` | `favorite` |
| `volume-2` | `speaker.wave.2.fill` | `volume_up` |

Any other valid Lucide name still resolves in the RN app (the whole Lucide set is
bundled). Native ports are NOT required to ship the full Lucide catalogue: map the
tables above; everything else degrades per §1 (dot placeholder). This is a deliberate
narrowing — record additions here as fixtures surface them.

## 4. Hard-coded chrome & renderer icons (Lucide, app-internal)

Emitted by AppLess code, never by the model:

| Lucide | Where | SF Symbol | Material Symbol |
|---|---|---|---|
| `chevron-left` | back button (stack > 1), GenOS chrome | `chevron.left` | `arrow_back_ios_new` |
| `house` | home button (stack = 1), GenOS chrome | `house.fill` | `home` |
| `chevron-right` | ListItem action affordance | `chevron.right` | `chevron_right` |
| `chevron-down` | Material Select trigger | `chevron.down` | `expand_more` |
| `chevrons-up-down` | Cupertino Select trigger | `chevron.up.chevron.down` | `unfold_more` |
| `check` | Select option checkmark, Material Chips | `checkmark` | `check` |
| `info` | TextCallout `neutral` / `info` | `info.circle.fill` | `info` |
| `circle-check` | TextCallout `success` | `checkmark.circle.fill` | `check_circle` |
| `triangle-alert` | TextCallout `warning` | `exclamationmark.triangle.fill` | `warning` |
| `octagon-alert` | TextCallout `danger` | `exclamationmark.octagon.fill` | `report` |

Plus one custom-drawn glyph: **AppsIcon** (app switcher — two overlapping rounded
squares, `ui/icons.tsx`). Suggested: SF `square.on.square` / Material `select_window`
— or redraw the two-square shape for exact parity.

## 5. Home-shell tile & suggestion icons (Phosphor, filled weight)

`shell/HomeScreen.tsx` uses `phosphor-react-native` (weight `fill`) for app tiles,
keyword-matched summon tiles, and suggestion rows — a different icon family from the
model-facing Lucide set. Mapping for the native shells:

| Phosphor | Used for | SF Symbol | Material Symbol |
|---|---|---|---|
| `ChatCircle` | 💬 Messages tile, "Text Maya" | `message.fill` | `chat_bubble` |
| `BowlFood` | 🍜 Food tile, "Order dinner" | ⚠ `fork.knife` | `ramen_dining` |
| `Barbell` | 💪 Fitness tile | `dumbbell.fill` | `fitness_center` |
| `CreditCard` | 💳 Banking tile, "My spending" | `creditcard.fill` | `credit_card` |
| `AirplaneTilt` | ✈️ Flights tile, "Weekend in Goa" | `airplane.departure` | `flight_takeoff` |
| `CalendarBlank` | 📅 Calendar tile, "My day" | `calendar` | `calendar_today` |
| `MusicNote` | 🎵 Music tile, "Play something" | `music.note` | `music_note` |
| `SunHorizon` | 🌅 Photos tile | `sun.horizon.fill` | `wb_twilight` |
| `Coffee` | ☕ keyword, "Coffee nearby" | `cup.and.saucer.fill` | `local_cafe` |
| `CloudSun` | ⛅ Weather tile | `cloud.sun.fill` | `partly_cloudy_day` |
| `NotePencil` | 📝 Notes tile, "New note" | `square.and.pencil` | `edit_note` |
| `MapTrifold` | 🗺️ Maps tile | `map.fill` | `map` |
| `GearSix` | ⚙️ Settings tile | `gearshape.fill` | `settings` |
| `PersonSimpleRun` | 🏃 keyword, "My workouts" | `figure.run` | `directions_run` |
| `Camera` | photo keyword | `camera.fill` | `photo_camera` |
| `ShoppingCart` | shopping keyword | `cart.fill` | `shopping_cart` |
| `Heartbeat` | health keyword | `waveform.path.ecg` | `monitor_heart` |
| `GameController` | game keyword | `gamecontroller.fill` | `sports_esports` |
| `Book` | reading keyword | `book.fill` | `menu_book` |
| `Car` | ride keyword | `car.fill` | `directions_car` |
| `Globe` | news keyword | `globe` | `public` |
| `Sparkle` | summoned-app fallback | `sparkles` | `auto_awesome` |
| `ArrowUp` | ask-bar submit button | `arrow.up` | `arrow_upward` |

The emoji→icon and keyword-regex→icon selection logic (`TILE_ICONS`,
`KEYWORD_ICONS`, `tileIconFor`, `oneWordName`) is shell behavior, spec'd by the
source in `shell/HomeScreen.tsx`; port the tables and regex order verbatim.
