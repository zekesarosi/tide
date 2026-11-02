# Slack Water: design system

The app should feel light and calm, and stay precise. It is named after
slack water, the still moment between tides. The tokens live in
`Shared/Theme.swift`, which both the app and the widgets compile.

## Principles

* **Answer first.** Every screen opens on the reading, the trend and the next
  tide. Method and sources are one tap away, never in front.
* **Hairlines, not boxes.** Space and 1 pt rules separate sections. Cards
  appear only on the mist list ground: radius 18, continuous corners, a shadow
  you barely see.
* **Color means something.** Harbor blue is measured water. Swell amber is
  forecast or extra water. The flood colors appear only for flood risk. A screen
  may carry one tinted block, the risk callout, and only when it is warranted.
* **Plain language.** Write "1.2 ft above the tide table", not "residual
  +0.36 m". Units follow the user's setting; times follow the station's clock.
* **Calm motion.** Numbers roll (`.contentTransition(.numericText())`) and the
  chart eases between ranges. Nothing bounces, and Reduce Motion turns it off.

## Tokens

| Role | Light | Dark | Use |
|---|---|---|---|
| Surface | #FFFFFF | #0B1820 | Screens |
| Mist | #F5F8F9 | #060F15 | List ground |
| Ink | #0D2230 | #E8F0F4 | Text |
| Ink secondary | #4E6575 | #9DB2BF | Labels (6:1 on white) |
| Hairline | #E3EAEE | #1F3340 | Rules |
| Harbor | #1F6FA6 | #6FB3E3 | Observed water, actions, tint |
| Swell | #D9772E | #F0A266 | Forecast line, surge |
| Swell text / wash | #9A4A10 / #FDF1E7 | #F4B27F / #3A2414 | Anomaly chip, risk callout |
| Tide table | #7F95A3 | #6F8794 | Dashed predicted tide |
| Flood line | #C4552B | #E7835A | Flood threshold rule |
| Action / Minor / Moderate / Major | #8A6D00 / #B35612 / #B3261E / #6E3AA0 | lighter tints | Flood badges only |

## Type

The type is SF Pro, with SF Pro Rounded for numbers.

* Reading: Rounded Thin 76 (`Font.reading(76)`); 30–42 in widgets.
* Card value: Rounded Thin 34. Row value: Rounded Light 20.
* Body 17; section labels at 13 semibold caps with 1 pt tracking (`SectionLabel`).

Spacing is on a 4 pt grid: 20 pt screen margins, 26 pt between sections and
12 pt inside them. Touch targets are at least 44 pt.

## Components

* `TideLineChart` is the signature element: a full-bleed tide line. It has an
  observed (harbor) and forecast (swell) line over a soft water fill, the 80 %
  range, the dashed tide table, the flood rule with any crossing filled, and a
  "now" dot. Scrubbing swaps the legend for a readout.
* `Chip` (swell / neutral / harbor), `FloodBadge`, `RiskCallout`, `TrendArrow`,
  `Hairline`, `SectionLabel`, `GroupCard`, `FavoriteCard` (with `DayTideLine`),
  `NextTidesGrid`, `FloodRuler`, `DriverBars`.

## Screens

* **Tides (home):** the date, favorites as live cards (reading, trend, next tide,
  today's line, anomaly, risk badge), then Nearby and Browse by region.
  Favorites refresh quietly in the background and feed the widgets.
* **Station:**
  * a caps header;
  * at most one risk callout (storm, NWS alert or flood risk);
  * the reading with its trend and chips;
  * the tide line;
  * next tides;
  * the flood outlook ruler;
  * why the water is high, as driver bars;
  * confidence;
  * a link to "How this forecast works" (method, surge chart, model diagnostics,
    sources).
* **Widgets:** the same tokens, with Rounded Thin numerals and the swell forecast line.
