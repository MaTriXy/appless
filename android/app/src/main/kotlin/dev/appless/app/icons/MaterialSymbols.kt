package dev.appless.app.icons

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.appless.uicore.IconMap
import dev.appless.uicore.IconResolution

/**
 * The Compose half of `ui-core`'s [IconMap].
 *
 * `IconMap` resolves a model-emitted Lucide name (or a shell Phosphor name) to
 * a **Material Symbols** name; this table turns that name into the concrete
 * `ImageVector` Compose ships. The table is EXHAUSTIVE over `IconMap`'s four
 * tables — `MaterialSymbolsTest` asserts every symbol name in the spec has an
 * entry, so a new row in `spec/icon-map.md` fails the build rather than
 * silently degrading to the placeholder dot.
 *
 * Five Material Symbols names have no counterpart in `material-icons-extended`
 * (which ships the older *Material Icons* set, not Symbols); each is mapped to
 * the classic set's equivalent glyph and flagged inline.
 */
public object MaterialSymbols {

    /** Material Symbols name -> the Compose vector that draws it. */
    public val vectors: Map<String, ImageVector> = mapOf(
    "ac_unit" to Icons.Rounded.AcUnit,
    "air" to Icons.Rounded.Air,
    "alarm" to Icons.Rounded.Alarm,
    "apartment" to Icons.Rounded.Apartment,
    "arrow_back_ios_new" to Icons.Rounded.ArrowBackIosNew,
    "arrow_upward" to Icons.Rounded.ArrowUpward,
    "auto_awesome" to Icons.Rounded.AutoAwesome,
    "auto_stories" to Icons.Rounded.AutoStories,
    "battery_charging_full" to Icons.Rounded.BatteryChargingFull,
    "battery_full" to Icons.Rounded.BatteryFull,
    "battery_std" to Icons.Rounded.BatteryStd,
    "bluetooth" to Icons.Rounded.Bluetooth,
    "bolt" to Icons.Rounded.Bolt,
    "brightness_low" to Icons.Rounded.BrightnessLow,
    "cake" to Icons.Rounded.Cake,
    "calendar_today" to Icons.Rounded.CalendarToday,
    "call" to Icons.Rounded.Call,
    "chat_bubble" to Icons.Rounded.ChatBubble,
    "check" to Icons.Rounded.Check,
    "check_circle" to Icons.Rounded.CheckCircle,
    "chevron_right" to Icons.Rounded.ChevronRight,
    "cloud" to Icons.Rounded.Cloud,
    "credit_card" to Icons.Rounded.CreditCard,
    "dark_mode" to Icons.Rounded.DarkMode,
    "device_thermostat" to Icons.Rounded.DeviceThermostat,
    "directions_bus" to Icons.Rounded.DirectionsBus,
    "directions_car" to Icons.Rounded.DirectionsCar,
    "directions_run" to Icons.Rounded.DirectionsRun,
    "eco" to Icons.Rounded.Eco,
    "edit" to Icons.Rounded.Edit,
    "edit_note" to Icons.Rounded.EditNote,
    "expand_more" to Icons.Rounded.ExpandMore,
    "favorite" to Icons.Rounded.Favorite,
    "fitness_center" to Icons.Rounded.FitnessCenter,
    "flight" to Icons.Rounded.Flight,
    "flight_takeoff" to Icons.Rounded.FlightTakeoff,
    "footprint" to Icons.Rounded.DirectionsWalk,  // Material Symbols-only; classic set's walking figure
    "group" to Icons.Rounded.Group,
    "hard_drive" to Icons.Rounded.Storage,  // Material Symbols-only; classic set's disk stack
    "headphones" to Icons.Rounded.Headphones,
    "home" to Icons.Rounded.Home,
    "image" to Icons.Rounded.Image,
    "info" to Icons.Rounded.Info,
    "light_mode" to Icons.Rounded.LightMode,
    "local_cafe" to Icons.Rounded.LocalCafe,
    "local_fire_department" to Icons.Rounded.LocalFireDepartment,
    "local_pizza" to Icons.Rounded.LocalPizza,
    "local_shipping" to Icons.Rounded.LocalShipping,
    "location_on" to Icons.Rounded.LocationOn,
    "lock" to Icons.Rounded.Lock,
    "mail" to Icons.Rounded.Mail,
    "map" to Icons.Rounded.Map,
    "menu_book" to Icons.Rounded.MenuBook,
    "mic" to Icons.Rounded.Mic,
    "monitor_heart" to Icons.Rounded.MonitorHeart,
    "movie" to Icons.Rounded.Movie,
    "music_note" to Icons.Rounded.MusicNote,
    "navigation" to Icons.Rounded.Navigation,
    "north_east" to Icons.Rounded.NorthEast,
    "notifications" to Icons.Rounded.Notifications,
    "notifications_active" to Icons.Rounded.NotificationsActive,
    "package_2" to Icons.Rounded.Inventory2,  // Material Symbols-only; classic set's parcel box
    "partly_cloudy_day" to Icons.Rounded.WbCloudy,  // Material Symbols-only; classic set's cloud+sun
    "payments" to Icons.Rounded.Payments,
    "person" to Icons.Rounded.Person,
    "photo_camera" to Icons.Rounded.PhotoCamera,
    "play_arrow" to Icons.Rounded.PlayArrow,
    "public" to Icons.Rounded.Public,
    "rainy" to Icons.Rounded.Grain,  // Material Symbols-only; classic set's rain glyph
    "ramen_dining" to Icons.Rounded.RamenDining,
    "receipt_long" to Icons.Rounded.ReceiptLong,
    "redeem" to Icons.Rounded.Redeem,
    "report" to Icons.Rounded.Report,
    "restaurant" to Icons.Rounded.Restaurant,
    "savings" to Icons.Rounded.Savings,
    "schedule" to Icons.Rounded.Schedule,
    "search" to Icons.Rounded.Search,
    "send" to Icons.Rounded.Send,
    "settings" to Icons.Rounded.Settings,
    "shopping_bag" to Icons.Rounded.ShoppingBag,
    "shopping_cart" to Icons.Rounded.ShoppingCart,
    "signal_cellular_alt" to Icons.Rounded.SignalCellularAlt,
    "south_east" to Icons.Rounded.SouthEast,
    "sports_esports" to Icons.Rounded.SportsEsports,
    "star" to Icons.Rounded.Star,
    "train" to Icons.Rounded.Train,
    "trending_down" to Icons.Rounded.TrendingDown,
    "trending_up" to Icons.Rounded.TrendingUp,
    "umbrella" to Icons.Rounded.Umbrella,
    "unfold_more" to Icons.Rounded.UnfoldMore,
    "verified_user" to Icons.Rounded.VerifiedUser,
    "volume_up" to Icons.Rounded.VolumeUp,
    "wallet" to Icons.Rounded.Wallet,
    "warning" to Icons.Rounded.Warning,
    "water_drop" to Icons.Rounded.WaterDrop,
    "wb_twilight" to Icons.Rounded.WbTwilight,
    "wifi" to Icons.Rounded.Wifi,
    "wine_bar" to Icons.Rounded.WineBar,    )

    /** `null` when the resolution is the placeholder dot or the name is unknown. */
    public fun vector(resolution: IconResolution): ImageVector? =
        resolution.symbolName?.let { vectors[it] }
}

/**
 * Draw a model-emitted Lucide icon name.
 *
 * Unknown names degrade to the neutral placeholder dot — an 8x8 rounded square
 * at 0.6 opacity (spec/icon-map.md §1, `ui/icons.tsx` fallback branch). Never
 * an error, never a fallback glyph, never text.
 */
@Composable
public fun LucideIcon(
    name: String?,
    tint: Color,
    size: Dp = IconMap.DEFAULT_ICON_SIZE.dp,
    modifier: Modifier = Modifier,
) {
    if (name.isNullOrEmpty()) return
    IconResolved(IconMap.resolve(name), tint, size, modifier)
}

/** The home shell's Phosphor names (spec/icon-map.md §5). */
@Composable
public fun PhosphorIcon(
    name: String,
    tint: Color,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    IconResolved(IconMap.resolvePhosphor(name), tint, size, modifier)
}

@Composable
public fun IconResolved(
    resolution: IconResolution,
    tint: Color,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    val vector = MaterialSymbols.vector(resolution)
    if (vector == null) {
        PlaceholderDot(tint, modifier)
        return
    }
    Icon(imageVector = vector, contentDescription = null, tint = tint, modifier = modifier.size(size))
}

/** `ui/icons.tsx` `LucideIcon` fallback branch — 8x8, radius 4, opacity 0.6. */
@Composable
public fun PlaceholderDot(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(IconMap.PLACEHOLDER_DOT_SIZE.dp)) {
        drawRoundRect(
            color = tint.copy(alpha = IconMap.PLACEHOLDER_DOT_OPACITY.toFloat()),
            cornerRadius = CornerRadius(IconMap.PLACEHOLDER_DOT_RADIUS.dp.toPx(), IconMap.PLACEHOLDER_DOT_RADIUS.dp.toPx()),
        )
    }
}

/**
 * The app-switcher glyph: two overlapping rounded squares.
 *
 * spec/icon-map.md §4 notes Material has no faithful equivalent and asks for
 * the shape to be REDRAWN rather than substituted — this is that redraw of
 * `AppsIcon` (`src/genos/ui/icons.tsx`).
 */
@Composable
public fun AppsIcon(color: Color, size: Dp = 18.dp, modifier: Modifier = Modifier) {
    Canvas(modifier.size(size)) {
        val s = this.size.minDimension
        val box = s * 0.62f
        val stroke = Stroke(width = s * 0.11f)
        val radius = CornerRadius(s * 0.16f, s * 0.16f)
        // Back square (top-right), then the front one (bottom-left) overlapping it.
        drawRoundRect(
            color = color.copy(alpha = 0.55f),
            topLeft = Offset(s - box, 0f),
            size = Size(box, box),
            cornerRadius = radius,
            style = stroke,
        )
        drawRoundRect(
            color = color,
            topLeft = Offset(0f, s - box),
            size = Size(box, box),
            cornerRadius = radius,
            style = stroke,
        )
    }
}
